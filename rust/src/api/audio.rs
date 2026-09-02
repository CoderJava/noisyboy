use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Stream, StreamConfig};
use nnnoiseless::DenoiseState;
use ringbuf::traits::{Consumer, Producer, Split};
use ringbuf::HeapRb;

struct AudioEngine {
    _input_stream: Stream,
    _output_stream: Stream,
}

unsafe impl Send for AudioEngine {}

static ENGINE: Mutex<Option<AudioEngine>> = Mutex::new(None);

/// Apakah denoise aktif. Bisa di-toggle saat loopback jalan.
static DENOISE_ON: AtomicBool = AtomicBool::new(true);

/// Sample rate yang dibutuhkan nnnoiseless.
const DENOISE_RATE: f32 = 48_000.0;

/// Resampler linear stateful sederhana. Cukup untuk voice.
/// Mengubah stream dari `from_rate` ke `to_rate` secara incremental.
struct LinearResampler {
    ratio: f32, // to_rate / from_rate
    pos: f32,
    last: f32,
    started: bool,
}

impl LinearResampler {
    fn new(from_rate: f32, to_rate: f32) -> Self {
        Self {
            ratio: to_rate / from_rate,
            pos: 0.0,
            last: 0.0,
            started: false,
        }
    }

    /// Masukkan satu sample input, keluarkan 0+ sample output ke `out`.
    fn push(&mut self, sample: f32, out: &mut Vec<f32>) {
        if !self.started {
            self.started = true;
            self.last = sample;
            self.pos = 0.0;
        }
        // Setiap sample input menaikkan "waktu" sebesar ratio.
        self.pos += self.ratio;
        while self.pos >= 1.0 {
            self.pos -= 1.0;
            let t = 1.0 - self.pos; // interpolasi antara last dan sample
            out.push(self.last + (sample - self.last) * t);
        }
        self.last = sample;
    }
}

/// Daftar nama device input yang tersedia.
#[flutter_rust_bridge::frb(sync)]
pub fn list_input_devices() -> Vec<String> {
    let host = cpal::default_host();
    let mut names = Vec::new();
    if let Ok(devices) = host.input_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                names.push(name);
            }
        }
    }
    names
}

/// Daftar nama device output (speaker) yang tersedia.
#[flutter_rust_bridge::frb(sync)]
pub fn list_output_devices() -> Vec<String> {
    let host = cpal::default_host();
    let mut names = Vec::new();
    if let Ok(devices) = host.output_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                names.push(name);
            }
        }
    }
    names
}

/// Aktif/nonaktifkan denoise secara live.
#[flutter_rust_bridge::frb(sync)]
pub fn set_denoise(enabled: bool) {
    DENOISE_ON.store(enabled, Ordering::Relaxed);
}

/// Status denoise saat ini.
#[flutter_rust_bridge::frb(sync)]
pub fn is_denoise_on() -> bool {
    DENOISE_ON.load(Ordering::Relaxed)
}

/// Mulai loopback dengan denoise.
///
/// Memakai sample rate NATIVE tiap device (tidak dipaksa), lalu resample
/// ke 48kHz untuk nnnoiseless dan resample balik ke rate output. Ini
/// menghindari error "stream configuration not supported".
pub fn start_loopback(
    device_name: Option<String>,
    output_name: Option<String>,
) -> Result<String> {
    let mut guard = ENGINE.lock().unwrap();
    if guard.is_some() {
        return Ok("Loopback sudah berjalan".to_string());
    }

    let host = cpal::default_host();

    // Pilih input device: cari berdasarkan nama, atau pakai default.
    let input_device = match device_name.as_deref() {
        Some(name) if !name.is_empty() => host
            .input_devices()
            .ok()
            .and_then(|mut devs| {
                devs.find(|d| d.name().map(|n| n == name).unwrap_or(false))
            })
            .or_else(|| host.default_input_device())
            .ok_or_else(|| anyhow!("Tidak ada input device (mic)"))?,
        _ => host
            .default_input_device()
            .ok_or_else(|| anyhow!("Tidak ada input device (mic)"))?,
    };

    // Pilih output device: cari berdasarkan nama, atau pakai default.
    let output_device = match output_name.as_deref() {
        Some(name) if !name.is_empty() => host
            .output_devices()
            .ok()
            .and_then(|mut devs| {
                devs.find(|d| d.name().map(|n| n == name).unwrap_or(false))
            })
            .or_else(|| host.default_output_device())
            .ok_or_else(|| anyhow!("Tidak ada output device (speaker)"))?,
        _ => host
            .default_output_device()
            .ok_or_else(|| anyhow!("Tidak ada output device (speaker)"))?,
    };

    // Pakai konfigurasi NATIVE device apa adanya.
    let input_config = input_device.default_input_config()?;
    let output_config = output_device.default_output_config()?;

    let in_channels = input_config.channels() as usize;
    let out_channels = output_config.channels() as usize;
    let in_rate = input_config.sample_rate().0 as f32;
    let out_rate = output_config.sample_rate().0 as f32;

    // Ring buffer menyimpan sample MONO pada rate OUTPUT. Kapasitas ~1 detik.
    let capacity = (out_rate as usize).max(48000);
    let rb = HeapRb::<f32>::new(capacity);
    let (mut producer, mut consumer) = rb.split();

    // Prefill diam ~80ms untuk cegah underrun awal.
    let prefill = (out_rate as usize) * 80 / 1000;
    for _ in 0..prefill {
        let _ = producer.try_push(0.0);
    }

    let in_cfg: StreamConfig = input_config.clone().into();
    let out_cfg: StreamConfig = output_config.clone().into();

    let err_fn = |err| eprintln!("[NoisyBoy] stream error: {err}");

    // Denoiser + resampler in (native->48k) dan out (48k->output rate).
    let mut denoiser = DenoiseState::new();
    let mut up = LinearResampler::new(in_rate, DENOISE_RATE);
    let mut down = LinearResampler::new(DENOISE_RATE, out_rate);
    let mut at48k: Vec<f32> = Vec::with_capacity(2048);
    let mut frame_in: Vec<f32> = Vec::with_capacity(DenoiseState::FRAME_SIZE);
    let mut frame_out = [0.0f32; DenoiseState::FRAME_SIZE];
    let mut resampled: Vec<f32> = Vec::with_capacity(2048);

    static UNDERRUN_LOGGED: AtomicBool = AtomicBool::new(false);

    let input_stream = input_device.build_input_stream(
        &in_cfg,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            for frame in data.chunks(in_channels) {
                // Downmix ke mono.
                let mut sum = 0.0f32;
                for &s in frame {
                    sum += s;
                }
                let mono = sum / in_channels as f32;

                // Resample native -> 48kHz.
                at48k.clear();
                up.push(mono, &mut at48k);

                for &s48 in at48k.iter() {
                    frame_in.push(s48);
                    if frame_in.len() == DenoiseState::FRAME_SIZE {
                        let processed: &[f32] = if DENOISE_ON.load(Ordering::Relaxed)
                        {
                            let scaled: Vec<f32> =
                                frame_in.iter().map(|s| s * 32768.0).collect();
                            denoiser.process_frame(&mut frame_out, &scaled);
                            for v in frame_out.iter_mut() {
                                *v /= 32768.0;
                            }
                            &frame_out[..]
                        } else {
                            &frame_in[..]
                        };

                        // Resample 48kHz -> output rate, push ke ring buffer.
                        for &p in processed.iter() {
                            resampled.clear();
                            down.push(p, &mut resampled);
                            for &r in resampled.iter() {
                                let _ = producer.try_push(r);
                            }
                        }
                        frame_in.clear();
                    }
                }
            }
        },
        err_fn,
        None,
    )?;

    let output_stream = output_device.build_output_stream(
        &out_cfg,
        move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
            for frame in data.chunks_mut(out_channels) {
                let mono = match consumer.try_pop() {
                    Some(v) => v,
                    None => {
                        if !UNDERRUN_LOGGED.swap(true, Ordering::Relaxed) {
                            eprintln!("[NoisyBoy] buffer underrun (glitch)");
                        }
                        0.0
                    }
                };
                for out in frame.iter_mut() {
                    *out = mono;
                }
            }
        },
        err_fn,
        None,
    )?;

    input_stream.play()?;
    output_stream.play()?;

    *guard = Some(AudioEngine {
        _input_stream: input_stream,
        _output_stream: output_stream,
    });

    Ok(format!(
        "Loopback + denoise jalan (mic {}Hz {}ch -> speaker {}Hz {}ch)",
        in_rate as u32, in_channels, out_rate as u32, out_channels
    ))
}

/// Hentikan loopback.
pub fn stop_loopback() -> Result<String> {
    let mut guard = ENGINE.lock().unwrap();
    if guard.take().is_some() {
        Ok("Loopback dihentikan".to_string())
    } else {
        Ok("Loopback tidak sedang berjalan".to_string())
    }
}

/// Apakah loopback sedang berjalan.
#[flutter_rust_bridge::frb(sync)]
pub fn is_running() -> bool {
    ENGINE.lock().unwrap().is_some()
}

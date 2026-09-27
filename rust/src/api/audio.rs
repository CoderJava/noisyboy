use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Stream, StreamConfig};
use nnnoiseless::DenoiseState;
use ringbuf::traits::{Consumer, Producer, Split};
use ringbuf::HeapRb;

use crate::frb_generated::StreamSink;

struct AudioEngine {
    input_stream: Stream,
    output_stream: Stream,
}

unsafe impl Send for AudioEngine {}

impl Drop for AudioEngine {
    fn drop(&mut self) {
        let _ = self.input_stream.pause();
        let _ = self.output_stream.pause();
    }
}

static ENGINE: Mutex<Option<AudioEngine>> = Mutex::new(None);

/// Data level audio untuk visualisasi VU meter / waveform di UI.
pub struct AudioLevel {
    pub input_level: f32,
    pub output_level: f32,
}

static LEVEL_SINK: Mutex<Option<StreamSink<AudioLevel>>> = Mutex::new(None);

/// Daftarkan stream sink untuk menerima update level audio secara live.
pub fn create_audio_level_stream(sink: StreamSink<AudioLevel>) -> Result<()> {
    let mut guard = LEVEL_SINK.lock().unwrap();
    *guard = Some(sink);
    Ok(())
}

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

/// High-pass filter 80Hz untuk memotong low rumble / getaran meja dari ketikan keyboard.
struct HighPassFilter {
    alpha: f32,
    prev_in: f32,
    prev_out: f32,
}

impl HighPassFilter {
    fn new(cutoff_hz: f32, sample_rate: f32) -> Self {
        let dt = 1.0 / sample_rate;
        let rc = 1.0 / (2.0 * std::f32::consts::PI * cutoff_hz);
        let alpha = rc / (rc + dt);
        Self {
            alpha,
            prev_in: 0.0,
            prev_out: 0.0,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let out = self.alpha * (self.prev_out + input - self.prev_in);
        self.prev_in = input;
        self.prev_out = out;
        out
    }
}

/// Intelligent VAD (Voice Activity Detection) Noise Gate.
/// Memotong suara gangguan transient (ketikan keyboard, keresekan plastik, klik mouse, nafas)
/// saat pengguna tidak sedang berbicara, dengan transisi halus dan hangover time.
struct VadGate {
    gain: f32,
    hangover_frames: usize,
    max_hangover: usize,
    threshold: f32,
}

impl VadGate {
    fn new() -> Self {
        Self {
            gain: 0.0,
            hangover_frames: 0,
            max_hangover: 18, // ~180ms hangover agar akhir kata tidak terpotong
            threshold: 0.25,  // VAD probability threshold
        }
    }

    fn process(&mut self, vad_prob: f32, frame: &mut [f32]) {
        let target_gain = if vad_prob >= self.threshold {
            self.hangover_frames = self.max_hangover;
            1.0
        } else if self.hangover_frames > 0 {
            self.hangover_frames -= 1;
            1.0
        } else {
            0.0
        };

        for sample in frame.iter_mut() {
            self.gain += (target_gain - self.gain) * 0.04;
            *sample *= self.gain;
        }
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

/// Cek apakah virtual audio driver (NoisyBoy Audio atau BlackHole) terpasang di sistem.
#[flutter_rust_bridge::frb(sync)]
pub fn is_virtual_driver_installed() -> bool {
    let outputs = list_output_devices();
    outputs.iter().any(|d| d.contains("NoisyBoy") || d.contains("BlackHole"))
}

/// Dapatkan nama virtual output device jika tersedia.
#[flutter_rust_bridge::frb(sync)]
pub fn get_virtual_device_name() -> Option<String> {
    let outputs = list_output_devices();
    outputs
        .into_iter()
        .find(|d| d.contains("NoisyBoy Audio") || d.contains("BlackHole"))
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
    if let Some(old) = guard.take() {
        let _ = old.input_stream.pause();
        let _ = old.output_stream.pause();
        drop(old);
    }
    UNDERRUN_LOGGED.store(false, Ordering::Relaxed);

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

fn compute_rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

fn rms_to_level(rms: f32) -> f32 {
    if rms <= 0.0001 {
        return 0.0;
    }
    let db = 20.0 * rms.max(0.0001).log10();
    let normalized = (db + 50.0) / 50.0;
    normalized.clamp(0.0, 1.0)
}

    // Denoiser + resampler in (native->48k) dan out (48k->output rate).
    let mut denoiser = DenoiseState::new();
    let mut up = LinearResampler::new(in_rate, DENOISE_RATE);
    let mut down = LinearResampler::new(DENOISE_RATE, out_rate);
    let mut hpf = HighPassFilter::new(80.0, DENOISE_RATE);
    let mut vad_gate = VadGate::new();
    let mut at48k: Vec<f32> = Vec::with_capacity(2048);
    let mut frame_in: Vec<f32> = Vec::with_capacity(DenoiseState::FRAME_SIZE);
    let mut frame_out = [0.0f32; DenoiseState::FRAME_SIZE];
    let mut resampled: Vec<f32> = Vec::with_capacity(2048);
    let mut meter_in: Vec<f32> = Vec::with_capacity(1440);
    let mut meter_out: Vec<f32> = Vec::with_capacity(1440);
    let mut frames_counter: usize = 0;

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
                    let filtered = hpf.process(s48);
                    frame_in.push(filtered);
                    if frame_in.len() == DenoiseState::FRAME_SIZE {
                        let processed: &[f32] = if DENOISE_ON.load(Ordering::Relaxed)
                        {
                            let scaled: Vec<f32> =
                                frame_in.iter().map(|s| s * 32768.0).collect();
                            let vad_prob = denoiser.process_frame(&mut frame_out, &scaled);
                            for v in frame_out.iter_mut() {
                                *v /= 32768.0;
                            }
                            vad_gate.process(vad_prob, &mut frame_out);
                            &frame_out[..]
                        } else {
                            &frame_in[..]
                        };

                        meter_in.extend_from_slice(&frame_in);
                        meter_out.extend_from_slice(processed);
                        frames_counter += 1;
                        if frames_counter >= 3 {
                            let in_lvl = rms_to_level(compute_rms(&meter_in));
                            let out_lvl = rms_to_level(compute_rms(&meter_out));
                            meter_in.clear();
                            meter_out.clear();
                            frames_counter = 0;
                            if let Ok(guard) = LEVEL_SINK.try_lock() {
                                if let Some(sink) = guard.as_ref() {
                                    let _ = sink.add(AudioLevel {
                                        input_level: in_lvl,
                                        output_level: out_lvl,
                                    });
                                }
                            }
                        }

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
        input_stream,
        output_stream,
    });

    Ok(format!(
        "Loopback + denoise jalan (mic {}Hz {}ch -> speaker {}Hz {}ch)",
        in_rate as u32, in_channels, out_rate as u32, out_channels
    ))
}

/// Hentikan loopback.
pub fn stop_loopback() -> Result<String> {
    let mut guard = ENGINE.lock().unwrap();
    if let Some(engine) = guard.take() {
        let _ = engine.input_stream.pause();
        let _ = engine.output_stream.pause();
        drop(engine);
        if let Ok(sink_guard) = LEVEL_SINK.try_lock() {
            if let Some(sink) = sink_guard.as_ref() {
                let _ = sink.add(AudioLevel {
                    input_level: 0.0,
                    output_level: 0.0,
                });
            }
        }
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

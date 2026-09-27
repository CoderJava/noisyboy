import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:noisyboy/src/rust/api/audio.dart' as rust;

/// Events
sealed class LoopbackEvent extends Equatable {
  const LoopbackEvent();
  @override
  List<Object?> get props => [];
}

class DevicesLoaded extends LoopbackEvent {
  const DevicesLoaded();
}

class RefreshDevices extends LoopbackEvent {
  const RefreshDevices();
}

class DeviceSelected extends LoopbackEvent {
  final String? device;
  const DeviceSelected(this.device);
  @override
  List<Object?> get props => [device];
}

class OutputSelected extends LoopbackEvent {
  final String? device;
  const OutputSelected(this.device);
  @override
  List<Object?> get props => [device];
}

class LoopbackStarted extends LoopbackEvent {
  const LoopbackStarted();
}

class LoopbackStopped extends LoopbackEvent {
  const LoopbackStopped();
}

class LoopbackToggled extends LoopbackEvent {
  const LoopbackToggled();
}

class DenoiseToggled extends LoopbackEvent {
  const DenoiseToggled();
}

class ModeChanged extends LoopbackEvent {
  final bool isVirtualMicMode;
  const ModeChanged(this.isVirtualMicMode);
  @override
  List<Object?> get props => [isVirtualMicMode];
}

class AudioLevelUpdated extends LoopbackEvent {
  final rust.AudioLevel level;
  const AudioLevelUpdated(this.level);
  @override
  List<Object?> get props => [level.inputLevel, level.outputLevel];
}

/// State
enum LoopbackStatus { idle, running, error }

class LoopbackState extends Equatable {
  final LoopbackStatus status;
  final String message;
  final bool denoiseOn;
  final List<String> devices;

  /// null = pakai mic default sistem.
  final String? selectedDevice;

  final List<String> outputDevices;

  /// null = pakai speaker default sistem.
  final String? selectedOutput;

  /// Audio metering levels (0.0 to 1.0)
  final double inputLevel;
  final double outputLevel;

  /// Virtual driver status
  final bool isVirtualDriverInstalled;
  final String? virtualDeviceName;
  final bool isVirtualMicMode;

  const LoopbackState({
    this.status = LoopbackStatus.idle,
    this.message = 'Siap',
    this.denoiseOn = true,
    this.devices = const [],
    this.selectedDevice,
    this.outputDevices = const [],
    this.selectedOutput,
    this.inputLevel = 0.0,
    this.outputLevel = 0.0,
    this.isVirtualDriverInstalled = false,
    this.virtualDeviceName,
    this.isVirtualMicMode = true,
  });

  bool get isRunning => status == LoopbackStatus.running;

  LoopbackState copyWith({
    LoopbackStatus? status,
    String? message,
    bool? denoiseOn,
    List<String>? devices,
    String? selectedDevice,
    List<String>? outputDevices,
    String? selectedOutput,
    double? inputLevel,
    double? outputLevel,
    bool? isVirtualDriverInstalled,
    String? virtualDeviceName,
    bool? isVirtualMicMode,
    bool clearSelected = false,
    bool clearOutput = false,
  }) {
    return LoopbackState(
      status: status ?? this.status,
      message: message ?? this.message,
      denoiseOn: denoiseOn ?? this.denoiseOn,
      devices: devices ?? this.devices,
      selectedDevice:
          clearSelected ? null : (selectedDevice ?? this.selectedDevice),
      outputDevices: outputDevices ?? this.outputDevices,
      selectedOutput:
          clearOutput ? null : (selectedOutput ?? this.selectedOutput),
      inputLevel: inputLevel ?? this.inputLevel,
      outputLevel: outputLevel ?? this.outputLevel,
      isVirtualDriverInstalled:
          isVirtualDriverInstalled ?? this.isVirtualDriverInstalled,
      virtualDeviceName: virtualDeviceName ?? this.virtualDeviceName,
      isVirtualMicMode: isVirtualMicMode ?? this.isVirtualMicMode,
    );
  }

  @override
  List<Object?> get props => [
        status,
        message,
        denoiseOn,
        devices,
        selectedDevice,
        outputDevices,
        selectedOutput,
        inputLevel,
        outputLevel,
        isVirtualDriverInstalled,
        virtualDeviceName,
        isVirtualMicMode,
      ];
}

/// Bloc
class LoopbackBloc extends Bloc<LoopbackEvent, LoopbackState> {
  StreamSubscription<rust.AudioLevel>? _levelSub;

  LoopbackBloc() : super(LoopbackState(denoiseOn: rust.isDenoiseOn())) {
    on<DevicesLoaded>(_onDevicesLoaded);
    on<RefreshDevices>(_onRefreshDevices);
    on<DeviceSelected>(_onDeviceSelected);
    on<OutputSelected>(_onOutputSelected);
    on<ModeChanged>(_onModeChanged);
    on<LoopbackStarted>(_onStarted);
    on<LoopbackStopped>(_onStopped);
    on<LoopbackToggled>(_onToggled);
    on<DenoiseToggled>(_onDenoiseToggled);
    on<AudioLevelUpdated>(_onAudioLevelUpdated);

    _initLevelStream();
    add(const DevicesLoaded());
  }

  void _initLevelStream() {
    _levelSub = rust.createAudioLevelStream().listen(
      (level) => add(AudioLevelUpdated(level)),
      onError: (err) {
        // Stream error handling
      },
    );
  }

  void _onDevicesLoaded(DevicesLoaded event, Emitter<LoopbackState> emit) {
    final devices = rust.listInputDevices();
    final outputs = rust.listOutputDevices();
    final driverInstalled = rust.isVirtualDriverInstalled();
    final virtualName = rust.getVirtualDeviceName();

    emit(state.copyWith(
      devices: devices,
      outputDevices: outputs,
      isVirtualDriverInstalled: driverInstalled,
      virtualDeviceName: virtualName,
      isVirtualMicMode: driverInstalled ? state.isVirtualMicMode : false,
    ));
  }

  void _onRefreshDevices(RefreshDevices event, Emitter<LoopbackState> emit) {
    final devices = rust.listInputDevices();
    final outputs = rust.listOutputDevices();
    final driverInstalled = rust.isVirtualDriverInstalled();
    final virtualName = rust.getVirtualDeviceName();

    emit(state.copyWith(
      devices: devices,
      outputDevices: outputs,
      isVirtualDriverInstalled: driverInstalled,
      virtualDeviceName: virtualName,
      isVirtualMicMode: driverInstalled ? state.isVirtualMicMode : false,
    ));
  }

  Future<void> _onModeChanged(
    ModeChanged event,
    Emitter<LoopbackState> emit,
  ) async {
    emit(state.copyWith(isVirtualMicMode: event.isVirtualMicMode));
    if (state.isRunning) {
      await rust.stopLoopback();
      final targetOutput = event.isVirtualMicMode
          ? state.virtualDeviceName
          : state.selectedOutput;
      final msg = await rust.startLoopback(
        deviceName: state.selectedDevice,
        outputName: targetOutput,
      );
      emit(state.copyWith(status: LoopbackStatus.running, message: msg));
    }
  }

  void _onAudioLevelUpdated(
    AudioLevelUpdated event,
    Emitter<LoopbackState> emit,
  ) {
    emit(state.copyWith(
      inputLevel: event.level.inputLevel,
      outputLevel: event.level.outputLevel,
    ));
  }

  Future<void> _onDeviceSelected(
    DeviceSelected event,
    Emitter<LoopbackState> emit,
  ) async {
    emit(state.copyWith(
      selectedDevice: event.device,
      clearSelected: event.device == null,
    ));
    // Jika sedang jalan, restart dengan device baru.
    if (state.isRunning) {
      await rust.stopLoopback();
      final targetOutput = state.isVirtualMicMode && state.virtualDeviceName != null
          ? state.virtualDeviceName
          : state.selectedOutput;
      final msg = await rust.startLoopback(
        deviceName: event.device,
        outputName: targetOutput,
      );
      emit(state.copyWith(status: LoopbackStatus.running, message: msg));
    }
  }

  Future<void> _onOutputSelected(
    OutputSelected event,
    Emitter<LoopbackState> emit,
  ) async {
    emit(state.copyWith(
      selectedOutput: event.device,
      clearOutput: event.device == null,
    ));
    if (state.isRunning && !state.isVirtualMicMode) {
      await rust.stopLoopback();
      final msg = await rust.startLoopback(
        deviceName: state.selectedDevice,
        outputName: event.device,
      );
      emit(state.copyWith(status: LoopbackStatus.running, message: msg));
    }
  }

  Future<void> _onStarted(
    LoopbackStarted event,
    Emitter<LoopbackState> emit,
  ) async {
    try {
      final targetOutput = state.isVirtualMicMode && state.virtualDeviceName != null
          ? state.virtualDeviceName
          : state.selectedOutput;
      final msg = await rust.startLoopback(
        deviceName: state.selectedDevice,
        outputName: targetOutput,
      );
      emit(state.copyWith(status: LoopbackStatus.running, message: msg));
    } catch (e) {
      emit(state.copyWith(status: LoopbackStatus.error, message: 'Error: $e'));
    }
  }

  Future<void> _onStopped(
    LoopbackStopped event,
    Emitter<LoopbackState> emit,
  ) async {
    try {
      final msg = await rust.stopLoopback();
      emit(state.copyWith(
        status: LoopbackStatus.idle,
        message: msg,
        inputLevel: 0.0,
        outputLevel: 0.0,
      ));
    } catch (e) {
      emit(state.copyWith(status: LoopbackStatus.error, message: 'Error: $e'));
    }
  }

  Future<void> _onToggled(
    LoopbackToggled event,
    Emitter<LoopbackState> emit,
  ) async {
    if (state.isRunning) {
      await _onStopped(const LoopbackStopped(), emit);
    } else {
      await _onStarted(const LoopbackStarted(), emit);
    }
  }

  void _onDenoiseToggled(DenoiseToggled event, Emitter<LoopbackState> emit) {
    final next = !state.denoiseOn;
    rust.setDenoise(enabled: next);
    emit(state.copyWith(denoiseOn: next));
  }

  @override
  Future<void> close() {
    _levelSub?.cancel();
    return super.close();
  }
}

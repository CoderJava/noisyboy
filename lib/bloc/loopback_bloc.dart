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

  const LoopbackState({
    this.status = LoopbackStatus.idle,
    this.message = 'Siap',
    this.denoiseOn = true,
    this.devices = const [],
    this.selectedDevice,
    this.outputDevices = const [],
    this.selectedOutput,
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
    );
  }

  @override
  List<Object?> get props =>
      [status, message, denoiseOn, devices, selectedDevice, outputDevices, selectedOutput];
}

/// Bloc
class LoopbackBloc extends Bloc<LoopbackEvent, LoopbackState> {
  LoopbackBloc() : super(LoopbackState(denoiseOn: rust.isDenoiseOn())) {
    on<DevicesLoaded>(_onDevicesLoaded);
    on<DeviceSelected>(_onDeviceSelected);
    on<OutputSelected>(_onOutputSelected);
    on<LoopbackStarted>(_onStarted);
    on<LoopbackStopped>(_onStopped);
    on<LoopbackToggled>(_onToggled);
    on<DenoiseToggled>(_onDenoiseToggled);
    add(const DevicesLoaded());
  }

  void _onDevicesLoaded(DevicesLoaded event, Emitter<LoopbackState> emit) {
    final devices = rust.listInputDevices();
    final outputs = rust.listOutputDevices();
    emit(state.copyWith(devices: devices, outputDevices: outputs));
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
      final msg = await rust.startLoopback(
        deviceName: event.device,
        outputName: state.selectedOutput,
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
    if (state.isRunning) {
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
      final msg = await rust.startLoopback(
        deviceName: state.selectedDevice,
        outputName: state.selectedOutput,
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
      emit(state.copyWith(status: LoopbackStatus.idle, message: msg));
    } catch (e) {
      emit(state.copyWith(status: LoopbackStatus.error, message: 'Error: $e'));
    }
  }

  Future<void> _onToggled(
    LoopbackToggled event,
    Emitter<LoopbackState> emit,
  ) async {
    if (state.isRunning) {
      add(const LoopbackStopped());
    } else {
      add(const LoopbackStarted());
    }
  }

  void _onDenoiseToggled(DenoiseToggled event, Emitter<LoopbackState> emit) {
    final next = !state.denoiseOn;
    rust.setDenoise(enabled: next);
    emit(state.copyWith(denoiseOn: next));
  }
}

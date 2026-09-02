import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:noisyboy/bloc/loopback_bloc.dart';
import 'package:noisyboy/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const NoisyBoyApp());
}

class NoisyBoyApp extends StatelessWidget {
  const NoisyBoyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoisyBoy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'SF Pro Display',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C5CE7),
          brightness: Brightness.dark,
        ),
      ),
      home: BlocProvider(
        create: (_) => LoopbackBloc(),
        child: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF12101E), Color(0xFF1E1B33), Color(0xFF0D0B17)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: BlocBuilder<LoopbackBloc, LoopbackState>(
                builder: (context, state) {
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const _Header(),
                      const SizedBox(height: 28),
                      _MicPicker(state: state),
                      const SizedBox(height: 14),
                      _OutputPicker(state: state),
                      const SizedBox(height: 28),
                      _MicButton(state: state),
                      const SizedBox(height: 24),
                      _DenoiseToggle(state: state),
                      const SizedBox(height: 24),
                      _StatusPill(state: state),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF9F8FFF), Color(0xFF6C5CE7)],
          ).createShader(bounds),
          child: const Text(
            'NoisyBoy',
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: -1,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'AI Noise Suppression',
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withValues(alpha: 0.5),
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

class _MicPicker extends StatelessWidget {
  final LoopbackState state;
  const _MicPicker({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(Icons.settings_voice_rounded,
              color: Color(0xFF9F8FFF), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: state.selectedDevice,
                isExpanded: true,
                dropdownColor: const Color(0xFF1E1B33),
                icon: const Icon(Icons.expand_more_rounded,
                    color: Colors.white54),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                hint: const Text('Mic Default Sistem',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Mic Default Sistem'),
                  ),
                  ...state.devices.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d,
                      child: Text(d, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (val) =>
                    context.read<LoopbackBloc>().add(DeviceSelected(val)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputPicker extends StatelessWidget {
  final LoopbackState state;
  const _OutputPicker({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(Icons.speaker_rounded, color: Color(0xFF9F8FFF), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: state.selectedOutput,
                isExpanded: true,
                dropdownColor: const Color(0xFF1E1B33),
                icon: const Icon(Icons.expand_more_rounded,
                    color: Colors.white54),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                hint: const Text('Speaker Default Sistem',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Speaker Default Sistem'),
                  ),
                  ...state.outputDevices.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d,
                      child: Text(d, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (val) =>
                    context.read<LoopbackBloc>().add(OutputSelected(val)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  final LoopbackState state;
  const _MicButton({required this.state});

  @override
  Widget build(BuildContext context) {
    final running = state.isRunning;
    return GestureDetector(
      onTap: () => context.read<LoopbackBloc>().add(const LoopbackToggled()),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: running
                ? [const Color(0xFF7C6FFF), const Color(0xFF5A4BD6)]
                : [const Color(0xFF2A2740), const Color(0xFF1C1A2E)],
          ),
          boxShadow: [
            BoxShadow(
              color: running
                  ? const Color(0xFF6C5CE7).withValues(alpha: 0.6)
                  : Colors.black.withValues(alpha: 0.4),
              blurRadius: running ? 60 : 20,
              spreadRadius: running ? 8 : 0,
            ),
          ],
        ),
        child: Icon(
          running ? Icons.mic_rounded : Icons.mic_off_rounded,
          size: 80,
          color: running ? Colors.white : Colors.white.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

class _DenoiseToggle extends StatelessWidget {
  final LoopbackState state;
  const _DenoiseToggle({required this.state});

  @override
  Widget build(BuildContext context) {
    final on = state.denoiseOn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            on ? Icons.auto_awesome : Icons.auto_awesome_outlined,
            color: on ? const Color(0xFF9F8FFF) : Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            'AI Denoise',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            value: on,
            activeThumbColor: Colors.white,
            activeTrackColor: const Color(0xFF6C5CE7),
            onChanged: (_) =>
                context.read<LoopbackBloc>().add(const DenoiseToggled()),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final LoopbackState state;
  const _StatusPill({required this.state});

  @override
  Widget build(BuildContext context) {
    final isError = state.status == LoopbackStatus.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isError
                  ? Colors.redAccent
                  : (state.isRunning
                      ? const Color(0xFF4ADE80)
                      : Colors.grey),
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              state.message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

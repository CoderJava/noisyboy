import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:noisyboy/bloc/loopback_bloc.dart';
import 'package:noisyboy/src/rust/frb_generated.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await RustLib.init();

  const windowOptions = WindowOptions(
    size: Size(480, 720),
    minimumSize: Size(440, 620),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'NoisyBoy',
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

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
        child: const AppTrayWrapper(child: HomePage()),
      ),
    );
  }
}

/// Menghubungkan TrayManager dan WindowManager ke BLoC
class AppTrayWrapper extends StatefulWidget {
  final Widget child;
  const AppTrayWrapper({super.key, required this.child});

  @override
  State<AppTrayWrapper> createState() => _AppTrayWrapperState();
}

class _AppTrayWrapperState extends State<AppTrayWrapper>
    with TrayListener, WindowListener {
  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initTray();
  }

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.png');
    await trayManager.setToolTip('NoisyBoy — AI Noise Suppression');
    if (mounted) {
      _updateTrayMenu(context.read<LoopbackBloc>().state);
    }
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Sembunyikan window saat tombol close ditekan agar tetap aktif di menubar
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final bloc = context.read<LoopbackBloc>();
    final key = menuItem.key;
    if (key == null) return;

    if (key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
    } else if (key == 'toggle_mic') {
      bloc.add(const LoopbackToggled());
    } else if (key == 'toggle_denoise') {
      bloc.add(const DenoiseToggled());
    } else if (key == 'mode_meeting') {
      bloc.add(const ModeChanged(true));
    } else if (key == 'mode_speaker') {
      bloc.add(const ModeChanged(false));
    } else if (key == 'mic_default') {
      bloc.add(const DeviceSelected(null));
    } else if (key.startsWith('mic_')) {
      final device = key.substring(4);
      bloc.add(DeviceSelected(device));
    } else if (key == 'speaker_default') {
      bloc.add(const ModeChanged(false));
      bloc.add(const OutputSelected(null));
    } else if (key.startsWith('speaker_')) {
      final device = key.substring(8);
      bloc.add(const ModeChanged(false));
      bloc.add(OutputSelected(device));
    } else if (key == 'quit') {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      await windowManager.destroy();
      exit(0);
    }
  }

  Future<void> _updateTrayMenu(LoopbackState state) async {
    final isRunning = state.isRunning;
    final isVirtual = state.isVirtualMicMode;

    final Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: 'Buka Window NoisyBoy',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'status',
          label: isRunning
              ? '● Status: Aktif (${isVirtual ? "Meeting" : "Speaker"})'
              : '○ Status: Berhenti',
          disabled: true,
        ),
        MenuItem(
          key: 'toggle_mic',
          label: isRunning ? '⏹ Matikan NoisyBoy' : '▶ Nyalakan NoisyBoy',
        ),
        MenuItem.checkbox(
          key: 'toggle_denoise',
          label: 'AI Noise Suppression',
          checked: state.denoiseOn,
        ),
        MenuItem.separator(),
        MenuItem.submenu(
          key: 'mode_submenu',
          label: 'Mode: ${isVirtual ? "Meeting (Virtual Mic)" : "Speaker Test"}',
          submenu: Menu(
            items: [
              MenuItem.checkbox(
                key: 'mode_meeting',
                label: 'Meeting Mode (Virtual Mic)',
                checked: isVirtual,
              ),
              MenuItem.checkbox(
                key: 'mode_speaker',
                label: 'Speaker Test Mode (Headset)',
                checked: !isVirtual,
              ),
            ],
          ),
        ),
        MenuItem.submenu(
          key: 'mic_submenu',
          label: 'Input: ${state.selectedDevice ?? "Mic Default"}',
          submenu: Menu(
            items: [
              MenuItem.checkbox(
                key: 'mic_default',
                label: 'Mic Default Sistem',
                checked: state.selectedDevice == null,
              ),
              ...state.devices.map(
                (d) => MenuItem.checkbox(
                  key: 'mic_$d',
                  label: d,
                  checked: state.selectedDevice == d,
                ),
              ),
            ],
          ),
        ),
        MenuItem.submenu(
          key: 'output_submenu',
          label: isVirtual
              ? 'Output: ${state.virtualDeviceName ?? "NoisyBoy Audio"} (Virtual)'
              : 'Output: ${state.selectedOutput ?? "Speaker Default"}',
          submenu: Menu(
            items: [
              MenuItem.checkbox(
                key: 'speaker_default',
                label: 'Speaker Default Sistem',
                checked: !isVirtual && state.selectedOutput == null,
              ),
              ...state.outputDevices.map(
                (d) => MenuItem.checkbox(
                  key: 'speaker_$d',
                  label: d,
                  checked: !isVirtual && state.selectedOutput == d,
                ),
              ),
            ],
          ),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Keluar NoisyBoy (Quit)',
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<LoopbackBloc, LoopbackState>(
      listener: (context, state) {
        _updateTrayMenu(state);
      },
      child: widget.child,
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0A14),
      body: Stack(
        children: [
          // Background ambient gradient glow
          Positioned(
            top: -100,
            left: -50,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF6C5CE7).withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            right: -50,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF00CEC9).withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: BlocBuilder<LoopbackBloc, LoopbackState>(
                    builder: (context, state) {
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const _Header(),
                          const SizedBox(height: 18),
                          _DriverBanner(state: state),
                          const SizedBox(height: 14),
                          _ModeSegmentedControl(state: state),
                          const SizedBox(height: 16),
                          _DeviceSection(state: state),
                          const SizedBox(height: 22),
                          _ReactiveMicButton(state: state),
                          const SizedBox(height: 20),
                          _AudioLevelVisualizer(state: state),
                          const SizedBox(height: 16),
                          _DenoiseToggleCard(state: state),
                          const SizedBox(height: 16),
                          _StatusPill(state: state),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFFA29BFE), Color(0xFF6C5CE7)],
              ).createShader(bounds),
              child: const Text(
                'NoisyBoy',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.8,
                ),
              ),
            ),
            Text(
              'Real-Time AI Noise Suppression',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.45),
                letterSpacing: 1.2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: 'Sembunyikan ke Menu Bar',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                padding: const EdgeInsets.all(10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              icon: const Icon(Icons.vertical_align_top_rounded,
                  color: Colors.white70, size: 20),
              onPressed: () => windowManager.hide(),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Refresh Perangkat Audio',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                padding: const EdgeInsets.all(10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              icon: const Icon(Icons.refresh_rounded,
                  color: Color(0xFFA29BFE), size: 20),
              onPressed: () =>
                  context.read<LoopbackBloc>().add(const RefreshDevices()),
            ),
          ],
        ),
      ],
    );
  }
}

class _DriverBanner extends StatelessWidget {
  final LoopbackState state;
  const _DriverBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final installed = state.isVirtualDriverInstalled;
    final deviceName = state.virtualDeviceName ?? 'NoisyBoy Audio';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: installed
            ? const Color(0xFF00B894).withValues(alpha: 0.08)
            : const Color(0xFFE17055).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: installed
              ? const Color(0xFF00B894).withValues(alpha: 0.25)
              : const Color(0xFFE17055).withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            color: installed ? const Color(0xFF00B894) : const Color(0xFFE17055),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  installed
                      ? 'Virtual Driver Terpasang ($deviceName)'
                      : 'Virtual Driver Belum Terinstall',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: installed
                        ? const Color(0xFF55EFC4)
                        : const Color(0xFFFAB1A0),
                  ),
                ),
                Text(
                  installed
                      ? 'Pilih "$deviceName" sebagai Microphone di Zoom/Meet/Discord'
                      : 'Jalankan: sudo bash driver/install_driver.sh',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSegmentedControl extends StatelessWidget {
  final LoopbackState state;
  const _ModeSegmentedControl({required this.state});

  @override
  Widget build(BuildContext context) {
    final isVirtual = state.isVirtualMicMode;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SegmentTab(
              icon: Icons.videocam_rounded,
              title: 'Meeting Mode',
              subtitle: 'Kirim ke Meet/Zoom',
              selected: isVirtual,
              onTap: () {
                context.read<LoopbackBloc>().add(const ModeChanged(true));
              },
            ),
          ),
          Expanded(
            child: _SegmentTab(
              icon: Icons.headphones_rounded,
              title: 'Speaker Test',
              subtitle: 'Dengar di Headset',
              selected: !isVirtual,
              onTap: () {
                context.read<LoopbackBloc>().add(const ModeChanged(false));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentTab({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF6C5CE7).withValues(alpha: 0.35)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFF9F8FFF).withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.white : Colors.white54,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 10,
                color: selected
                    ? Colors.white.withValues(alpha: 0.8)
                    : Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  final LoopbackState state;
  const _DeviceSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final isVirtual = state.isVirtualMicMode;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          _DropdownRow(
            icon: Icons.mic_rounded,
            label: 'Input Microphone',
            value: state.selectedDevice,
            hint: 'Mic Default Sistem',
            items: state.devices,
            onChanged: (val) =>
                context.read<LoopbackBloc>().add(DeviceSelected(val)),
          ),
          if (!isVirtual) ...[
            const Divider(height: 18, thickness: 1, color: Colors.white10),
            _DropdownRow(
              icon: Icons.speaker_rounded,
              label: 'Output Speaker / Monitor',
              value: state.selectedOutput,
              hint: 'Speaker Default Sistem',
              items: state.outputDevices,
              onChanged: (val) =>
                  context.read<LoopbackBloc>().add(OutputSelected(val)),
            ),
          ] else ...[
            const Divider(height: 18, thickness: 1, color: Colors.white10),
            Row(
              children: [
                const Icon(Icons.route_rounded,
                    color: Color(0xFF55EFC4), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Output diarahkan otomatis ke Virtual Mic (${state.virtualDeviceName ?? "NoisyBoy Audio"})',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final String hint;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: const Color(0xFFA29BFE), size: 15),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: value,
            isExpanded: true,
            dropdownColor: const Color(0xFF1E1B33),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white54, size: 18),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            hint: Text(hint,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(hint, overflow: TextOverflow.ellipsis),
              ),
              ...items.map(
                (d) => DropdownMenuItem<String?>(
                  value: d,
                  child: Text(d, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _ReactiveMicButton extends StatelessWidget {
  final LoopbackState state;
  const _ReactiveMicButton({required this.state});

  @override
  Widget build(BuildContext context) {
    final isRunning = state.isRunning;
    final level = isRunning ? (state.inputLevel.clamp(0.0, 1.0)) : 0.0;
    final glowSpread = isRunning ? (8.0 + (level * 22.0)) : 0.0;
    final glowBlur = isRunning ? (40.0 + (level * 35.0)) : 20.0;

    return GestureDetector(
      onTap: () => context.read<LoopbackBloc>().add(const LoopbackToggled()),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 155,
        height: 155,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: isRunning
                ? [
                    Color.lerp(
                        const Color(0xFF7C6FFF), const Color(0xFF00CEC9), level)!,
                    const Color(0xFF5A4BD6),
                  ]
                : [const Color(0xFF242036), const Color(0xFF151324)],
          ),
          boxShadow: [
            BoxShadow(
              color: isRunning
                  ? const Color(0xFF6C5CE7).withValues(
                      alpha: 0.45 + (level * 0.45).clamp(0.0, 0.5),
                    )
                  : Colors.black.withValues(alpha: 0.5),
              blurRadius: glowBlur,
              spreadRadius: glowSpread,
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (isRunning)
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 130 + (level * 18),
                height: 130 + (level * 18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2 + (level * 0.3)),
                    width: 2,
                  ),
                ),
              ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isRunning ? Icons.mic_rounded : Icons.mic_off_rounded,
                  size: 58,
                  color: isRunning
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 4),
                Text(
                  isRunning ? 'ACTIVE' : 'START',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: isRunning
                        ? Colors.white.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioLevelVisualizer extends StatelessWidget {
  final LoopbackState state;
  const _AudioLevelVisualizer({required this.state});

  @override
  Widget build(BuildContext context) {
    final isRunning = state.isRunning;
    final inLvl = isRunning ? state.inputLevel : 0.0;
    final outLvl = isRunning ? state.outputLevel : 0.0;
    final isDenoising = isRunning && state.denoiseOn && (inLvl > outLvl + 0.03);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE AUDIO LEVEL',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              if (isDenoising)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00CEC9).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF00CEC9).withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.shield_outlined,
                          color: Color(0xFF00CEC9), size: 11),
                      SizedBox(width: 4),
                      Text(
                        'Noise Filtered',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF00CEC9),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _MeterBar(
            label: 'Input',
            level: inLvl,
            gradient: const LinearGradient(
              colors: [Color(0xFF6C5CE7), Color(0xFFA29BFE), Color(0xFFFF7675)],
            ),
          ),
          const SizedBox(height: 8),
          _MeterBar(
            label: 'Clean',
            level: outLvl,
            gradient: const LinearGradient(
              colors: [Color(0xFF00B894), Color(0xFF55EFC4), Color(0xFF0984E3)],
            ),
          ),
        ],
      ),
    );
  }
}

class _MeterBar extends StatelessWidget {
  final String label;
  final double level;
  final Gradient gradient;

  const _MeterBar({
    required this.label,
    required this.level,
    required this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 9,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: level.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(gradient: gradient),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 32,
          child: Text(
            '${(level * 100).toInt()}%',
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
  }
}

class _DenoiseToggleCard extends StatelessWidget {
  final LoopbackState state;
  const _DenoiseToggleCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final on = state.denoiseOn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: on
              ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: on
                      ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  on ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                  color: on ? const Color(0xFFA29BFE) : Colors.white38,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AI Noise Suppression',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    on ? 'RNNoise + Intelligent VAD Gate' : 'Bypass / Unfiltered',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isError
                  ? Colors.redAccent
                  : (state.isRunning
                      ? const Color(0xFF4ADE80)
                      : Colors.white24),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              state.message,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

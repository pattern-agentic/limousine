import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/services_provider.dart';
import '../../../providers/workspace_provider.dart';

class ControlBar extends ConsumerStatefulWidget {
  final ClientServiceInfo service;
  const ControlBar({super.key, required this.service});

  @override
  ConsumerState<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends ConsumerState<ControlBar> {
  String? _selectedCommand;

  @override
  void initState() {
    super.initState();
    final commands = widget.service.service.commands;
    _selectedCommand =
        commands.containsKey('run') ? 'run' : commands.keys.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(serviceStatesProvider)[widget.service.id];
    final status = state?.status ?? ProcessStatus.stopped;
    final commands = widget.service.service.commands;
    final isRunning = status == ProcessStatus.running;

    return Container(
      height: 48,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xF00F172A), Color(0xD00F172A)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          Text(
            '${widget.service.moduleName} / ${widget.service.serviceName}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          if (isRunning) _statusPill(),
          const Spacer(),
          if (commands.length > 1) ...[
            _commandSelector(commands, isRunning),
            const SizedBox(width: 8),
          ],
          _mainButton(status, state),
        ],
      ),
    );
  }

  Widget _statusPill() {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF22C55E).withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF22C55E),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text('Running',
              style:
                  TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.8))),
        ],
      ),
    );
  }

  Widget _mainButton(ProcessStatus status, ServiceStateDto? state) {
    final notifier = ref.read(serviceStatesProvider.notifier);
    switch (status) {
      case ProcessStatus.running:
        final label = _stopLabel(state?.nextSignal ?? StopSignal.sigint);
        return _actionButton(
          icon: Icons.stop,
          label: label,
          onPressed: () => notifier.stop(widget.service.id),
          color: const Color(0xFFF43F5E),
        );
      case ProcessStatus.orphaned:
        return _actionButton(
          icon: Icons.dangerous,
          label: 'Kill',
          onPressed: () => notifier.killOrphan(widget.service.id),
          color: const Color(0xFFF97316),
        );
      case ProcessStatus.stopped:
        final cmd = _selectedCommand;
        return _actionButton(
          icon: Icons.play_arrow,
          label: 'Run',
          onPressed: cmd == null
              ? null
              : () => notifier.start(widget.service.id, command: cmd),
          color: const Color(0xFF22C55E),
        );
    }
  }

  String _stopLabel(StopSignal s) => switch (s) {
        StopSignal.sigint => 'Stop',
        StopSignal.sigterm => 'Stop (TERM)',
        StopSignal.sigkill => 'Stop (KILL)',
      };

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required Color color,
  }) {
    return SizedBox(
      height: 28,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          backgroundColor: color.withOpacity(0.16),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _commandSelector(Map<String, String> commands, bool isRunning) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButton<String>(
        value: _selectedCommand,
        underline: const SizedBox.shrink(),
        icon: Icon(Icons.arrow_drop_down,
            size: 18, color: Colors.white.withOpacity(0.7)),
        // textTheme.apply(bodyColor/displayColor) doesn't cover titleMedium,
        // which is what DropdownButton uses by default for its items —
        // without an explicit color we get black-on-dark in the popup.
        style: const TextStyle(fontSize: 12, color: Color(0xFFE5E7EB)),
        dropdownColor: const Color(0xFF0B1120),
        items: commands.keys
            .map((name) => DropdownMenuItem(value: name, child: Text(name)))
            .toList(),
        onChanged:
            isRunning ? null : (v) => setState(() => _selectedCommand = v),
      ),
    );
  }

}

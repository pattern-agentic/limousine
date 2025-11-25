import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/service_state.dart';
import '../../../providers/workspace_provider.dart';
import '../../../providers/services_provider.dart';
import '../dialogs/env_dialog.dart';
import '../dialogs/secrets_dialog.dart';

class ControlBar extends ConsumerStatefulWidget {
  final ServiceInfo serviceInfo;

  const ControlBar({super.key, required this.serviceInfo});

  @override
  ConsumerState<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends ConsumerState<ControlBar> {
  String? _selectedCommand;

  @override
  void initState() {
    super.initState();
    final commands = widget.serviceInfo.service.commands;
    _selectedCommand = commands.containsKey('run') ? 'run' : commands.keys.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final states = ref.watch(serviceStatesProvider);
    final state = states[widget.serviceInfo.id];
    final status = state?.status ?? ProcessStatus.stopped;
    final commands = widget.serviceInfo.service.commands;
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
            '${widget.serviceInfo.moduleName} / ${widget.serviceInfo.serviceName}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          if (isRunning) _buildStatusPill(),
          const Spacer(),
          if (commands.length > 1) ...[
            _buildCommandSelector(commands, status),
            const SizedBox(width: 8),
          ],
          _buildMainButton(status, state),
          const SizedBox(width: 8),
          _buildEnvMenu(context),
        ],
      ),
    );
  }

  Widget _buildStatusPill() {
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
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'Running',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainButton(ProcessStatus status, ServiceState? state) {
    switch (status) {
      case ProcessStatus.running:
        return _buildActionButton(
          icon: Icons.stop,
          label: state?.stopButtonLabel ?? 'Stop',
          onPressed: () => ref
              .read(serviceStatesProvider.notifier)
              .stopService(widget.serviceInfo.id),
          color: const Color(0xFFF43F5E),
        );
      case ProcessStatus.orphaned:
        return _buildActionButton(
          icon: Icons.dangerous,
          label: 'Kill',
          onPressed: () => ref
              .read(serviceStatesProvider.notifier)
              .killOrphanedProcess(widget.serviceInfo.id),
          color: const Color(0xFFF97316),
        );
      case ProcessStatus.stopped:
        final cmd = _selectedCommand != null
            ? widget.serviceInfo.service.commands[_selectedCommand]
            : null;
        return _buildActionButton(
          icon: Icons.play_arrow,
          label: 'Run',
          onPressed: cmd == null
              ? null
              : () => ref
                  .read(serviceStatesProvider.notifier)
                  .startService(widget.serviceInfo, cmd),
          color: const Color(0xFF22C55E),
        );
    }
  }

  Widget _buildActionButton({
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildCommandSelector(Map<String, String> commands, ProcessStatus status) {
    final isRunning = status == ProcessStatus.running;

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
        icon: Icon(
          Icons.arrow_drop_down,
          size: 18,
          color: Colors.white.withOpacity(0.7),
        ),
        style: const TextStyle(fontSize: 12),
        items: commands.keys.map((name) {
          return DropdownMenuItem(
            value: name,
            child: Text(name),
          );
        }).toList(),
        onChanged: isRunning
            ? null
            : (value) => setState(() => _selectedCommand = value),
      ),
    );
  }

  Widget _buildEnvMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: Colors.white.withOpacity(0.7),
      ),
      tooltip: 'More options',
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'env',
          child: Text('Environment variables...'),
        ),
        const PopupMenuItem(
          value: 'secrets',
          child: Text('Secrets...'),
        ),
      ],
      onSelected: (value) {
        if (value == 'env') {
          showDialog(
            context: context,
            builder: (_) => EnvDialog(serviceInfo: widget.serviceInfo),
          );
        } else if (value == 'secrets') {
          showDialog(
            context: context,
            builder: (_) => SecretsDialog(serviceInfo: widget.serviceInfo),
          );
        }
      },
    );
  }
}

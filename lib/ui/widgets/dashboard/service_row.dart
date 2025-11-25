import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/module.dart';
import '../../../models/service_state.dart';
import '../../../providers/workspace_provider.dart';
import '../../../providers/services_provider.dart';

class ServiceRow extends ConsumerWidget {
  final String projectPath;
  final String moduleName;
  final ModuleConfig moduleConfig;
  final Service service;

  const ServiceRow({
    super.key,
    required this.projectPath,
    required this.moduleName,
    required this.moduleConfig,
    required this.service,
  });

  String get serviceId => '$moduleName/${service.name}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final states = ref.watch(serviceStatesProvider);
    final state = states[serviceId];
    final status = state?.status ?? ProcessStatus.stopped;

    return ListTile(
      dense: true,
      leading: _StatusIndicator(status: status),
      title: Text(service.name),
      trailing: _buildControls(ref, status, state),
    );
  }

  Widget _buildControls(WidgetRef ref, ProcessStatus status, ServiceState? state) {
    final serviceInfo = ServiceInfo(
      projectName: '',
      projectPath: projectPath,
      moduleName: moduleName,
      moduleConfig: moduleConfig,
      serviceName: service.name,
      service: service,
    );

    switch (status) {
      case ProcessStatus.running:
        return FilledButton(
          onPressed: () =>
              ref.read(serviceStatesProvider.notifier).stopService(serviceId),
          child: Text(state?.stopButtonLabel ?? 'Stop'),
        );
      case ProcessStatus.orphaned:
        return FilledButton.tonal(
          onPressed: () => ref
              .read(serviceStatesProvider.notifier)
              .killOrphanedProcess(serviceId),
          child: const Text('Kill Orphan'),
        );
      case ProcessStatus.stopped:
        final runCmd = service.runCommand;
        if (runCmd == null) return const SizedBox.shrink();
        return FilledButton(
          onPressed: () => ref
              .read(serviceStatesProvider.notifier)
              .startService(serviceInfo, runCmd),
          child: const Text('Run'),
        );
    }
  }
}

class _StatusIndicator extends StatelessWidget {
  final ProcessStatus status;

  const _StatusIndicator({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (status) {
      ProcessStatus.running => (Colors.green, Icons.play_arrow),
      ProcessStatus.stopped => (Colors.grey, Icons.stop),
      ProcessStatus.orphaned => (Colors.orange, Icons.warning),
    };
    return Icon(icon, color: color, size: 20);
  }
}

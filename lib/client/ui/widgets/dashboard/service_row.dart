import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../../core/module.dart';
import '../../../providers/services_provider.dart';

class ServiceRow extends ConsumerWidget {
  final String serviceId;
  final Service service;
  final ModuleConfig moduleConfig;

  const ServiceRow({
    super.key,
    required this.serviceId,
    required this.service,
    required this.moduleConfig,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final states = ref.watch(serviceStatesProvider);
    final state = states[serviceId];
    final status = state?.status ?? ProcessStatus.stopped;

    return ListTile(
      dense: true,
      leading: _StatusIcon(status: status),
      title: Text(service.name),
      trailing: _controls(ref, status),
    );
  }

  Widget _controls(WidgetRef ref, ProcessStatus status) {
    switch (status) {
      case ProcessStatus.running:
        return FilledButton(
          onPressed: () =>
              ref.read(serviceStatesProvider.notifier).stop(serviceId),
          child: const Text('Stop'),
        );
      case ProcessStatus.orphaned:
        return FilledButton.tonal(
          onPressed: () =>
              ref.read(serviceStatesProvider.notifier).killOrphan(serviceId),
          child: const Text('Kill Orphan'),
        );
      case ProcessStatus.stopped:
        if (service.runCommand == null) return const SizedBox.shrink();
        return FilledButton(
          onPressed: () => ref
              .read(serviceStatesProvider.notifier)
              .start(serviceId, command: 'run'),
          child: const Text('Run'),
        );
    }
  }
}

class _StatusIcon extends StatelessWidget {
  final ProcessStatus status;
  const _StatusIcon({required this.status});

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

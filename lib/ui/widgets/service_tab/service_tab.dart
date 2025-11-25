import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/workspace_provider.dart';
import 'control_bar.dart';
import 'terminal_view.dart';

class ServiceTab extends ConsumerWidget {
  final ServiceInfo serviceInfo;

  const ServiceTab({super.key, required this.serviceInfo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF020617),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          ControlBar(serviceInfo: serviceInfo),
          const Divider(height: 1),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(16),
              ),
              child: TerminalPanel(serviceId: serviceInfo.id),
            ),
          ),
        ],
      ),
    );
  }
}

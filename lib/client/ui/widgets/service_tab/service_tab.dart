import 'package:flutter/material.dart';
import '../../../providers/workspace_provider.dart';
import 'control_bar.dart';
import 'terminal_view.dart';

class ServiceTab extends StatelessWidget {
  final ClientServiceInfo service;
  const ServiceTab({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF020617),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          ControlBar(service: service),
          const Divider(height: 1),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(16),
              ),
              child: TerminalPanel(serviceId: service.id),
            ),
          ),
        ],
      ),
    );
  }
}

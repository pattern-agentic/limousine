import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/secret_store_provider.dart';

class SecretStoreStatusIndicator extends ConsumerWidget {
  const SecretStoreStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(secretStoreProvider);
    final (color, label, tooltip) = _decorate(status);

    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(status), size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7)),
            ),
          ],
        ),
      ),
    );
  }

  IconData _icon(SecretStoreStatus s) => switch (s) {
        SecretStoreStatus.verified => Icons.lock_open,
        SecretStoreStatus.newStamp => Icons.fiber_new,
        SecretStoreStatus.mismatch => Icons.error_outline,
        SecretStoreStatus.missingPassword => Icons.lock,
        SecretStoreStatus.unknown => Icons.help_outline,
      };

  (Color, String, String) _decorate(SecretStoreStatus s) => switch (s) {
        SecretStoreStatus.verified => (
            const Color(0xFF22C55E),
            'secret store: verified',
            'Secret store unlocked and stamp verified.',
          ),
        SecretStoreStatus.newStamp => (
            const Color(0xFF22D3EE),
            'secret store: new',
            'New stamp created for this workspace. This password is now '
                'required for future starts.',
          ),
        SecretStoreStatus.mismatch => (
            const Color(0xFFF43F5E),
            'secret store: mismatch',
            'LIMOUSINE_SECRETS_PASSWORD did not match the stamp — the server '
                'should have exited. Refresh once it is restarted with the '
                'correct password.',
          ),
        SecretStoreStatus.missingPassword => (
            Colors.grey,
            'secret store: locked',
            'No secret-store password supplied at startup. Services with '
                'encrypted secrets cannot start. Restart with '
                'LIMOUSINE_SECRETS_PASSWORD set.',
          ),
        SecretStoreStatus.unknown => (
            Colors.grey,
            'secret store: …',
            'Secret-store status unknown (still hydrating).',
          ),
      };
}

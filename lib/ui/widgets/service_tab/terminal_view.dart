import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:xterm/ui.dart' as xterm_ui;
import '../../../providers/services_provider.dart';

class TerminalPanel extends ConsumerStatefulWidget {
  final String serviceId;

  const TerminalPanel({super.key, required this.serviceId});

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  double _fontSize = 13;
  final _terminalController = xterm.TerminalController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        ref.read(serviceStatesProvider.notifier).getOrCreate(widget.serviceId);
      }
    });
  }

  @override
  void dispose() {
    _terminalController.dispose();
    super.dispose();
  }

  void _copySelection() {
    final selection = _terminalController.selection;
    if (selection != null) {
      final state = ref.read(serviceStatesProvider)[widget.serviceId];
      if (state != null) {
        final text = state.terminal.buffer.getText(selection);
        Clipboard.setData(ClipboardData(text: text));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(serviceStatesProvider)[widget.serviceId];
    if (state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final terminalTheme = xterm_ui.TerminalTheme(
      cursor: const Color(0xFF22D3EE),
      selection: const Color(0x4022D3EE),
      foreground: const Color(0xFFE5E7EB),
      background: const Color(0xFF020617),
      black: const Color(0xFF1E293B),
      white: const Color(0xFFF1F5F9),
      red: const Color(0xFFF43F5E),
      green: const Color(0xFF22C55E),
      yellow: const Color(0xFFF59E0B),
      blue: const Color(0xFF3B82F6),
      magenta: const Color(0xFFA855F7),
      cyan: const Color(0xFF22D3EE),
      brightBlack: const Color(0xFF475569),
      brightRed: const Color(0xFFFB7185),
      brightGreen: const Color(0xFF4ADE80),
      brightYellow: const Color(0xFFFBBF24),
      brightBlue: const Color(0xFF60A5FA),
      brightMagenta: const Color(0xFFC084FC),
      brightCyan: const Color(0xFF67E8F9),
      brightWhite: const Color(0xFFFFFFFF),
      searchHitBackground: const Color(0xFF22D3EE),
      searchHitBackgroundCurrent: const Color(0xFF22C55E),
      searchHitForeground: const Color(0xFF020617),
    );

    return Stack(
      children: [
        Container(
          color: const Color(0xFF020617),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: xterm.TerminalView(
            state.terminal,
            controller: _terminalController,
            textStyle: xterm.TerminalStyle(
              fontSize: _fontSize,
              fontFamily: GoogleFonts.jetBrainsMono().fontFamily!,
            ),
            theme: terminalTheme,
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _buildToolbar(state.terminal),
        ),
      ],
    );
  }

  Widget _buildToolbar(xterm.Terminal terminal) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120).withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToolbarButton(
            icon: Icons.remove,
            tooltip: 'Decrease font',
            onPressed: () => setState(() => _fontSize = (_fontSize - 1).clamp(8, 24)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${_fontSize.toInt()}',
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7)),
            ),
          ),
          _buildToolbarButton(
            icon: Icons.add,
            tooltip: 'Increase font',
            onPressed: () => setState(() => _fontSize = (_fontSize + 1).clamp(8, 24)),
          ),
          const SizedBox(width: 4),
          _buildToolbarButton(
            icon: Icons.horizontal_rule,
            tooltip: 'Separator',
            onPressed: () => terminal.write('\r\n${'─' * 60}\r\n'),
          ),
          _buildToolbarButton(
            icon: Icons.delete_outline,
            tooltip: 'Clear',
            onPressed: () {
              terminal.write('\x1b[2J\x1b[H');
              terminal.buffer.clear();
            },
          ),
          _buildToolbarButton(
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onPressed: _copySelection,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(icon, color: Colors.white.withOpacity(0.7)),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

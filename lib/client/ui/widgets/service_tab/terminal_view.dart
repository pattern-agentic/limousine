import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:xterm/ui.dart' as xterm_ui;
import '../../../providers/terminal_provider.dart';

class TerminalPanel extends ConsumerStatefulWidget {
  final String serviceId;
  const TerminalPanel({super.key, required this.serviceId});

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  double _fontSize = 13;
  final _controller = xterm.TerminalController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _copySelection(xterm.Terminal terminal) {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = terminal.buffer.getText(selection);
    Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(serviceTerminalProvider(widget.serviceId));
    final terminal = session.terminal;

    return Stack(
      children: [
        Container(
          color: const Color(0xFF020617),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: xterm.TerminalView(
            terminal,
            controller: _controller,
            textStyle: xterm.TerminalStyle(
              fontSize: _fontSize,
              fontFamily: GoogleFonts.jetBrainsMono().fontFamily!,
            ),
            theme: _theme,
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _toolbar(terminal),
        ),
      ],
    );
  }

  static const xterm_ui.TerminalTheme _theme = xterm_ui.TerminalTheme(
    cursor: Color(0xFF22D3EE),
    selection: Color(0x4022D3EE),
    foreground: Color(0xFFE5E7EB),
    background: Color(0xFF020617),
    black: Color(0xFF1E293B),
    white: Color(0xFFF1F5F9),
    red: Color(0xFFF43F5E),
    green: Color(0xFF22C55E),
    yellow: Color(0xFFF59E0B),
    blue: Color(0xFF3B82F6),
    magenta: Color(0xFFA855F7),
    cyan: Color(0xFF22D3EE),
    brightBlack: Color(0xFF475569),
    brightRed: Color(0xFFFB7185),
    brightGreen: Color(0xFF4ADE80),
    brightYellow: Color(0xFFFBBF24),
    brightBlue: Color(0xFF60A5FA),
    brightMagenta: Color(0xFFC084FC),
    brightCyan: Color(0xFF67E8F9),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF22D3EE),
    searchHitBackgroundCurrent: Color(0xFF22C55E),
    searchHitForeground: Color(0xFF020617),
  );

  Widget _toolbar(xterm.Terminal terminal) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120).withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn(Icons.remove, 'Smaller', () => setState(() => _fontSize = (_fontSize - 1).clamp(8, 24))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('${_fontSize.toInt()}',
                style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7))),
          ),
          _btn(Icons.add, 'Larger', () => setState(() => _fontSize = (_fontSize + 1).clamp(8, 24))),
          const SizedBox(width: 4),
          _btn(Icons.horizontal_rule, 'Separator',
              () => terminal.write('\r\n${'─' * 60}\r\n')),
          _btn(Icons.delete_outline, 'Clear', () {
            terminal.write('\x1b[2J\x1b[H');
            terminal.buffer.clear();
          }),
          _btn(Icons.copy_outlined, 'Copy', () => _copySelection(terminal)),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, String tooltip, VoidCallback onPressed) {
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

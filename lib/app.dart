import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/workspace_provider.dart';
import 'ui/screens/startup_screen.dart';
import 'ui/screens/main_screen.dart';

class LimousineApp extends ConsumerWidget {
  const LimousineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspacePath = ref.watch(currentWorkspacePathProvider);

    final theme = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF020617),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF22D3EE),
        secondary: Color(0xFF22C55E),
        surface: Color(0xFF0B1120),
        onSurface: Color(0xFFE5E7EB),
      ),
      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: const Color(0xFFE5E7EB),
        displayColor: const Color(0xFFE5E7EB),
      ),
      dividerColor: const Color(0x3394A3B8),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF020617),
        elevation: 0,
      ),
    );

    return MaterialApp(
      title: 'Limousine',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: workspacePath == null
          ? const StartupScreen()
          : const MainScreen(),
    );
  }
}

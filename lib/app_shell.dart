import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:gotohp_rs/about_page.dart';
import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/accounts_page.dart';
import 'package:gotohp_rs/home_page.dart';
import 'package:gotohp_rs/settings_page.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/theme_controller.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.theme});

  final ThemeController theme;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _running = false;
  Timer? _statusTimer;

  static const _titles = ['Upload', 'Settings', 'Accounts', 'About'];

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final running = await isUploadRunning();
        if (mounted && running != _running) setState(() => _running = running);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _go(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pages = <Widget>[
      HomePage(onOpenSettings: () => _go(1)),
      SettingsPage(theme: widget.theme),
      const AccountsPage(),
      const AboutPage(),
    ];
    final active = AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.025), end: Offset.zero).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
    );

    final appBar = AppBar(
      leading: wide ? null : const PixieLogo(size: 26),
      title: Text(
        _titles[_index],
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
      ),
      actions: [
        _statusPill(cs),
        IconButton(
          tooltip: 'Cycle theme mode',
          icon: Icon(
            switch (widget.theme.mode) {
              PixieThemeMode.system => Icons.brightness_auto_outlined,
              PixieThemeMode.light => Icons.light_mode_outlined,
              PixieThemeMode.dark => Icons.dark_mode_outlined,
            },
          ),
          onPressed: () {
            final next = switch (widget.theme.mode) {
              PixieThemeMode.system => PixieThemeMode.light,
              PixieThemeMode.light => PixieThemeMode.dark,
              PixieThemeMode.dark => PixieThemeMode.system,
            };
            widget.theme.setMode(next);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Theme: ${switch (next) {
                  PixieThemeMode.system => 'System',
                  PixieThemeMode.light => 'Light',
                  PixieThemeMode.dark => 'Dark',
                }}'),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => _go(1),
        ),
        const SizedBox(width: 6),
      ],
    );

    if (!wide) {
      return Scaffold(
        appBar: appBar,
        body: active,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _go,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.cloud_upload_outlined), label: 'Upload'),
            NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Settings'),
            NavigationDestination(icon: Icon(Icons.account_circle_outlined), label: 'Accounts'),
            NavigationDestination(icon: Icon(Icons.info_outline), label: 'About'),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          NavigationRail(
            extended: MediaQuery.sizeOf(context).width >= 1100,
            selectedIndex: _index,
            onDestinationSelected: _go,
            leading: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 24),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const PixieLogo(size: 36),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pixie',
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ],
              ),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.cloud_upload_outlined), label: Text('Upload')),
              NavigationRailDestination(icon: Icon(Icons.tune_rounded), label: Text('Settings')),
              NavigationRailDestination(icon: Icon(Icons.account_circle_outlined), label: Text('Accounts')),
              NavigationRailDestination(icon: Icon(Icons.info_outline), label: Text('About')),
            ],
          ),
          VerticalDivider(width: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
          Expanded(child: active),
        ],
      ),
    );
  }

  Widget _statusPill(ColorScheme cs) {
    final color = _running ? Colors.orange.shade700 : Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(
            _running ? 'Uploading' : 'Ready',
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

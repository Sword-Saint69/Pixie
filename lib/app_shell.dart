import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:gotohp_rs/about_page.dart';
import 'package:gotohp_rs/accounts_page.dart';
import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/design.dart';
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
  bool _paused = false;
  int _done = 0;
  int _total = 0;
  String _account = '';
  int _accountCount = 0;
  Timer? _statusTimer;

  static const _titles = ['Upload', 'Settings', 'Accounts', 'About'];

  @override
  void initState() {
    super.initState();
    _loadAccount();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final running = await isUploadRunning();
        final paused = await isUploadPaused();
        final needSummary = running || _total > 0;
        final summary = needSummary ? await getSummary() : null;
        if (mounted) {
          setState(() {
            _running = running;
            _paused = paused;
            if (summary != null) {
              _done = summary.succeeded + summary.skipped + summary.failed;
              _total = summary.total;
            }
          });
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    try {
      final email = await selectedAccount();
      final accounts = await listAccounts();
      if (mounted) {
        setState(() {
          _account = email;
          _accountCount = accounts.length;
        });
      }
    } catch (_) {}
  }

  void _go(int index) {
    if (index == 2) _loadAccount();
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 640;
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
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(animation),
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
          icon: Icon(switch (widget.theme.mode) {
            PixieThemeMode.system => Icons.brightness_auto_outlined,
            PixieThemeMode.light => Icons.light_mode_outlined,
            PixieThemeMode.dark => Icons.dark_mode_outlined,
          }),
          onPressed: () {
            final next = switch (widget.theme.mode) {
              PixieThemeMode.system => PixieThemeMode.light,
              PixieThemeMode.light => PixieThemeMode.dark,
              PixieThemeMode.dark => PixieThemeMode.system,
            };
            widget.theme.setMode(next);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Theme: ${switch (next) {
                    PixieThemeMode.system => 'System',
                    PixieThemeMode.light => 'Light',
                    PixieThemeMode.dark => 'Dark',
                  }}',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
        const SizedBox(width: 8),
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
            NavigationDestination(
              icon: Icon(Icons.cloud_upload_outlined),
              label: 'Upload',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_circle_outlined),
              label: 'Accounts',
            ),
            NavigationDestination(
              icon: Icon(Icons.info_outline),
              label: 'About',
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          _Sidebar(
            index: _index,
            onSelect: _go,
            dark: widget.theme.mode == PixieThemeMode.dark,
            onDarkToggle: (value) => widget.theme.setMode(
              value ? PixieThemeMode.dark : PixieThemeMode.light,
            ),
            email: _account,
            accountCount: _accountCount,
            onAccounts: () => _go(2),
          ),
          VerticalDivider(
            width: 1,
            color: cs.outlineVariant.withValues(alpha: 0.4),
          ),
          Expanded(child: active),
        ],
      ),
    );
  }

  Widget _statusPill(ColorScheme cs) {
    final color = _paused
        ? Colors.amber.shade700
        : _running
        ? Colors.blue.shade700
        : Colors.green.shade700;
    final label = _paused
        ? 'Paused'
        : _running
        ? 'Uploading $_done/$_total'
        : _total > 0
        ? 'Last run: $_done/$_total'
        : 'Ready';
    return GestureDetector(
      onTap: () => _go(0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.index,
    required this.onSelect,
    required this.dark,
    required this.onDarkToggle,
    required this.email,
    required this.accountCount,
    required this.onAccounts,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool dark;
  final ValueChanged<bool> onDarkToggle;
  final String email;
  final int accountCount;
  final VoidCallback onAccounts;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 224,
      color: cs.surface,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const PixieLogo(size: 32),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pixie',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                      ),
                    ),
                    Text(
                      'photo cloud',
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _accountCard(cs),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: MicroLabel('Workspace'),
          ),
          const SizedBox(height: 8),
          _tile(0, Icons.cloud_upload_outlined, 'Upload', cs),
          _tile(2, Icons.account_circle_outlined, 'Accounts', cs),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: MicroLabel('Tools'),
          ),
          const SizedBox(height: 8),
          _tile(1, Icons.tune_rounded, 'Settings', cs),
          const Spacer(),
          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              secondary: Icon(
                dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              title: Text(
                'Dark mode',
                style: TextStyle(fontSize: 12, color: cs.onSurface),
              ),
              value: dark,
              onChanged: onDarkToggle,
            ),
          ),
          _tile(3, Icons.info_outline, 'About', cs),
        ],
      ),
    );
  }

  Widget _accountCard(ColorScheme cs) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onAccounts,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: cs.primary.withValues(alpha: 0.14),
              child: Text(
                email.isEmpty ? '?' : email[0].toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    email.isEmpty ? 'No account' : email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  Text(
                    '$accountCount account(s)',
                    style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _tile(int value, IconData icon, String label, ColorScheme cs) {
    final selected = index == value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () => onSelect(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.11)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

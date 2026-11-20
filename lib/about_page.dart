import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/design.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutState();
}

class _AboutState extends State<AboutPage> {
  static const _repo = 'https://github.com/Sword-Saint69/Pixie';

  CoreInfo? _info;
  String _configPath = '';

  @override
  void initState() {
    super.initState();
    coreInfo()
        .then((info) {
          if (mounted) setState(() => _info = info);
        })
        .catchError((_) {});
    configPath()
        .then((path) {
          if (mounted) setState(() => _configPath = path);
        })
        .catchError((_) {});
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open link'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _copyDebugInfo() async {
    final info = _info;
    final text = [
      'Pixie debug info',
      'version: ${info?.crateVersion ?? 'unknown'}',
      'bridge: ${info?.bridgeVersion ?? 'unknown'}',
      'target: ${info?.target ?? 'unknown'}',
      'features: ${info?.features ?? 'unknown'}',
      'config: $_configPath',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Debug info copied'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              const SizedBox(height: 16),
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: const PixieLogo(size: 80),
              ),
              const SizedBox(height: 14),
              Text(
                'Pixie',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Photo cloud uploader · Rust core',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              PixieCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MicroLabel('Changelog'),
                    const SizedBox(height: 10),
                    _change(
                      '0.1.0',
                      'Rust upload core, Flutter shell, themes, preflight and live progress.',
                    ),
                    _change(
                      '0.0.2',
                      'Android config path and TLS trust fixes.',
                    ),
                    _change('0.0.1', 'Initial build with embedded credential.'),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: () => _open('$_repo/releases'),
                      icon: const Icon(Icons.system_update_outlined, size: 16),
                      label: const Text('Check for updates'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PixieCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MicroLabel('Support'),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _open('$_repo/issues/new'),
                        icon: const Icon(Icons.bug_report_outlined, size: 17),
                        label: const Text('Report a bug or give feedback'),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _copyDebugInfo,
                        icon: const Icon(Icons.copy_all_outlined, size: 17),
                        label: const Text('Copy debug info'),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _open('$_repo/blob/main/pubspec.lock'),
                        icon: const Icon(Icons.gavel_outlined, size: 17),
                        label: const Text('Licenses and dependencies'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PixieCard(
                padding: 0,
                child: ExpansionTile(
                  title: const MicroLabel('Advanced info'),
                  iconColor: cs.primary,
                  collapsedIconColor: cs.onSurfaceVariant,
                  children: [
                    if (_info == null)
                      const SizedBox(
                        height: 48,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                        child: Column(
                          children: [
                            _row('Version', _info!.crateVersion, cs),
                            _row('Bridge', _info!.bridgeVersion, cs),
                            _row('Target', _info!.target, cs),
                            _row('Features', _info!.features, cs),
                            _row('Config', _configPath, cs),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _change(String version, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            version,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _row(String label, String value, ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        MicroLabel(label),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: cs.onSurface),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

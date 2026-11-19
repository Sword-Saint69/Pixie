import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/design.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:material_ui/material_ui.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutState();
}

class _AboutState extends State<AboutPage> {
  CoreInfo? _info;

  @override
  void initState() {
    super.initState();
    coreInfo().then((info) {
      if (mounted) setState(() => _info = info);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              const SizedBox(height: 26),
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const PixieLogo(size: 92),
              ),
              const SizedBox(height: 18),
              Text('Pixie', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface)),
              const SizedBox(height: 4),
              Text('Photo cloud uploader · Rust core',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 26),
              PixieCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MicroLabel('Rust core'),
                    const SizedBox(height: 12),
                    Text('Built with Flutter and Rust',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface)),
                    const SizedBox(height: 8),
                    Text(
                      'Authentication, protobuf protocol, hashing, the upload worker pool and progress accounting all run in Rust and are shared with the gotohp-rs CLI.',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    if (_info == null)
                      const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()))
                    else
                      Column(
                        children: [
                          _row('Version', _info!.crateVersion, cs),
                          _row('Bridge', _info!.bridgeVersion, cs),
                          _row('Target', _info!.target, cs),
                          _row('Features', _info!.features, cs),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            MicroLabel(label),
            const Spacer(),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: cs.onSurface),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}

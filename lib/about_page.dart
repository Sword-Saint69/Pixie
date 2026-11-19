import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/design.dart';
import 'package:material_ui/material_ui.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
              const SizedBox(height: 30),
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const PixieLogo(size: 92),
              ),
              const SizedBox(height: 20),
              Text('Pixie', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface)),
              const SizedBox(height: 4),
              Text('Photo cloud uploader · Rust core', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
              PixieCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Built with Flutter and Rust', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cs.onSurface)),
                      const SizedBox(height: 8),
                      Text(
                        'The upload pipeline, authentication and protobuf protocol are implemented in Rust and shared by this app and the gotohp-rs CLI. The interface is Flutter.',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Version 0.1.0 · flutter_rust_bridge 2.13.0',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
}

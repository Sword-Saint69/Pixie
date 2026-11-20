import 'package:material_ui/material_ui.dart';

/// The Pixie mascot, used in the shell, empty state and About page.
class PixieLogo extends StatelessWidget {
  const PixieLogo({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/pixie_logo.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
  );
}

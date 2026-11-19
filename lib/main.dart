import 'package:gotohp_rs/home_page.dart';
import 'package:gotohp_rs/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const GotohpApp());
}

class GotohpApp extends StatelessWidget {
  const GotohpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gotohp-rs',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

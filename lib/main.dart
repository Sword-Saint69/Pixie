import 'package:material_ui/material_ui.dart';
import 'package:gotohp_rs/app_shell.dart';
import 'package:gotohp_rs/src/rust/frb_generated.dart';
import 'package:gotohp_rs/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final theme = ThemeController();
  await theme.load();
  runApp(PixieApp(theme: theme));
}

class PixieApp extends StatelessWidget {
  const PixieApp({super.key, required this.theme});

  final ThemeController theme;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) => MaterialApp(
        title: 'Pixie',
        debugShowCheckedModeBanner: false,
        themeMode: theme.themeMode,
        theme: theme.lightTheme(),
        darkTheme: theme.darkTheme(),
        home: AppShell(theme: theme),
      ),
    );
  }
}

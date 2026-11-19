import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:gotohp_rs/main.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/frb_generated.dart';
import 'package:gotohp_rs/theme_controller.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('bridge reads config from Rust', (tester) async {
    final path = await configPath();
    expect(path, isNotEmpty);
    expect(path, endsWith('gotohp.config'));

    final settings = await getSettings();
    expect(settings.uploadThreads, greaterThanOrEqualTo(1));
    expect(settings.proxy, isA<String>());

    final accounts = await listAccounts();
    expect(accounts, isA<List>());
  });

  testWidgets('Pixie shell, sidebar and settings page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(PixieApp(theme: ThemeController()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Send your photos to the cloud'), findsOneWidget);
    expect(find.textContaining('Drop photos, videos or folders here'), findsOneWidget);
    expect(find.text('Upload'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Accounts'), findsWidgets);
    expect(find.text('About'), findsWidgets);

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Make Pixie yours'), findsOneWidget);
    expect(find.textContaining('Appearance'), findsWidgets);
    expect(find.textContaining('ACCENT'), findsOneWidget);
  });
}

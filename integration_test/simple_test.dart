import 'package:flutter_test/flutter_test.dart';
import 'package:gotohp_rs/main.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/frb_generated.dart';
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

  testWidgets('app shell renders all three panels', (tester) async {
    await tester.pumpWidget(const GotohpApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('Account'), findsWidgets);
    expect(find.textContaining('Upload settings'), findsOneWidget);
    expect(find.textContaining('Upload queue'), findsOneWidget);
    expect(find.textContaining('Live progress'), findsOneWidget);
  });
}

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PixieThemeMode { system, light, dark }

enum PixieAccent { violet, teal, rose, ocean }

class ThemeController extends ChangeNotifier {
  static const _modeKey = 'pixie.theme_mode';
  static const _accentKey = 'pixie.accent';

  PixieThemeMode _mode = PixieThemeMode.system;
  PixieAccent _accent = PixieAccent.violet;

  PixieThemeMode get mode => _mode;
  PixieAccent get accent => _accent;

  ThemeMode get themeMode => switch (_mode) {
        PixieThemeMode.system => ThemeMode.system,
        PixieThemeMode.light => ThemeMode.light,
        PixieThemeMode.dark => ThemeMode.dark,
      };

  Color get accentColor => switch (_accent) {
        PixieAccent.violet => const Color(0xFF7C3AED),
        PixieAccent.teal => const Color(0xFF0F8B8D),
        PixieAccent.rose => const Color(0xFFE11D48),
        PixieAccent.ocean => const Color(0xFF2563EB),
      };

  String get modeLabel => switch (_mode) {
        PixieThemeMode.system => 'System',
        PixieThemeMode.light => 'Light',
        PixieThemeMode.dark => 'Dark',
      };

  String get accentLabel => switch (_accent) {
        PixieAccent.violet => 'Violet',
        PixieAccent.teal => 'Teal',
        PixieAccent.rose => 'Rose',
        PixieAccent.ocean => 'Ocean',
      };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = PixieThemeMode.values.firstWhere(
      (m) => m.name == prefs.getString(_modeKey),
      orElse: () => PixieThemeMode.system,
    );
    _accent = PixieAccent.values.firstWhere(
      (a) => a.name == prefs.getString(_accentKey),
      orElse: () => PixieAccent.violet,
    );
    notifyListeners();
  }

  Future<void> setMode(PixieThemeMode mode) async {
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
    notifyListeners();
  }

  Future<void> setAccent(PixieAccent accent) async {
    _accent = accent;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, accent.name);
    notifyListeners();
  }

  ThemeData lightTheme() => _theme(Brightness.light);
  ThemeData darkTheme() => _theme(Brightness.dark);

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: accentColor, brightness: brightness);
    final scheme = dark
        ? base.copyWith(
            primary: Color.lerp(accentColor, Colors.white, 0.38)!,
            surface: const Color(0xFF151A1E),
            surfaceContainerLowest: const Color(0xFF0D1114),
            surfaceContainerLow: const Color(0xFF11171B),
            surfaceContainer: const Color(0xFF1A2025),
            surfaceContainerHigh: const Color(0xFF212830),
            surfaceContainerHighest: const Color(0xFF29323A),
            outline: const Color(0xFF3B474F),
            outlineVariant: const Color(0xFF2B343B),
            onSurface: const Color(0xFFE9EEF1),
            onSurfaceVariant: const Color(0xFF9AA9B1),
          )
        : base;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF0C1013) : const Color(0xFFF4F6F8),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: dark ? const Color(0xFF11161A) : Colors.white,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF191F24) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: dark ? const Color(0xFF2B343B) : Colors.grey.shade200),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xFF2B343B) : Colors.grey.shade200,
        space: 1,
        thickness: 1,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark ? const Color(0xFF11161A) : Colors.white,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF11161A) : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
      ),
      sliderTheme: SliderThemeData(activeTrackColor: scheme.primary, thumbColor: scheme.primary),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF14181B),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1B2228) : const Color(0xFFF4F6F8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: dark ? const Color(0xFF334048) : Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: dark ? const Color(0xFF334048) : Colors.grey.shade300),
        ),
      ),
    );
  }

}

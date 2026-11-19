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
    final scheme = ColorScheme.fromSeed(seedColor: accentColor, brightness: brightness);
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF111417) : const Color(0xFFF4F6F8),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: dark ? const Color(0xFF171B1F) : Colors.white,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1A1F24) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: dark ? Colors.white12 : Colors.grey.shade200),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark ? const Color(0xFF171B1F) : Colors.white,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF171B1F) : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: 0.15),
      ),
      sliderTheme: SliderThemeData(activeTrackColor: scheme.primary, thumbColor: scheme.primary),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF20262C) : const Color(0xFFF4F6F8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: dark ? Colors.white12 : Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: dark ? Colors.white12 : Colors.grey.shade300),
        ),
      ),
    );
  }
}

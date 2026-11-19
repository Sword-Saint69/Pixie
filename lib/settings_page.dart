import 'package:material_ui/material_ui.dart';
import 'package:gotohp_rs/design.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:gotohp_rs/theme_controller.dart';

enum _Section { appearance, upload, advanced }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.theme});

  final ThemeController theme;

  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  _Section _section = _Section.appearance;
  AppSettings? _settings;
  String _configPath = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await getSettings();
      final path = await configPath();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _configPath = path;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save(AppSettings next) async {
    setState(() => _settings = next);
    try {
      await saveSettings(settings: next);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  AppSettings _copy({
    String? proxy,
    bool? useQuota,
    bool? saver,
    bool? recursive,
    bool? forceUpload,
    bool? pairLivePhotos,
    bool? skipIncompleteLivePhotos,
    bool? updateExistingPhotosToLive,
    int? uploadThreads,
    bool? deleteFromHost,
    bool? disableUnsupportedFilesFilter,
    bool? setDateFromFilename,
    String? excludePattern,
  }) {
    final s = _settings!;
    return AppSettings(
      proxy: proxy ?? s.proxy,
      useQuota: useQuota ?? s.useQuota,
      saver: saver ?? s.saver,
      recursive: recursive ?? s.recursive,
      forceUpload: forceUpload ?? s.forceUpload,
      pairLivePhotos: pairLivePhotos ?? s.pairLivePhotos,
      skipIncompleteLivePhotos: skipIncompleteLivePhotos ?? s.skipIncompleteLivePhotos,
      updateExistingPhotosToLive: updateExistingPhotosToLive ?? s.updateExistingPhotosToLive,
      uploadThreads: uploadThreads ?? s.uploadThreads,
      deleteFromHost: deleteFromHost ?? s.deleteFromHost,
      disableUnsupportedFilesFilter: disableUnsupportedFilesFilter ?? s.disableUnsupportedFilesFilter,
      setDateFromFilename: setDateFromFilename ?? s.setDateFromFilename,
      excludePattern: excludePattern ?? s.excludePattern,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MicroLabel('Preferences'),
              const SizedBox(height: 6),
              Text(
                'Make Pixie yours',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: cs.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                'Appearance and upload behaviour, in one place.',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              _settingsBar(cs),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              if (_settings == null)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                PixieCard(
                  child: switch (_section) {
                    _Section.appearance => _appearance(cs),
                    _Section.upload => _upload(cs),
                    _Section.advanced => _advanced(cs),
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsBar(ColorScheme cs) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            for (final section in _Section.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      color: _section == section ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: TextButton.icon(
                      onPressed: () => setState(() => _section = section),
                      icon: Icon(
                        switch (section) {
                          _Section.appearance => Icons.palette_outlined,
                          _Section.upload => Icons.cloud_upload_outlined,
                          _Section.advanced => Icons.tune_rounded,
                        },
                        size: 17,
                        color: _section == section ? cs.primary : cs.onSurfaceVariant,
                      ),
                      label: Text(
                        switch (section) {
                          _Section.appearance => 'Appearance',
                          _Section.upload => 'Upload',
                          _Section.advanced => 'Advanced',
                        },
                        style: TextStyle(
                          color: _section == section ? cs.primary : cs.onSurfaceVariant,
                          fontWeight: _section == section ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _appearance(ColorScheme cs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('THEME', 'Choose how Pixie looks on this device', cs),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final mode in PixieThemeMode.values)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: mode == PixieThemeMode.dark ? 0 : 10),
                    child: _choiceCard(
                      selected: widget.theme.mode == mode,
                      icon: switch (mode) {
                        PixieThemeMode.system => Icons.brightness_auto_outlined,
                        PixieThemeMode.light => Icons.light_mode_outlined,
                        PixieThemeMode.dark => Icons.dark_mode_outlined,
                      },
                      label: switch (mode) {
                        PixieThemeMode.system => 'System',
                        PixieThemeMode.light => 'Light',
                        PixieThemeMode.dark => 'Dark',
                      },
                      cs: cs,
                      onTap: () => widget.theme.setMode(mode),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _sectionTitle('ACCENT', 'A splash of colour across the interface', cs),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final accent in PixieAccent.values)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: accent == PixieAccent.ocean ? 0 : 10),
                    child: _accentCard(accent, cs),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Current theme: ${widget.theme.modeLabel} · ${widget.theme.accentLabel}',
                    style: TextStyle(color: cs.onSurface, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _choiceCard({
    required bool selected,
    required IconData icon,
    required String label,
    required ColorScheme cs,
    required VoidCallback onTap,
  }) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.6),
                width: selected ? 2 : 1,
              ),
              color: selected ? cs.primary.withValues(alpha: 0.06) : Colors.transparent,
            ),
            child: Column(
              children: [
                Icon(icon, color: selected ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(height: 6),
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
              ],
            ),
          ),
        ),
      );

  Widget _accentCard(PixieAccent accent, ColorScheme cs) {
    final color = switch (accent) {
      PixieAccent.violet => const Color(0xFF7C3AED),
      PixieAccent.teal => const Color(0xFF0F8B8D),
      PixieAccent.rose => const Color(0xFFE11D48),
      PixieAccent.ocean => const Color(0xFF2563EB),
    };
    final selected = widget.theme.accent == accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.theme.setAccent(accent),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? color : cs.outlineVariant.withValues(alpha: 0.6), width: selected ? 2 : 1),
          ),
          child: Column(
            children: [
              CircleAvatar(backgroundColor: color, radius: 14,
                  child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null),
              const SizedBox(height: 8),
              Text(accent.name[0].toUpperCase() + accent.name.substring(1),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _upload(ColorScheme cs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('UPLOAD BEHAVIOUR', 'How files are selected and sent', cs),
          _switch('Recursive directory scan', 'Include sub-folders', _settings!.recursive,
              (v) => _save(_copy(recursive: v)), cs),
          _switch('Force upload', 'Ignore remote duplicates', _settings!.forceUpload,
              (v) => _save(_copy(forceUpload: v)), cs),
          _switch('Storage saver', 'Upload compressed originals', _settings!.saver,
              (v) => _save(_copy(saver: v)), cs),
          _switch('Use quota model', 'Device fingerprint variant', _settings!.useQuota,
              (v) => _save(_copy(useQuota: v)), cs),
          _sectionTitle('FILTERS & TIMING', 'Metadata and file filtering', cs),
          _switch('Date from filename', 'Read timestamp from name', _settings!.setDateFromFilename,
              (v) => _save(_copy(setDateFromFilename: v)), cs),
          _switch('Allow all file types', 'Skip extension filter', _settings!.disableUnsupportedFilesFilter,
              (v) => _save(_copy(disableUnsupportedFilesFilter: v)), cs),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 160, child: Text('Threads', style: TextStyle(fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: _settings!.uploadThreads.clamp(1, 16).toDouble(),
                    min: 1,
                    max: 16,
                    divisions: 15,
                    label: '${_settings!.uploadThreads}',
                    onChanged: (v) => _save(_copy(uploadThreads: v.round())),
                  ),
                ),
                Text('${_settings!.uploadThreads}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          TextField(
            decoration: const InputDecoration(labelText: 'Exclude directory name'),
            controller: TextEditingController(text: _settings!.excludePattern)
              ..selection = TextSelection.collapsed(offset: _settings!.excludePattern.length),
            onSubmitted: (v) => _save(_copy(excludePattern: v.trim())),
          ),
          const SizedBox(height: 10),
          TextField(
            decoration: const InputDecoration(labelText: 'Proxy (optional)'),
            controller: TextEditingController(text: _settings!.proxy)
              ..selection = TextSelection.collapsed(offset: _settings!.proxy.length),
            onSubmitted: (v) => _save(_copy(proxy: v.trim())),
          ),
        ],
      );

  Widget _advanced(ColorScheme cs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('AFTER UPLOAD', null, cs),
          _switch('Delete from host', 'Remove local file after commit', _settings!.deleteFromHost,
              (v) => _save(_copy(deleteFromHost: v)), cs),
          _sectionTitle('LIVE PHOTOS', 'Pairing is stored for compatibility; not yet active', cs),
          _switch('Pair Live Photos', 'Group HEIC + MOV pairs', _settings!.pairLivePhotos,
              (v) => _save(_copy(pairLivePhotos: v)), cs),
          _switch('Skip incomplete pairs', 'Do not upload unmatched files', _settings!.skipIncompleteLivePhotos,
              (v) => _save(_copy(skipIncompleteLivePhotos: v)), cs),
          _switch('Update existing to Live', 'Reconcile already-uploaded photos', _settings!.updateExistingPhotosToLive,
              (v) => _save(_copy(updateExistingPhotosToLive: v)), cs),
          const SizedBox(height: 20),
          _sectionTitle('CONFIGURATION', null, cs),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(_configPath, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      );

  Widget _sectionTitle(String label, [String? subtitle, ColorScheme? scheme]) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.w700,
                color: (scheme ?? Theme.of(context).colorScheme).primary)),
            if (subtitle != null)
              Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      );

  Widget _switch(String label, String subtitle, bool value, ValueChanged<bool> onChanged, ColorScheme cs) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface)),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        value: value,
        onChanged: onChanged,
      );
}

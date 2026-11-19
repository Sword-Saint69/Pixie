import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:material_ui/material_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _teal = Color(0xFF0F8B8D);
  static const _ink = Color(0xFF152A2E);
  static const _muted = Color(0xFF6B8286);
  static const _canvas = Color(0xFFF3F6F7);

  AppSettings _settings = const AppSettings(
    proxy: '',
    useQuota: false,
    saver: false,
    recursive: false,
    forceUpload: false,
    pairLivePhotos: false,
    skipIncompleteLivePhotos: true,
    updateExistingPhotosToLive: false,
    uploadThreads: 3,
    deleteFromHost: false,
    disableUnsupportedFilesFilter: false,
    setDateFromFilename: false,
    excludePattern: '',
  );
  List<AccountInfo> _accounts = [];
  String _selected = '';
  String _configPath = '';
  final List<String> _paths = [];
  final List<UploadEvent> _threadStates = [];
  final List<UploadResult> _results = [];
  UploadSummary _summary = const UploadSummary(
    total: 0,
    succeeded: 0,
    failed: 0,
    skipped: 0,
    results: [],
  );
  bool _running = false;
  bool _dragOver = false;
  bool _busy = false;
  String? _error;
  Timer? _poll;
  final _albumController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) => _pump());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await getSettings();
      final accounts = await listAccounts();
      final selected = await selectedAccount();
      final path = await configPath();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _accounts = accounts;
        _selected = selected.isNotEmpty ? selected : (accounts.isNotEmpty ? accounts.first.email : '');
        _configPath = path;
      });
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _pump() async {
    if (_busy) return;
    try {
      final events = await drainEvents();
      final running = await isUploadRunning();
      if (!mounted || (events.isEmpty && running == _running)) return;
      setState(() {
        _running = running;
        for (final event in events) {
          switch (event.eventType) {
            case 'thread':
              _threadStates.removeWhere((e) => e.workerId == event.workerId);
              _threadStates.add(event);
            case 'file_result':
              _results.insert(
                0,
                UploadResult(
                  path: event.filePath,
                  mediaKey: event.mediaKey,
                  isError: event.isError,
                  skipped: event.skipped,
                  skipCode: event.skipCode,
                  skipReason: event.skipReason,
                  errorMessage: event.message,
                ),
              );
            case 'start':
              if (event.total > 0) {
                _results.clear();
                _threadStates.clear();
              }
            case 'fatal':
              _error = event.message;
          }
        }
        _threadStates.sort((a, b) => a.workerId.compareTo(b.workerId));
      });
      if (!running) {
        _summary = await getSummary();
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Polling is best-effort; the next tick retries.
    }
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = e.toString().replaceFirst('AnyhowException(', '').replaceAll(RegExp(r'\)$'), ''));
  }

  Future<void> _saveSettings(AppSettings next) async {
    setState(() => _settings = next);
    try {
      await saveSettings(settings: next);
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _pickFiles({required bool directory}) async {
    try {
      final List<String> paths = directory
          ? [(await FilePicker.pickDirectory())?.toFilePath()]
              .whereType<String>()
              .toList()
          : (await FilePicker.pickFiles(type: FileType.any))
              .map((f) => f.path)
              .whereType<String>()
              .toList();
      if (paths.isEmpty || !mounted) return;
      setState(() => _paths.addAll(paths));
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _addAccount() async {
    final controller = TextEditingController();
    var raw = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.account_circle_outlined, color: _teal),
              SizedBox(width: 10),
              Text('Add Google account'),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  raw
                      ? 'Paste the full credential string captured from the Google Photos auth request.'
                      : 'Paste the oauth_token cookie value from Google Embedded Setup.',
                  style: const TextStyle(color: _muted),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Raw credential')),
                    ButtonSegment(value: false, label: Text('oauth_token')),
                  ],
                  selected: {raw},
                  onSelectionChanged: (s) => setDialogState(() => raw = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 5,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    hintText: raw ? 'androidId=...&Email=...&Token=...' : 'oauth_token cookie value',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
    if (result != true || controller.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final email = raw
          ? await addAccountRaw(credential: controller.text.trim())
          : await addAccountOauth(
              oauthToken: controller.text.trim(),
              proxy: _settings.proxy,
            );
      await _load();
      setState(() => _selected = email);
      await selectAccount(email: email);
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    if (_selected.isEmpty) {
      _setError('Add a Google account first');
      return;
    }
    if (_paths.isEmpty) {
      _setError('Select files or folders first');
      return;
    }
    setState(() {
      _error = null;
      _results.clear();
      _threadStates.clear();
      _running = true;
    });
    try {
      await startUpload(
        paths: List.unmodifiable(_paths),
        settings: _settings,
        albumName: _albumController.text.trim(),
        albumAuto: false,
        account: _selected,
      );
    } catch (e) {
      _setError(e);
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _canvas,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _teal.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.photo_library_outlined, color: _teal, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('gotohp-rs', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _ink)),
                Text('Google Photos uploader · Rust core', style: TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
          ],
        ),
        actions: [
          _statusPill(),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Reload accounts and settings',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, color: _muted),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1040;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1500),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 380, child: _leftColumn()),
                          const SizedBox(width: 20),
                          Expanded(child: _rightColumn()),
                        ],
                      )
                    : Column(
                        children: [
                          _leftColumn(),
                          const SizedBox(height: 20),
                          _rightColumn(),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _statusPill() {
    final color = _running ? Colors.orange.shade700 : Colors.green.shade700;
    final label = _running ? 'Uploading' : 'Ready';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _leftColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            title: 'Account',
            icon: Icons.account_circle_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_selected.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _teal.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: _teal,
                          radius: 18,
                          child: Text(
                            _selected[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selected,
                                style: const TextStyle(fontWeight: FontWeight.w600, color: _ink),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${_accounts.length} account(s) stored',
                                style: const TextStyle(fontSize: 11, color: _muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_selected.isNotEmpty) const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _accounts.any((a) => a.email == _selected) ? _selected : null,
                  isExpanded: true,
                  decoration: _inputDecoration('Switch account'),
                  items: [
                    for (final account in _accounts)
                      DropdownMenuItem(
                        value: account.email,
                        child: Text(
                          account.needsTokenBinding ? '${account.email} (token binding)' : account.email,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => _selected = value);
                    try {
                      await selectAccount(email: value);
                    } catch (e) {
                      _setError(e);
                    }
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _addAccount,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add account'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _teal,
                          side: BorderSide(color: _teal.withValues(alpha: 0.4)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: _selected.isEmpty
                            ? null
                            : () async {
                                try {
                                  await validateAccount(email: _selected);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Credential accepted by Google')),
                                    );
                                  }
                                } catch (e) {
                                  _setError(e);
                                }
                              },
                        icon: const Icon(Icons.verified_outlined, size: 16),
                        label: const Text('Test'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(title: 'Preferences', icon: Icons.tune_rounded, child: _settingsForm()),
        ],
      );

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: _canvas,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
      );

  Widget _settingsForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('UPLOAD BEHAVIOUR'),
          _toggle('Recursive directory scan', 'Include sub-folders', _settings.recursive,
              (v) => _saveSettings(_copy(recursive: v))),
          _toggle('Force upload', 'Ignore remote duplicates', _settings.forceUpload,
              (v) => _saveSettings(_copy(forceUpload: v))),
          _toggle('Storage saver', 'Upload compressed originals', _settings.saver,
              (v) => _saveSettings(_copy(saver: v))),
          _toggle('Use quota model', 'Device fingerprint variant', _settings.useQuota,
              (v) => _saveSettings(_copy(useQuota: v))),
          _sectionLabel('AFTER UPLOAD'),
          _toggle('Delete from host', 'Remove local file after commit', _settings.deleteFromHost,
              (v) => _saveSettings(_copy(deleteFromHost: v))),
          _toggle('Pair Live Photos', 'Group HEIC + MOV pairs', _settings.pairLivePhotos,
              (v) => _saveSettings(_copy(pairLivePhotos: v))),
          _sectionLabel('FILTERS & TIMING'),
          _toggle('Date from filename', 'Read timestamp from name', _settings.setDateFromFilename,
              (v) => _saveSettings(_copy(setDateFromFilename: v))),
          _toggle('Allow all file types', 'Skip extension filter', _settings.disableUnsupportedFilesFilter,
              (v) => _saveSettings(_copy(disableUnsupportedFilesFilter: v))),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const SizedBox(width: 132, child: Text('Threads', style: TextStyle(fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: _settings.uploadThreads.clamp(1, 16).toDouble(),
                    min: 1,
                    max: 16,
                    divisions: 15,
                    activeColor: _teal,
                    label: '${_settings.uploadThreads}',
                    onChanged: (v) => _saveSettings(_copy(uploadThreads: v.round())),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: _teal.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text('${_settings.uploadThreads}', style: const TextStyle(color: _teal, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            decoration: _inputDecoration('Exclude directory name'),
            controller: TextEditingController(text: _settings.excludePattern)
              ..selection = TextSelection.collapsed(offset: _settings.excludePattern.length),
            onSubmitted: (v) => _saveSettings(_copy(excludePattern: v.trim())),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: _inputDecoration('Proxy (optional)'),
            controller: TextEditingController(text: _settings.proxy)
              ..selection = TextSelection.collapsed(offset: _settings.proxy.length),
            onSubmitted: (v) => _saveSettings(_copy(proxy: v.trim())),
          ),
        ],
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(text, style: const TextStyle(fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.w700, color: _muted)),
      );

  Widget _toggle(String label, String subtitle, bool value, ValueChanged<bool> onChanged) => Material(
        color: Colors.transparent,
        child: SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(fontSize: 13, color: _ink)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: _muted)),
          activeThumbColor: _teal,
          value: value,
          onChanged: onChanged,
        ),
      );

  AppSettings _copy({
    String? proxy,
    bool? useQuota,
    bool? saver,
    bool? recursive,
    bool? forceUpload,
    bool? pairLivePhotos,
    int? uploadThreads,
    bool? deleteFromHost,
    bool? disableUnsupportedFilesFilter,
    bool? setDateFromFilename,
    String? excludePattern,
  }) {
    return AppSettings(
      proxy: proxy ?? _settings.proxy,
      useQuota: useQuota ?? _settings.useQuota,
      saver: saver ?? _settings.saver,
      recursive: recursive ?? _settings.recursive,
      forceUpload: forceUpload ?? _settings.forceUpload,
      pairLivePhotos: pairLivePhotos ?? _settings.pairLivePhotos,
      skipIncompleteLivePhotos: _settings.skipIncompleteLivePhotos,
      updateExistingPhotosToLive: _settings.updateExistingPhotosToLive,
      uploadThreads: uploadThreads ?? _settings.uploadThreads,
      deleteFromHost: deleteFromHost ?? _settings.deleteFromHost,
      disableUnsupportedFilesFilter:
          disableUnsupportedFilesFilter ?? _settings.disableUnsupportedFilesFilter,
      setDateFromFilename: setDateFromFilename ?? _settings.setDateFromFilename,
      excludePattern: excludePattern ?? _settings.excludePattern,
    );
  }

  Widget _rightColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statRow(),
          const SizedBox(height: 16),
          _card(
            title: 'Upload queue',
            icon: Icons.cloud_upload_outlined,
            trailing: _paths.isEmpty ? null : Text('${_paths.length} path(s)', style: const TextStyle(color: _muted, fontSize: 12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropTarget(
                  onDragDone: (details) {
                    if (!mounted) return;
                    final dropped = details.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
                    if (dropped.isNotEmpty) setState(() => _paths.addAll(dropped));
                  },
                  onDragEntered: (_) => setState(() => _dragOver = true),
                  onDragExited: (_) => setState(() => _dragOver = false),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 120,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _dragOver ? _teal.withValues(alpha: 0.08) : Colors.white,
                      border: Border.all(
                        color: _dragOver ? _teal : Colors.grey.shade300,
                        width: _dragOver ? 2.5 : 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _dragOver ? Icons.download_rounded : Icons.drive_folder_upload_outlined,
                          color: _teal,
                          size: 28,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _dragOver ? 'Release to add files' : 'Drop photos, videos or folders here',
                          style: const TextStyle(color: _muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickFiles(directory: false),
                        icon: const Icon(Icons.insert_photo_outlined, size: 17),
                        label: const Text('Choose files'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _ink,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickFiles(directory: true),
                        icon: const Icon(Icons.folder_open_outlined, size: 17),
                        label: const Text('Choose folder'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _ink,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: _paths.isEmpty ? null : () => setState(() => _paths.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                if (_paths.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 130),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (int i = 0; i < _paths.length; i++)
                            InputChip(
                              label: Text(
                                _paths[i].split(Platform.pathSeparator).last,
                                style: const TextStyle(fontSize: 12),
                              ),
                              avatar: const Icon(Icons.image_outlined, size: 15, color: _teal),
                              onDeleted: () => setState(() => _paths.removeAt(i)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _albumController,
                        decoration: _inputDecoration('Album name (optional)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _running ? null : _start,
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: const Text('Upload'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _teal,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _running ? cancelUpload : null,
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade200),
              ),
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      _error!,
                      style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _error = null),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          _card(
            title: 'Live progress',
            icon: Icons.show_chart_rounded,
            trailing: _running ? const Text('in progress', style: TextStyle(color: Colors.orange, fontSize: 12)) : null,
            child: _progressView(),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Config: $_configPath',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ),
        ],
      );

  Widget _statRow() => Row(
        children: [
          _statTile('TOTAL', '${_summary.total}', Icons.folder_open_outlined, _ink),
          const SizedBox(width: 12),
          _statTile('UPLOADED', '${_summary.succeeded}', Icons.check_circle_outline, Colors.green.shade700),
          const SizedBox(width: 12),
          _statTile('SKIPPED', '${_summary.skipped}', Icons.remove_circle_outline, Colors.orange.shade700),
          const SizedBox(width: 12),
          _statTile('FAILED', '${_summary.failed}', Icons.error_outline, Colors.red.shade700),
        ],
      );

  Widget _statTile(String label, String value, IconData icon, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
                  Text(label, style: const TextStyle(fontSize: 10, letterSpacing: 0.8, color: _muted)),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _progressView() {
    if (_threadStates.isEmpty && _results.isEmpty) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.cloud_queue_outlined, size: 34, color: Colors.grey),
            SizedBox(height: 8),
            Text('No uploads yet — add files and press Upload', style: TextStyle(color: _muted, fontSize: 13)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final event in _threadStates)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: _teal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
                  child: Text('${event.workerId}', style: const TextStyle(color: _teal, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              event.fileName.isEmpty ? event.status : event.fileName,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _ink),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(event.status, style: const TextStyle(fontSize: 10, color: _muted)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: event.bytesTotal > 0
                              ? (event.bytesUploaded / event.bytesTotal).clamp(0.0, 1.0)
                              : null,
                          minHeight: 5,
                          color: _teal,
                          backgroundColor: Colors.grey.shade200,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: Text(
                    event.bytesTotal > 0
                        ? '${event.bytesUploaded ~/ 1024}/${event.bytesTotal ~/ 1024} KiB'
                        : event.message,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 10, color: _muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (_threadStates.isNotEmpty) const Divider(height: 20),
        SizedBox(
          height: 280,
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final r = _results[i];
              final color = r.isError ? Colors.red.shade700 : r.skipped ? Colors.orange.shade700 : Colors.green.shade700;
              final icon = r.isError ? Icons.error_outline : r.skipped ? Icons.remove_circle_outline : Icons.check_circle_outline;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.path.split(Platform.pathSeparator).last,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            r.isError ? r.errorMessage : r.skipped ? r.skipReason : r.mediaKey,
                            style: const TextStyle(fontSize: 11, color: _muted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _card({
    required String title,
    required IconData icon,
   required Widget child,
    Widget? trailing,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: _teal),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _ink)),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

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
  bool _albumAuto = false;

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
      if (!mounted || events.isEmpty && running == _running) return;
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
      // Transient polling failure; next tick retries.
    }
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = e.toString());
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
          ? [(await FilePicker.pickDirectory())?.toFilePath()].whereType<String>().toList()
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
    var raw = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Google account'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Paste the oauth_token cookie from Google Embedded Setup, or a raw '
                  'credential query string (androidId=...&Email=...&Token=...).',
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Raw credential string'),
                  value: raw,
                  onChanged: (v) => setDialogState(() => raw = v ?? false),
                ),
                TextField(
                  controller: controller,
                  maxLines: 5,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: raw ? 'androidId=...&Email=...' : 'oauth_token value',
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
        albumAuto: _albumAuto,
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
      appBar: AppBar(
        title: const Text('gotohp-rs  •  Google Photos uploader'),
        actions: [
          IconButton(
            tooltip: 'Reload accounts and settings',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: _leftColumn()),
                      const SizedBox(width: 16),
                      Expanded(flex: 3, child: _rightColumn()),
                    ],
                  )
                : Column(
                    children: [
                      _leftColumn(),
                      const SizedBox(height: 16),
                      _rightColumn(),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _leftColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            'Account',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _accounts.any((a) => a.email == _selected) ? _selected : null,
                  decoration: const InputDecoration(
                    labelText: 'Google account',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final account in _accounts)
                      DropdownMenuItem(
                        value: account.email,
                        child: Text(
                          account.needsTokenBinding
                              ? '${account.email} (needs token binding)'
                              : account.email,
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: _busy ? null : _addAccount,
                      child: const Text('Add account'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () async {
                              try {
                                await validateAccount(email: _selected);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Credential accepted')),
                                  );
                                }
                              } catch (e) {
                                _setError(e);
                              }
                            },
                      child: const Text('Test'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card('Upload settings', _settingsForm()),
        ],
      );

  Widget _settingsForm() => Column(
        children: [
          _toggle('Upload storage saver (compress)', _settings.saver,
              (v) => _saveSettings(_copy(saver: v))),
          _toggle('Use quota model', _settings.useQuota,
              (v) => _saveSettings(_copy(useQuota: v))),
          _toggle('Recursive directory scan', _settings.recursive,
              (v) => _saveSettings(_copy(recursive: v))),
          _toggle('Force upload (skip dedup)', _settings.forceUpload,
              (v) => _saveSettings(_copy(forceUpload: v))),
          _toggle('Delete local file after upload', _settings.deleteFromHost,
              (v) => _saveSettings(_copy(deleteFromHost: v))),
          _toggle('Allow unsupported file types', _settings.disableUnsupportedFilesFilter,
              (v) => _saveSettings(_copy(disableUnsupportedFilesFilter: v))),
          _toggle('Read date from filename', _settings.setDateFromFilename,
              (v) => _saveSettings(_copy(setDateFromFilename: v))),
          _toggle('Pair Live Photos', _settings.pairLivePhotos,
              (v) => _saveSettings(_copy(pairLivePhotos: v))),
          Row(
            children: [
              const SizedBox(width: 140, child: Text('Threads')),
              Expanded(
                child: Slider(
                  value: _settings.uploadThreads.clamp(1, 16).toDouble(),
                  min: 1,
                  max: 16,
                  divisions: 15,
                  label: '${_settings.uploadThreads}',
                  onChanged: (v) => _saveSettings(_copy(uploadThreads: v.round())),
                ),
              ),
              Text('${_settings.uploadThreads}'),
            ],
          ),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Exclude directory name',
              border: OutlineInputBorder(),
            ),
            controller: TextEditingController(text: _settings.excludePattern)
              ..selection = TextSelection.collapsed(offset: _settings.excludePattern.length),
            onSubmitted: (v) => _saveSettings(_copy(excludePattern: v.trim())),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Proxy (optional)',
              border: OutlineInputBorder(),
            ),
            controller: TextEditingController(text: _settings.proxy)
              ..selection = TextSelection.collapsed(offset: _settings.proxy.length),
            onSubmitted: (v) => _saveSettings(_copy(proxy: v.trim())),
          ),
        ],
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

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        onChanged: onChanged,
      );

  Widget _rightColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            'Upload queue',
            Column(
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
                  child: Container(
                    height: 110,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _dragOver ? Colors.teal : Colors.grey.shade500,
                        width: _dragOver ? 3 : 1.5,
                      ),
                      color: _dragOver ? Colors.teal.withValues(alpha: 0.08) : null,
                    ),
                    child: Text(
                      _dragOver
                          ? 'Drop files or folders here'
                          : '${_paths.length} path(s) selected — drop more here',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _pickFiles(directory: false),
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Files'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _pickFiles(directory: true),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('Folder'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _paths.isEmpty ? null : () => setState(() => _paths.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                if (_paths.isNotEmpty)
                  Container(
                    height: 96,
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: _paths.length,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        title: Text(
                          _paths[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() => _paths.removeAt(i)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _albumController,
                        decoration: const InputDecoration(
                          labelText: 'Album name (optional; ignored in AUTO mode)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Tooltip(
                      message: 'Create one album per source directory',
                      child: SizedBox(
                        width: 110,
                        child: CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('AUTO', style: TextStyle(fontSize: 12)),
                          value: _albumAuto,
                          onChanged: (v) => setState(() => _albumAuto = v ?? false),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _running ? null : _start,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Upload'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _running ? cancelUpload : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            'Live progress  •  ${_summary.succeeded} ok / ${_summary.skipped} skipped / ${_summary.failed} failed of ${_summary.total}',
            _progressView(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _card(
                'Error',
                SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Config: $_configPath',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );

  Widget _progressView() {
    if (_threadStates.isEmpty && _results.isEmpty) {
      return const SizedBox(
        height: 80,
        child: Center(child: Text('No uploads yet.')),
      );
    }
    return Column(
      children: [
        for (final event in _threadStates)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 28,
              child: Text('${event.workerId}', style: const TextStyle(fontSize: 11)),
            ),
            title: Text(
              event.fileName.isEmpty ? event.status : '${event.fileName} — ${event.status}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: event.bytesTotal > 0
                ? LinearProgressIndicator(
                    value: (event.bytesUploaded / event.bytesTotal).clamp(0.0, 1.0),
                  )
                : Text(event.message, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: event.bytesTotal > 0
                ? Text('${event.bytesUploaded ~/ 1024}/${event.bytesTotal ~/ 1024} KiB')
                : null,
          ),
        const Divider(),
        SizedBox(
          height: 260,
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final r = _results[i];
              final color = r.isError
                  ? Colors.red
                  : r.skipped
                      ? Colors.orange
                      : Colors.green;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.circle, size: 10, color: color),
                title: Text(
                  r.path.split(Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  r.isError
                      ? r.errorMessage
                      : r.skipped
                          ? r.skipReason
                          : r.mediaKey,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _card(String title, Widget child) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              child,
            ],
          ),
        ),
      );
}

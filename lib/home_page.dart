import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _queueKey = 'pixie.queue_paths';
  static const _albumKey = 'pixie.album';
  static const _autoKey = 'pixie.album_auto';

  AppSettings? _settings;
  String _selected = '';
  final List<String> _paths = [];
  final _albumController = TextEditingController();
  bool _albumAuto = false;

  final List<UploadEvent> _threadStates = [];
  final List<UploadResult> _results = [];
  UploadSummary _summary = const UploadSummary(
    total: 0,
    succeeded: 0,
    failed: 0,
    skipped: 0,
    results: [],
  );

  int _preflightCount = 0;
  int _preflightBytes = 0;
  bool _preflighting = false;
  Timer? _preflightTimer;
  DateTime? _runStart;
  double _etaSeconds = -1;
  double _speedBytes = 0;

  bool _running = false;
  bool _dragOver = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(milliseconds: 180), (_) => _pump());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _preflightTimer?.cancel();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await getSettings();
      final selected = await selectedAccount();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _selected = selected;
        final saved = prefs.getStringList(_queueKey) ?? <String>[];
        _paths
          ..clear()
          ..addAll(saved);
        _albumController.text = prefs.getString(_albumKey) ?? '';
        _albumAuto = prefs.getBool(_autoKey) ?? false;
      });
      _schedulePreflight();
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queueKey, _paths);
    await prefs.setString(_albumKey, _albumController.text);
    await prefs.setBool(_autoKey, _albumAuto);
  }

  void _schedulePreflight() {
    _preflightTimer?.cancel();
    _preflightTimer = Timer(const Duration(milliseconds: 250), _preflight);
  }

  Future<void> _preflight() async {
    final settings = _settings;
    if (settings == null || _paths.isEmpty || !mounted) {
      if (mounted) setState(() => _preflightCount = _preflightBytes = 0);
      return;
    }
    setState(() => _preflighting = true);
    try {
      final files = await previewFiles(paths: _paths, settings: settings);
      var bytes = 0;
      for (final path in files) {
        try {
          bytes += await File(path).length();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _preflightCount = files.length;
        _preflightBytes = bytes;
        _preflighting = false;
      });
    } catch (_) {
      if (mounted) setState(() => _preflighting = false);
    }
  }

  Future<void> _pump() async {
    try {
      final events = await drainEvents();
      final running = await isUploadRunning();
      if (!mounted) return;
      final wasRunning = _running;
      var summaryChanged = false;
      setState(() {
        _running = running;
        for (final event in events) {
          switch (event.eventType) {
            case 'thread':
              _threadStates.removeWhere((e) => e.workerId == event.workerId);
              _threadStates.add(event);
            case 'file_result':
              _results.insert(0, UploadResult(
                path: event.filePath,
                mediaKey: event.mediaKey,
                isError: event.isError,
                skipped: event.skipped,
                skipCode: event.skipCode,
                skipReason: event.skipReason,
                errorMessage: event.message,
              ));
            case 'start':
              if (event.total > 0) {
                _results.clear();
                _threadStates.clear();
                _runStart = DateTime.now();
              }
            case 'fatal':
              _error = _friendly(event.message);
          }
        }
        _threadStates.sort((a, b) => a.workerId.compareTo(b.workerId));
        _computeSpeed();
      });
      if (!running) {
        final fresh = await getSummary();
        if (!mounted) return;
        setState(() {
          _summary = fresh;
          summaryChanged = true;
        });
      }
      if (wasRunning && !running && summaryChanged) {
        _showCompletion();
      }
    } catch (_) {}
  }

  void _computeSpeed() {
    final start = _runStart;
    if (!_running || start == null) {
      _speedBytes = 0;
      _etaSeconds = -1;
      return;
    }
    final uploaded = _threadStates.fold<int>(0, (sum, e) => sum + e.bytesUploaded);
    final seconds = DateTime.now().difference(start).inMilliseconds / 1000;
    if (seconds <= 0.2) return;
    _speedBytes = uploaded / seconds;
    final remaining = _preflightBytes - uploaded;
    _etaSeconds = _speedBytes > 0 && remaining > 0 ? remaining / _speedBytes : -1;
  }

  void _showCompletion() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final s = _summary;
    final color = s.failed > 0 ? Colors.orange.shade700 : Colors.green.shade700;
    messenger.showSnackBar(SnackBar(
      content: Text('Upload finished · ${s.succeeded} uploaded, ${s.skipped} skipped, ${s.failed} failed'),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  String _friendly(Object e) {
    final text = e.toString().replaceFirst('AnyhowException(', '').replaceAll(RegExp(r'\)$'), '');
    if (text.contains('Read-only file system')) {
      return 'Cannot write the config file. Check app storage permissions.';
    }
    if (text.toLowerCase().contains('auth') || text.contains('BadAuthentication')) {
      return 'Google rejected this credential. Add a fresh one in Accounts.';
    }
    if (text.toLowerCase().contains('network') || text.contains('failed to')) {
      return 'Network error — check your connection and try again.';
    }
    return text;
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = _friendly(e));
  }

  void _addPaths(List<String> paths) {
    if (paths.isEmpty) return;
    setState(() => _paths.addAll(paths));
    _persistQueue();
    _schedulePreflight();
  }

  Future<void> _pickFiles({required bool directory}) async {
    try {
      final List<String> paths = directory
          ? [(await FilePicker.pickDirectory())?.toFilePath()].whereType<String>().toList()
          : (await FilePicker.pickFiles(type: FileType.any))
              .map((f) => f.path)
              .whereType<String>()
              .toList();
      if (mounted) _addPaths(paths);
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _start() async {
    if (_selected.isEmpty) {
      _setError('No account selected — add one in the Accounts tab');
      return;
    }
    if (_settings == null) {
      _setError('Settings are still loading');
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
      _runStart = DateTime.now();
    });
    try {
      await startUpload(
        paths: List.unmodifiable(_paths),
        settings: _settings!,
        albumName: _albumAuto ? '' : _albumController.text.trim(),
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
    final cs = Theme.of(context).colorScheme;
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyU): const _UploadIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma): const _SettingsIntent(),
      },
      child: Actions(
        actions: {
          _UploadIntent: CallbackAction<_UploadIntent>(onInvoke: (_) => _start()),
          _SettingsIntent: CallbackAction<_SettingsIntent>(onInvoke: (_) => widget.onOpenSettings?.call()),
        },
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(cs),
                    const SizedBox(height: 22),
                    _dropZone(cs),
                    const SizedBox(height: 14),
                    _fileButtons(cs),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _paths.isEmpty ? const SizedBox.shrink() : _queue(cs),
                    ),
                    const SizedBox(height: 18),
                    _albumRow(cs),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _running ? _overallProgress(cs) : const SizedBox.shrink(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      _errorBanner(cs),
                    ],
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      child: (_threadStates.isNotEmpty || _results.isNotEmpty)
                          ? _activity(cs)
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Tip: press Ctrl+U to upload, Ctrl+, for settings',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme cs) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send your photos to the cloud',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: cs.onSurface)),
                const SizedBox(height: 4),
                Text('Drop files, choose a folder, and Pixie handles the rest.',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Row(
            children: [
              _chip('${_preflighting ? '…' : _preflightCount}', 'files', Icons.folder_open_outlined, cs.onSurface, cs),
              const SizedBox(width: 8),
              _chip('${_summary.succeeded}', 'done', Icons.check_circle_outline, Colors.green.shade700, cs),
              const SizedBox(width: 8),
              _chip('${_summary.failed}', 'failed', Icons.error_outline, cs.error, cs),
            ],
          ),
        ],
      );

  Widget _dropZone(ColorScheme cs) => DropTarget(
        onDragDone: (d) => _addPaths(d.files.map((f) => f.path).where((p) => p.isNotEmpty).toList()),
        onDragEntered: (_) => setState(() => _dragOver = true),
        onDragExited: (_) => setState(() => _dragOver = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 176,
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(_dragOver ? 1.015 : 1.0, _dragOver ? 1.015 : 1.0, 1),
          decoration: BoxDecoration(
            color: _dragOver ? cs.primary.withValues(alpha: 0.08) : cs.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _dragOver ? cs.primary : cs.outlineVariant,
              width: _dragOver ? 2.5 : 1.5,
            ),
            boxShadow: _dragOver
                ? [BoxShadow(color: cs.primary.withValues(alpha: 0.12), blurRadius: 24)]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _dragOver
                    ? Icon(Icons.download_rounded, key: const ValueKey('drag'), size: 36, color: cs.primary)
                    : const PixieLogo(key: ValueKey('logo'), size: 44),
              ),
              const SizedBox(height: 10),
              Text(
                _dragOver ? 'Release to add files' : 'Drop photos, videos or folders here',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              const SizedBox(height: 4),
              if (_preflightCount > 0)
                Text(
                  '$_preflightCount file(s) · ${_formatBytes(_preflightBytes)} ready',
                  style: TextStyle(fontSize: 12, color: cs.primary),
                )
              else
                Text('or use the buttons below', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );

  Widget _fileButtons(ColorScheme cs) => Row(
        children: [
          OutlinedButton.icon(
            onPressed: () => _pickFiles(directory: false),
            icon: const Icon(Icons.insert_photo_outlined, size: 17),
            label: const Text('Choose files'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () => _pickFiles(directory: true),
            icon: const Icon(Icons.folder_open_outlined, size: 17),
            label: const Text('Choose folder'),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: _paths.isEmpty
                ? null
                : () {
                    setState(() => _paths.clear());
                    _persistQueue();
                    _schedulePreflight();
                  },
            child: const Text('Clear'),
          ),
        ],
      );

  Widget _queue(ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 118),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (int i = 0; i < _paths.length; i++)
                  InputChip(
                    label: Text(_paths[i].split(Platform.pathSeparator).last,
                        style: const TextStyle(fontSize: 12)),
                    avatar: Icon(Icons.image_outlined, size: 15, color: cs.primary),
                    onDeleted: () {
                      setState(() => _paths.removeAt(i));
                      _persistQueue();
                      _schedulePreflight();
                    },
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _albumRow(ColorScheme cs) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: _albumController,
              enabled: !_albumAuto,
              decoration: InputDecoration(
                labelText: _albumAuto ? 'Albums created from folder names' : 'Album name (optional)',
                prefixIcon: const Icon(Icons.photo_album_outlined, size: 18),
              ),
              onChanged: (_) => _persistQueue(),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Create one album per source directory',
            child: FilterChip(
              label: const Text('AUTO'),
              selected: _albumAuto,
              onSelected: (v) {
                setState(() => _albumAuto = v);
                _persistQueue();
              },
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _running ? null : _start,
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Upload'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18)),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _running ? cancelUpload : null,
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Cancel'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18)),
          ),
        ],
      );

  Widget _overallProgress(ColorScheme cs) {
    final uploaded = _threadStates.fold<int>(0, (sum, e) => sum + e.bytesUploaded);
    final total = _preflightBytes > 0 ? _preflightBytes : _summary.total;
    final progress = total > 0 ? (uploaded / total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Overall progress', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface)),
                  const Spacer(),
                  Text(
                    progress == null ? '' : '${(progress * 100).round()}%',
                    style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  color: cs.primary,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_formatBytes(uploaded)} / ${_formatBytes(total)}'
                '${_speedBytes > 0 ? ' · ${_formatBytes(_speedBytes.round())}/s' : ''}'
                '${_etaSeconds > 0 ? ' · ${_etaSeconds.round()}s left' : ''}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBanner(ColorScheme cs) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: cs.error),
            const SizedBox(width: 12),
            Expanded(child: SelectableText(_error!, style: TextStyle(color: cs.error, fontSize: 13))),
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _error = null)),
          ],
        ),
      );

  Widget _activity(ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Activity', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface)),
            const SizedBox(height: 10),
            Card(
              child: Padding(padding: const EdgeInsets.all(16), child: _activityBody(cs)),
            ),
          ],
        ),
      );

  Widget _activityBody(ColorScheme cs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final event in _threadStates)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                CircleAvatar(radius: 13, backgroundColor: cs.primary.withValues(alpha: 0.12),
                    child: Text('${event.workerId}', style: TextStyle(fontSize: 10, color: cs.primary))),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(event.fileName.isEmpty ? event.status : event.fileName,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
                    value: event.bytesTotal > 0 ? (event.bytesUploaded / event.bytesTotal).clamp(0.0, 1.0) : null,
                    minHeight: 5, color: cs.primary, backgroundColor: cs.surfaceContainerHighest,
                  )),
                ])),
                const SizedBox(width: 10),
                SizedBox(width: 96, child: Text(
                  event.bytesTotal > 0 ? '${_formatBytes(event.bytesUploaded)}/${_formatBytes(event.bytesTotal)}' : event.message,
                  textAlign: TextAlign.right, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis)),
              ]),
            ),
          if (_threadStates.isNotEmpty) Divider(height: 20, color: cs.outlineVariant.withValues(alpha: 0.4)),
          SizedBox(height: 220, child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final r = _results[i];
              final color = r.isError ? cs.error : r.skipped ? Colors.orange.shade700 : Colors.green.shade700;
              final icon = r.isError ? Icons.error_outline : r.skipped ? Icons.remove_circle_outline : Icons.check_circle_outline;
              return Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.path.split(Platform.pathSeparator).last,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                        overflow: TextOverflow.ellipsis),
                    Text(r.isError ? r.errorMessage : r.skipped ? r.skipReason : r.mediaKey,
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant), maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ])),
                ],
              ));
            },
          )),
        ],
      );

  Widget _chip(String value, String label, IconData icon, Color color, ColorScheme cs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5))),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 7),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: color)),
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ]),
        ]),
      );

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

class _UploadIntent extends Intent {
  const _UploadIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

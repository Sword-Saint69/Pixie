import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/design.dart';
import 'package:gotohp_rs/error_messages.dart';
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
  UploadProgress _progress = const UploadProgress(
    totalBytes: 0,
    uploadedBytes: 0,
    elapsedMs: 0,
    speedBytesPerSec: 0,
    etaSeconds: -1,
  );

  bool _running = false;
  bool _paused = false;
  bool _dragOver = false;
  String? _error;
  Timer? _poll;
  Timer? _successTimer;
  bool _showSuccess = false;
  int _activityFilter = 0; // 0 all, 1 uploaded, 2 skipped, 3 failed

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(milliseconds: 150), (_) => _pump());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _successTimer?.cancel();
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
      final files = await previewFilesDetailed(
        paths: _paths,
        settings: settings,
      );
      final bytes = files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
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
      final paused = await isUploadPaused();
      final progress = await getProgress();
      final summary = await getSummary();
      if (!mounted) return;

      final wasRunning = _running;
      final changed =
          events.isNotEmpty ||
          running != _running ||
          paused != _paused ||
          progress != _progress ||
          summary != _summary;
      if (!changed) return;

      setState(() {
        _running = running;
        _paused = paused;
        _progress = progress;
        _summary = summary;
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
              _error = friendlyError(event.message);
          }
        }
        _threadStates.sort((a, b) => a.workerId.compareTo(b.workerId));
      });

      if (wasRunning && !running) {
        _showCompletion();
      }
    } catch (_) {}
  }

  void _showCompletion() {
    HapticFeedback.lightImpact();
    setState(() => _showSuccess = true);
    _successTimer?.cancel();
    _successTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showSuccess = false);
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final s = _summary;
    final color = s.failed > 0 ? Colors.orange.shade700 : Colors.green.shade700;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Upload finished · ${s.succeeded} uploaded, ${s.skipped} skipped, ${s.failed} failed',
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = friendlyError(e));
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
          ? [(await FilePicker.pickDirectory())?.toFilePath()]
                .whereType<String>()
                .toList()
          : (await FilePicker.pickFiles(type: FileType.any))
                .map((f) => f.path)
                .whereType<String>()
                .toList();
      if (mounted) _addPaths(paths);
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _togglePause() async {
    HapticFeedback.selectionClick();
    try {
      if (_paused) {
        await resumeUpload();
      } else {
        await pauseUpload();
      }
      final paused = await isUploadPaused();
      if (mounted) setState(() => _paused = paused);
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
    HapticFeedback.mediumImpact();
    setState(() {
      _error = null;
      _results.clear();
      _threadStates.clear();
      _running = true;
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
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyU):
            const _UploadIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma):
            const _SettingsIntent(),
      },
      child: Actions(
        actions: {
          _UploadIntent: CallbackAction<_UploadIntent>(
            onInvoke: (_) => _start(),
          ),
          _SettingsIntent: CallbackAction<_SettingsIntent>(
            onInvoke: (_) => widget.onOpenSettings?.call(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(cs),
                    const SizedBox(height: 14),
                    if (_paths.isNotEmpty || _summary.total > 0)
                      _statusStrip(cs),
                    const SizedBox(height: 14),
                    _successBadge(cs),
                    _dropZone(cs),
                    const SizedBox(height: 14),
                    _fileButtons(cs),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _paths.isEmpty
                          ? const SizedBox.shrink()
                          : _queue(cs),
                    ),
                    const SizedBox(height: 18),
                    _albumRow(cs),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _running
                          ? _overallProgress(cs)
                          : const SizedBox.shrink(),
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
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
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

  Widget _header(ColorScheme cs) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MicroLabel('Session'),
                const SizedBox(height: 6),
                Text(
                  'Send your photos to the cloud',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Drop files, choose a folder, and Pixie handles the rest.',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PillSwitch<int>(
            values: const [0, 1, 2],
            labels: const ['All', 'Done', 'Failed'],
            selected: _activityFilter,
            onChanged: (v) => setState(() => _activityFilter = v),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _paths.isEmpty && _summary.total == 0
          ? _compactStats(cs)
          : Row(
              children: [
                StatCard(
                  label: 'Files queued',
                  value: '$_preflightCount',
                  icon: Icons.folder_open_outlined,
                  color: cs.primary,
                  count: _preflightCount,
                ),
                const SizedBox(width: 10),
                StatCard(
                  label: 'Uploaded',
                  value: '${_summary.succeeded}',
                  icon: Icons.check_circle_outline,
                  color: successColor(context),
                  count: _summary.succeeded,
                ),
                const SizedBox(width: 10),
                StatCard(
                  label: 'Skipped',
                  value: '${_summary.skipped}',
                  icon: Icons.remove_circle_outline,
                  color: warningColor(context),
                  count: _summary.skipped,
                ),
                const SizedBox(width: 10),
                StatCard(
                  label: 'Failed',
                  value: '${_summary.failed}',
                  icon: Icons.error_outline,
                  color: dangerColor(context),
                  count: _summary.failed,
                ),
              ],
            ),
    ],
  );

  Widget _compactStats(ColorScheme cs) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          'No files selected yet',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const Spacer(),
        Text(
          '0 · 0 · 0',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    ),
  );

  Widget _statusStrip(ColorScheme cs) => PixieCard(
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const MicroLabel('Workflow health'),
            const Spacer(),
            Text(
              'this session',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 14),
        StatusBar(
          done: _summary.succeeded,
          skipped: _summary.skipped,
          failed: _summary.failed,
        ),
      ],
    ),
  );

  Widget _successBadge(ColorScheme cs) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 260),
    transitionBuilder: (child, animation) =>
        ScaleTransition(scale: animation, child: child),
    child: _showSuccess
        ? Container(
            key: const ValueKey('success'),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: successColor(context).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PixieLogo(size: 20),
                const SizedBox(width: 8),
                Text(
                  'All done!',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: successColor(context),
                  ),
                ),
              ],
            ),
          )
        : const SizedBox.shrink(key: ValueKey('none')),
  );

  Widget _dropZone(ColorScheme cs) {
    if (Platform.isAndroid || Platform.isIOS) return _mobilePickArea(cs);
    return DropTarget(
      onDragDone: (d) => _addPaths(
        d.files.map((f) => f.path).where((p) => p.isNotEmpty).toList(),
      ),
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 150,
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          _dragOver ? 1.015 : 1.0,
          _dragOver ? 1.015 : 1.0,
          1,
        ),
        decoration: BoxDecoration(
          color: _dragOver ? cs.primary.withValues(alpha: 0.08) : cs.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _dragOver ? cs.primary : cs.outlineVariant,
            width: _dragOver ? 2.5 : 1.5,
          ),
          boxShadow: _dragOver
              ? [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.12),
                    blurRadius: 24,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _dragOver
                  ? Icon(
                      Icons.download_rounded,
                      key: const ValueKey('drag'),
                      size: 36,
                      color: cs.primary,
                    )
                  : const PixieLogo(key: ValueKey('logo'), size: 44),
            ),
            const SizedBox(height: 10),
            Text(
              _dragOver
                  ? 'Release to add files'
                  : 'Drop photos, videos or folders here',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            if (_preflighting)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Measuring queue…',
                    style: TextStyle(fontSize: 12, color: cs.primary),
                  ),
                ],
              )
            else if (_preflightCount > 0)
              Text(
                '$_preflightCount file(s) · ${_formatBytes(_preflightBytes)} ready',
                style: TextStyle(fontSize: 12, color: cs.primary),
              )
            else
              Text(
                'or use the buttons below',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mobilePickArea(ColorScheme cs) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: () => _pickFiles(directory: false),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 150,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const PixieLogo(size: 44),
            const SizedBox(height: 10),
            Text(
              'Select photos',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to choose images and videos',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
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
                label: Text(
                  _paths[i].split(Platform.pathSeparator).last,
                  style: const TextStyle(fontSize: 12),
                ),
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
            labelText: _albumAuto
                ? 'Albums created from folder names'
                : 'Album name (optional)',
            prefixIcon: const Icon(Icons.photo_album_outlined, size: 18),
          ),
          onChanged: (_) => _persistQueue(),
        ),
      ),
      const SizedBox(width: 10),
      Tooltip(
        message: 'Create one album per source directory',
        child: FilterChip(
          label: const Text('Auto albums'),
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
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        ),
      ),
      if (_running) ...[
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: cancelUpload,
          icon: const Icon(Icons.stop_rounded, size: 18),
          label: const Text('Cancel'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          ),
        ),
      ],
    ],
  );

  Widget _overallProgress(ColorScheme cs) {
    final total = _progress.totalBytes > 0
        ? _progress.totalBytes
        : _preflightBytes;
    final uploaded = _progress.uploadedBytes;
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
                  Text(
                    'Overall progress',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  if (_running)
                    IconButton(
                      tooltip: _paused ? 'Resume upload' : 'Pause upload',
                      icon: Icon(
                        _paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      onPressed: _togglePause,
                    ),
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: progress ?? 0,
                          strokeWidth: 4,
                          backgroundColor: cs.surfaceContainerHighest,
                          color: cs.primary,
                        ),
                        Text(
                          progress == null ? '' : '${(progress * 100).round()}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _stageRow(cs),
              const SizedBox(height: 12),
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
                '${_progress.speedBytesPerSec > 0 ? ' · ${_formatBytes(_progress.speedBytesPerSec)}/s' : ''}'
                '${_progress.etaSeconds > 0 ? ' · ${_progress.etaSeconds}s left' : ''}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stageRow(ColorScheme cs) {
    final stages = _threadStates.map((e) => e.status).toSet();
    final items = [
      ('Hashing', 'hashing', Icons.fingerprint),
      ('Checking', 'checking', Icons.search),
      ('Uploading', 'uploading', Icons.cloud_upload_outlined),
      ('Committing', 'finalizing', Icons.task_alt),
    ];
    return Row(
      children: [
        for (final (label, key, icon) in items)
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: stages.contains(key)
                    ? cs.primary.withValues(alpha: 0.10)
                    : cs.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: stages.contains(key)
                        ? cs.primary
                        : cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
      ],
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
        Expanded(
          child: SelectableText(
            _error!,
            style: TextStyle(color: cs.error, fontSize: 13),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => _error = null),
        ),
      ],
    ),
  );

  Widget _activity(ColorScheme cs) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Activity',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        PixieCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const MicroLabel('Session map'),
                  const Spacer(),
                  PillSwitch<int>(
                    values: const [0, 1, 2, 3],
                    labels: const ['All', 'Done', 'Skip', 'Fail'],
                    selected: _activityFilter,
                    onChanged: (v) => setState(() => _activityFilter = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DotMatrix(
                states: _results.reversed.map((r) {
                  if (r.isError) return 3;
                  if (r.skipped) return 2;
                  return 1;
                }).toList(),
              ),
              const SizedBox(height: 14),
              Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
              _activityBody(cs),
            ],
          ),
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
          child: Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: cs.primary.withValues(alpha: 0.12),
                child: Text(
                  '${event.workerId}',
                  style: TextStyle(fontSize: 10, color: cs.primary),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.fileName.isEmpty ? event.status : event.fileName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: event.bytesTotal > 0
                            ? (event.bytesUploaded / event.bytesTotal).clamp(
                                0.0,
                                1.0,
                              )
                            : null,
                        minHeight: 5,
                        color: cs.primary,
                        backgroundColor: cs.surfaceContainerHighest,
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
                      ? '${_formatBytes(event.bytesUploaded)}/${_formatBytes(event.bytesTotal)}'
                      : event.message,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      if (_threadStates.isNotEmpty)
        Divider(height: 20, color: cs.outlineVariant.withValues(alpha: 0.4)),
      SizedBox(
        height: 220,
        child: ListView.builder(
          itemCount: _filteredResults.length,
          itemBuilder: (context, i) {
            final r = _filteredResults[i];
            final color = r.isError
                ? dangerColor(context)
                : r.skipped
                ? warningColor(context)
                : successColor(context);
            final icon = r.isError
                ? Icons.error_outline
                : r.skipped
                ? Icons.remove_circle_outline
                : Icons.check_circle_outline;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fileThumb(r.path, icon, color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.path.split(Platform.pathSeparator).last,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          r.isError
                              ? r.errorMessage
                              : r.skipped
                              ? r.skipReason
                              : r.mediaKey,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
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

  List<UploadResult> get _filteredResults {
    if (_activityFilter == 0) return _results;
    return _results
        .where(
          (r) => switch (_activityFilter) {
            1 => !r.isError && !r.skipped,
            2 => r.skipped,
            3 => r.isError,
            _ => true,
          },
        )
        .toList();
  }

  Widget _fileThumb(String path, IconData fallback, Color color) {
    final ext = path.split('.').last.toLowerCase();
    const imageExts = [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'bmp',
    ];
    if (!imageExts.contains(ext)) {
      return Icon(fallback, size: 18, color: color);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.file(
        File(path),
        width: 30,
        height: 30,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(fallback, size: 18, color: color),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

class _UploadIntent extends Intent {
  const _UploadIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

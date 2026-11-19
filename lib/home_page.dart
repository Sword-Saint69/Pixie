import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gotohp_rs/brand.dart';
import 'package:gotohp_rs/src/rust/api.dart';
import 'package:gotohp_rs/src/rust/api/app_types.dart';
import 'package:material_ui/material_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppSettings? _settings;
  String _selected = '';
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
      final selected = await selectedAccount();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _selected = selected;
      });
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _pump() async {
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
              _error = _clean(event.message);
          }
        }
        _threadStates.sort((a, b) => a.workerId.compareTo(b.workerId));
      });
      if (!running) {
        _summary = await getSummary();
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  String _clean(Object e) => e
      .toString()
      .replaceFirst('AnyhowException(', '')
      .replaceAll(RegExp(r'\)$'), '');

  void _setError(Object e) {
    if (mounted) setState(() => _error = _clean(e));
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
    });
    try {
      await startUpload(
        paths: List.unmodifiable(_paths),
        settings: _settings!,
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
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.color ?? cs.onSurfaceVariant;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Send your photos to the cloud',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: cs.onSurface),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Drop files, choose a folder, and Pixie handles the rest.',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                      ],
                    ),
                  ),
                  _statChips(cs),
                ],
              ),
              const SizedBox(height: 22),
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
                  height: 170,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _dragOver ? cs.primary.withValues(alpha: 0.07) : cs.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: _dragOver ? cs.primary : cs.outlineVariant,
                      width: _dragOver ? 2.5 : 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _dragOver
                          ? Icon(Icons.download_rounded, size: 34, color: cs.primary)
                          : const PixieLogo(size: 40),
                      const SizedBox(height: 10),
                      Text(
                        _dragOver ? 'Release to add files' : 'Drop photos, videos or folders here',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text('or use the buttons below', style: TextStyle(fontSize: 12, color: muted)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
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
                    onPressed: _paths.isEmpty ? null : () => setState(() => _paths.clear()),
                    child: const Text('Clear'),
                  ),
                ],
              ),
              if (_paths.isNotEmpty) ...[
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
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
                            onDeleted: () => setState(() => _paths.removeAt(i)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _albumController,
                      decoration: const InputDecoration(
                        labelText: 'Album name (optional)',
                        prefixIcon: Icon(Icons.photo_album_outlined, size: 18),
                      ),
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
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _running ? cancelUpload : null,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
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
                        child: SelectableText(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _error = null),
                      ),
                    ],
                  ),
                ),
              ],
              if (_threadStates.isNotEmpty || _results.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Activity',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _activity(cs, muted),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statChips(ColorScheme cs) => Row(
        children: [
          _chip('${_summary.total}', 'files', Icons.folder_open_outlined, cs.onSurface, cs),
          const SizedBox(width: 8),
          _chip('${_summary.succeeded}', 'done', Icons.check_circle_outline, Colors.green.shade700, cs),
          const SizedBox(width: 8),
          _chip('${_summary.failed}', 'failed', Icons.error_outline, cs.error, cs),
        ],
      );

  Widget _chip(String value, String label, IconData icon, Color color, ColorScheme cs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 7),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: color)),
                Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ],
        ),
      );

  Widget _activity(ColorScheme cs, Color muted) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final event in _threadStates)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  CircleAvatar(radius: 13, backgroundColor: cs.primary.withValues(alpha: 0.12),
                      child: Text('${event.workerId}', style: TextStyle(fontSize: 10, color: cs.primary))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.fileName.isEmpty ? event.status : event.fileName,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: event.bytesTotal > 0
                                ? (event.bytesUploaded / event.bytesTotal).clamp(0.0, 1.0)
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
                          ? '${event.bytesUploaded ~/ 1024}/${event.bytesTotal ~/ 1024} KiB'
                          : event.message,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 10, color: muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (_threadStates.isNotEmpty) Divider(height: 20, color: cs.outlineVariant.withValues(alpha: 0.4)),
          SizedBox(
            height: 220,
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                final color = r.isError ? cs.error : r.skipped ? Colors.orange.shade700 : Colors.green.shade700;
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
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              r.isError ? r.errorMessage : r.skipped ? r.skipReason : r.mediaKey,
                              style: TextStyle(fontSize: 11, color: muted),
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

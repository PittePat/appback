import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../controllers/shizuku_controller.dart';
import '../models/app_info.dart';

/// The single main screen: list installed apps, back up / restore each one.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ShizukuController _controller = ShizukuController();

  List<AppInfo> _apps = [];
  bool _loading = false;
  String _filter = '';
  String? _busyPackage; // package currently being backed up / restored

  // Decoded icon cache, keyed by package. Null value = "tried, none available".
  // Persists across scroll/rebuilds so we never re-fetch or re-decode an icon.
  final Map<String, Uint8List?> _iconCache = {};

  List<AppInfo> get _visibleApps {
    if (_filter.isEmpty) return _apps;
    final f = _filter.toLowerCase();
    return _apps
        .where((a) =>
            a.packageName.toLowerCase().contains(f) ||
            a.displayName.toLowerCase().contains(f))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    // print('Refreshing app list...');
    final conn = await _controller.ensureConnected();
    if (!conn.success) {
      setState(() => _loading = false);
      // Connection failures carry detailed native diagnostics — show them in full
      // (scrollable/selectable) so the actual cause is visible on-device.
      await _showDetails('Could not connect to Shizuku', conn.message);
      return;
    }
    try {
      final apps = await _controller.loadApps();
      setState(() {
        _apps = apps;
        _iconCache.clear();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _toast('Failed to load apps: $e', error: true);
    }
  }

  Future<void> _backup(AppInfo app) async {
    setState(() => _busyPackage = app.packageName);
    final res = await _controller.backup(app.packageName);
    setState(() => _busyPackage = null);
    _toast(res.message, error: !res.success);
    if (res.success) _refresh();
  }

  Future<void> _restore(AppInfo app) async {
    final confirmed = await _confirmRestore(app);
    if (!confirmed) return;
    setState(() => _busyPackage = app.packageName);
    final res = await _controller.restore(app.packageName);
    setState(() => _busyPackage = null);
    _toast(res.message, error: !res.success);
  }

  Future<void> _cloudBackup(AppInfo app) async {
    setState(() => _busyPackage = app.packageName);
    final res = await _controller.cloudBackup(app.packageName);
    setState(() => _busyPackage = null);
    _toast(res.message, error: !res.success);
  }

  Future<void> _cloudRestore(AppInfo app) async {
    setState(() => _busyPackage = app.packageName);
    final res = await _controller.cloudRestore(app.packageName);
    setState(() => _busyPackage = null);
    _toast(res.message, error: !res.success);
  }

  Future<bool> _confirmRestore(AppInfo app) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Load checkpoint?'),
            content: Text(
              'This reloads the saved checkpoint for "${app.displayName}", '
              'replacing its current data. The app will be force-stopped first '
              'so it picks up the restored state.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Load'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  /// Show full multi-line diagnostics in a scrollable, selectable dialog.
  /// Used for bind/connection failures so the real reason is visible on-device.
  Future<void> _showDetails(String title, String body) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              body,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AppBack · Checkpoints'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search apps & games',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_apps.isEmpty) {
      return _EmptyState(onConnect: _refresh);
    }
    final apps = _visibleApps;
    if (apps.isEmpty) {
      return const Center(child: Text('No packages match your search.'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        // Fixed row height lets Flutter skip per-item layout measurement,
        // which is the main source of scroll jank on long lists.
        itemExtent: 72,
        itemCount: apps.length,
        // Keep the scroll cheap: don't retain offscreen tile state.
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemBuilder: (_, i) {
          final app = apps[i];
          return _appTile(app);
        },
      ),
    );
  }

  Widget _appTile(AppInfo app) {
    final busy = _busyPackage == app.packageName;
    final theme = Theme.of(context);
    return ListTile(
      key: ValueKey(app.packageName),
      onTap: busy ? null : () => _openAppSheet(app),
      leading: _AppIcon(
        packageName: app.packageName,
        fallbackLetter:
            app.displayName.isNotEmpty ? app.displayName[0].toUpperCase() : '?',
        cache: _iconCache,
        load: _controller.appIcon,
      ),
      title: Text(app.displayName, overflow: TextOverflow.ellipsis),
      subtitle: app.hasCheckpoint
          ? Row(
              children: [
                Icon(Icons.bookmark, size: 13, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Checkpoint · ${app.checkpointAgo}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.primary),
                  ),
                ),
              ],
            )
          : Text(
              'No checkpoint yet',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
      trailing: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
    );
  }

  /// Opens the per-app action sheet — the "Save Scummer" control panel.
  Future<void> _openAppSheet(AppInfo app) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _AppActionSheet(
        app: app,
        iconCache: _iconCache,
        loadIcon: _controller.appIcon,
        onFreeze: () {
          Navigator.pop(ctx);
          _backup(app);
        },
        onLoad: app.hasCheckpoint
            ? () {
                Navigator.pop(ctx);
                _restore(app);
              }
            : null,
        onCloudUpload: () {
          Navigator.pop(ctx);
          _cloudBackup(app);
        },
        onCloudPull: () {
          Navigator.pop(ctx);
          _cloudRestore(app);
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onConnect});
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bookmark_added_outlined, size: 64),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Make sure Shizuku is running, then connect to list your apps '
              'and set checkpoints.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onConnect,
            icon: const Icon(Icons.link),
            label: const Text('Connect & load apps'),
          ),
        ],
      ),
    );
  }
}


/// A 40x40 app icon that loads lazily and caches the decoded bytes in a
/// shared map. While loading (or if no icon exists) it shows a letter avatar.
///
/// The [cache] is owned by the list state so an icon is fetched/decoded at most
/// once per package, keeping scrolling smooth.
class _AppIcon extends StatefulWidget {
  const _AppIcon({
    required this.packageName,
    required this.fallbackLetter,
    required this.cache,
    required this.load,
  });

  final String packageName;
  final String fallbackLetter;
  final Map<String, Uint8List?> cache;
  final Future<String?> Function(String packageName) load;

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(_AppIcon old) {
    super.didUpdateWidget(old);
    // Tiles are recycled (fixed extent + keys), so react if the package changes.
    if (old.packageName != widget.packageName) _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    // Already cached (including a cached "no icon" null) → nothing to do.
    if (widget.cache.containsKey(widget.packageName)) return;
    final b64 = await widget.load(widget.packageName);
    if (!mounted) return;
    Uint8List? bytes;
    if (b64 != null && b64.isNotEmpty) {
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        bytes = null;
      }
    }
    setState(() => widget.cache[widget.packageName] = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.cache[widget.packageName];
    if (bytes != null) {
      return SizedBox(
        width: 40,
        height: 40,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      );
    }
    // Loading or no-icon: letter avatar fallback.
    return CircleAvatar(
      radius: 20,
      child: Text(widget.fallbackLetter),
    );
  }
}

/// The per-app "Save Scummer" control panel shown as a bottom sheet.
///
/// - Freeze  = set an on-device checkpoint (bmgr local snapshot). One slot;
///             a new freeze replaces the old one.
/// - Load    = reload the checkpoint (bmgr restore). Only when one exists.
/// - Cloud   = upload/pull via Google's transport for cross-device sync.
class _AppActionSheet extends StatelessWidget {
  const _AppActionSheet({
    required this.app,
    required this.iconCache,
    required this.loadIcon,
    required this.onFreeze,
    required this.onLoad,
    required this.onCloudUpload,
    required this.onCloudPull,
  });

  final AppInfo app;
  final Map<String, Uint8List?> iconCache;
  final Future<String?> Function(String) loadIcon;
  final VoidCallback onFreeze;
  final VoidCallback? onLoad; // null when there's no checkpoint to load
  final VoidCallback onCloudUpload;
  final VoidCallback onCloudPull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: icon + name + package
            Row(
              children: [
                _AppIcon(
                  packageName: app.packageName,
                  fallbackLetter: app.displayName.isNotEmpty
                      ? app.displayName[0].toUpperCase()
                      : '?',
                  cache: iconCache,
                  load: loadIcon,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.displayName,
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis),
                      Text(app.packageName,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Checkpoint status banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: app.hasCheckpoint
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    app.hasCheckpoint ? Icons.bookmark : Icons.bookmark_border,
                    color: app.hasCheckpoint
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.hintColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      app.hasCheckpoint
                          ? 'Checkpoint set ${app.checkpointAgo}'
                          : 'No checkpoint yet — freeze the current state to '
                              'create one.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Primary actions: Freeze + Load
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onFreeze,
                    icon: const Icon(Icons.ac_unit),
                    label:
                        Text(app.hasCheckpoint ? 'Re-freeze' : 'Freeze state'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onLoad,
                    icon: const Icon(Icons.restore),
                    label: const Text('Load'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'One checkpoint per app. Re-freezing replaces it.',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),

            const Divider(height: 28),

            // Cloud (cross-device) actions
            Text('Cloud sync (another phone, same Google account)',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCloudUpload,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Upload'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCloudPull,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Pull'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

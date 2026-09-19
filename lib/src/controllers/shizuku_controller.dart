import 'package:flutter/services.dart';

import '../models/app_info.dart';
import '../services/shizuku_manager.dart';

/// Outcome of a backup/restore action, ready for the UI to show.
class ActionResult {
  const ActionResult(this.success, this.message);
  final bool success;
  final String message;
}

/// High-level orchestration of the Shizuku + backup workflow.
///
/// Owns the connection lifecycle and turns raw channel calls into
/// UI-friendly results. The UI talks only to this class.
class ShizukuController {
  final ShizukuManager _shizuku = ShizukuManager();

  bool _connected = false;
  bool get isConnected => _connected;

  /// Ensure Shizuku permission is granted and the privileged service is bound.
  /// Safe to call repeatedly; it no-ops once connected.
  Future<ActionResult> ensureConnected() async {
    if (_connected) return const ActionResult(true, 'Connected.');

    final granted = await _shizuku.checkAndRequestPermission();
    if (!granted) {
      return const ActionResult(
          false, 'Shizuku permission denied or Shizuku is not running.');
    }

    // bindService now resolves only after onServiceConnected fires (or times out),
    // so the privileged service is genuinely ready here — no guess-sleep needed.
    try {
      final bound = await _shizuku.connectToService();
      if (!bound) {
        return const ActionResult(false, 'Could not bind the Shizuku service.');
      }
    } on PlatformException catch (e) {
      // Surface the FULL native diagnostics so bind failures are debuggable
      // on-device (especially OEM ROMs that throttle Shizuku).
      final details = e.details is String ? e.details as String : '';
      final msg = StringBuffer()
        ..writeln('Bind failed [${e.code}]')
        ..writeln(e.message ?? '')
        ..write(details);
      return ActionResult(false, msg.toString().trim());
    }

    _connected = true;
    return const ActionResult(true, 'Connected.');
  }

  /// Load installed apps merged with any existing backups.
  Future<List<AppInfo>> loadApps({bool includeSystem = false}) async {
    final packages = await _shizuku.listApps(includeSystem: includeSystem);
    final backups = await _shizuku.listBackups();

    final allPackages = <String>{...packages, ...backups.keys}.toList();

    // Batch-resolve human-readable labels in ONE native call (fast; no per-app
    // round-trips). Icons are loaded lazily per-tile by the UI to keep this snappy.
    Map<String, String> labels = const {};
    try {
      labels = await _shizuku.getAppLabels(allPackages);
    } catch (_) {
      // Non-fatal: fall back to package names.
    }

    final apps = allPackages
        .map((p) => AppInfo(
              packageName: p,
              label: labels[p],
              checkpointAt: backups[p],
            ))
        .toList();

    // Sort by what the user actually sees (label, case-insensitive).
    apps.sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return apps;
  }

  /// Fetch an app's icon (base64 PNG) for lazy per-tile loading.
  Future<String?> appIcon(String packageName) async {
    try {
      return await _shizuku.getAppIcon(packageName);
    } catch (_) {
      return null;
    }
  }

  Future<ActionResult> backup(String packageName) async {
    final conn = await ensureConnected();
    if (!conn.success) return conn;
    try {
      final msg = await _shizuku.backupApp(packageName);
      return ActionResult(true, msg);
    } on PlatformException catch (e) {
      return ActionResult(false, e.message ?? 'Backup failed.');
    }
  }

  Future<ActionResult> restore(String packageName) async {
    final conn = await ensureConnected();
    if (!conn.success) return conn;
    try {
      final msg = await _shizuku.restoreApp(packageName);
      return ActionResult(true, msg);
    } on PlatformException catch (e) {
      return ActionResult(false, e.message ?? 'Restore failed.');
    }
  }

  Future<ActionResult> cloudBackup(String packageName) async {
    final conn = await ensureConnected();
    if (!conn.success) return conn;
    try {
      final msg = await _shizuku.cloudBackup(packageName);
      return ActionResult(true, msg);
    } on PlatformException catch (e) {
      return ActionResult(false, e.message ?? 'Cloud upload failed.');
    }
  }

  Future<ActionResult> cloudRestore(String packageName) async {
    final conn = await ensureConnected();
    if (!conn.success) return conn;
    try {
      final msg = await _shizuku.cloudRestore(packageName);
      return ActionResult(true, msg);
    } on PlatformException catch (e) {
      return ActionResult(false, e.message ?? 'Cloud restore failed.');
    }
  }
}

import 'package:flutter/services.dart';

import '../constants.dart';

/// Low-level wrapper around the platform [MethodChannel].
///
/// This is the Dart mirror of the methods exposed in `MainActivity.kt`.
/// It knows *how* to talk to the native side, but nothing about *when* or
/// *why* — that orchestration lives in `ShizukuController`.
class ShizukuManager {
  // Must match the CHANNEL string inside MainActivity.kt exactly.
  static const _channel = MethodChannel(kMethodChannelName);

  /// Ask the user for permission via Shizuku's dialog.
  Future<bool> checkAndRequestPermission() async {
    try {
      final bool isGranted =
          await _channel.invokeMethod('requestShizukuPermission');
      return isGranted;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print("Shizuku Permission Error: ${e.message} (Code: ${e.code})");
      return false;
    }
  }

  /// Bind our ShizukuShellService into Shizuku's privileged process.
  /// Returns true on success. Throws [PlatformException] with code/message/details
  /// on failure so the caller can surface the real diagnostics.
  Future<bool> connectToService() async {
    final bool contextBound = await _channel.invokeMethod('bindService');
    return contextBound;
  }

  /// Batch-fetch human-readable labels. Returns a map of packageName -> label.
  /// Packages without a resolvable label are omitted.
  Future<Map<String, String>> getAppLabels(List<String> packages) async {
    final String? raw = await _channel.invokeMethod('getAppLabels', {
      'packages': packages,
    });
    if (raw == null || raw.isEmpty) return const {};
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      if (line.isEmpty) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      map[line.substring(0, tab)] = line.substring(tab + 1);
    }
    return map;
  }

  /// Fetch a single app's icon as a base64 PNG string, or null if unavailable.
  Future<String?> getAppIcon(String packageName) async {
    return await _channel.invokeMethod<String>('getAppIcon', {
      'package_name': packageName,
    });
  }

  /// List installed package names. Set [includeSystem] to include system apps.
  Future<List<String>> listApps({bool includeSystem = false}) async {
    final String? raw = await _channel.invokeMethod('listApps', {
      'include_system': includeSystem,
    });
    if (raw == null) return const [];
    return raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Existing backups as a map of packageName -> size in bytes.
  /// Map of package -> checkpoint time (when the on-device snapshot was set).
  Future<Map<String, DateTime>> listBackups() async {
    final String? raw = await _channel.invokeMethod('listBackups');
    final map = <String, DateTime>{};
    if (raw == null) return map;
    for (final line in raw.split('\n')) {
      final parts = line.split('\t');
      if (parts.length == 2) {
        final epoch = int.tryParse(parts[1].trim());
        if (epoch != null && epoch > 0) {
          map[parts[0].trim()] =
              DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
        }
      }
    }
    return map;
  }

  /// Back up a package to a portable .ab file.
  /// Throws [PlatformException] on failure (including user cancel).
  Future<String> backupApp(String packageName) async {
    final String? msg = await _channel.invokeMethod('backupAppData', {
      'package_name': packageName,
    });
    return msg ?? 'Backup complete.';
  }

  /// Restore a package from its portable .ab file.
  /// Throws [PlatformException] on failure.
  Future<String> restoreApp(String packageName) async {
    final String? msg = await _channel.invokeMethod('restoreAppData', {
      'package_name': packageName,
    });
    return msg ?? 'Restore triggered.';
  }

  /// EXPERIMENT: upload the app's data to Google's cloud backup transport.
  /// Throws [PlatformException] with the raw output on failure/uncertainty.
  Future<String> cloudBackup(String packageName) async {
    final String? msg = await _channel.invokeMethod('cloudBackup', {
      'package_name': packageName,
    });
    return msg ?? 'Cloud upload triggered.';
  }

  /// EXPERIMENT: restore the app's data from Google's cloud backup transport.
  /// Throws [PlatformException] with the raw output on failure/uncertainty.
  Future<String> cloudRestore(String packageName) async {
    final String? msg = await _channel.invokeMethod('cloudRestore', {
      'package_name': packageName,
    });
    return msg ?? 'Cloud restore triggered.';
  }

  /// Sanity check that the native bridge is alive.
  Future<String> testNative() async {
    try {
      final String? result = await _channel.invokeMethod('testNative');
      return result ?? "No message received from native code.";
    } on PlatformException catch (e) {
      return "Failed to invoke native method: '${e.message}'.";
    }
  }
}

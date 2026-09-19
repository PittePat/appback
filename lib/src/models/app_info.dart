/// A single installed application entry, plus its checkpoint state.
class AppInfo {
  const AppInfo({
    required this.packageName,
    this.label,
    this.checkpointAt,
  });

  /// e.g. "com.rectfy.birdybird"
  final String packageName;

  /// Human-readable name, e.g. "Birdy Bird". Null until resolved.
  final String? label;

  /// When the on-device checkpoint was set, or null if none exists.
  final DateTime? checkpointAt;

  bool get hasCheckpoint => checkpointAt != null;

  /// What to show as the primary line: the label if we have one, else the package.
  String get displayName =>
      (label != null && label!.isNotEmpty) ? label! : packageName;

  AppInfo copyWith({
    String? label,
    DateTime? checkpointAt,
    bool clearCheckpoint = false,
  }) {
    return AppInfo(
      packageName: packageName,
      label: label ?? this.label,
      checkpointAt: clearCheckpoint ? null : (checkpointAt ?? this.checkpointAt),
    );
  }

  /// Human-friendly "how long ago" the checkpoint was set, e.g. "3 min ago".
  String get checkpointAgo {
    final at = checkpointAt;
    if (at == null) return '';
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr ago';
    if (d.inDays < 7) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }
}

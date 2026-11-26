/// A TV, set-top box or speaker found on the Wi-Fi that can play media (DLNA).
class CastDevice {
  const CastDevice({
    required this.name,
    required this.controlUrl,
    required this.serviceType,
    this.renderUrl,
    this.renderType,
  });

  final String name;
  final String controlUrl;
  final String serviceType;
  final String? renderUrl;
  final String? renderType;

  factory CastDevice.fromMap(Map<dynamic, dynamic> m) => CastDevice(
        name: m['name'] as String? ?? 'TV',
        controlUrl: m['controlUrl'] as String? ?? '',
        serviceType: m['serviceType'] as String? ?? '',
        renderUrl: m['renderUrl'] as String?,
        renderType: m['renderType'] as String?,
      );

  Map<String, Object?> toMap() => {
        'name': name,
        'controlUrl': controlUrl,
        'serviceType': serviceType,
        'renderUrl': renderUrl,
        'renderType': renderType,
      };
}

/// One thing to play on the TV: a saved file, or a YouTube link played as a stream.
class CastItem {
  const CastItem({required this.uri, required this.title, required this.mime, this.stream = false});

  final String uri;
  final String title;
  final String mime;
  final bool stream;

  Map<String, Object?> toMap() => {'uri': uri, 'title': title, 'mime': mime, 'stream': stream};
}

/// What the TV is doing right now, as reported by the native casting session.
class CastState {
  const CastState({
    this.status = 'idle',
    this.device = '',
    this.title,
    this.uri,
    this.volume = -1,
    this.index = 0,
    this.count = 0,
    this.next = '',
    this.error,
  });

  const CastState.idle() : this();

  final String status;
  final String device;
  final String? title;
  final String? uri;
  final int volume;
  final int index;
  final int count;
  final String next;
  final String? error;

  /// True while a session is running (so the control bar is shown).
  bool get active => const {'connecting', 'loading', 'playing', 'paused'}.contains(status);

  bool get paused => status == 'paused';

  factory CastState.fromMap(Map<dynamic, dynamic> m) => CastState(
        status: m['status'] as String? ?? 'idle',
        device: m['device'] as String? ?? '',
        title: m['title'] as String?,
        uri: m['uri'] as String?,
        volume: (m['volume'] as num?)?.toInt() ?? -1,
        index: (m['index'] as num?)?.toInt() ?? 0,
        count: (m['count'] as num?)?.toInt() ?? 0,
        next: m['next'] as String? ?? '',
        error: m['error'] as String?,
      );
}

/// Playback position on the TV, in seconds.
class CastProgress {
  const CastProgress({this.position = 0, this.duration = 0});

  final int position;
  final int duration;
}

/// One place in the TV's queue.
class QueueEntry {
  const QueueEntry({required this.uri, required this.title});

  final String uri;
  final String title;
}

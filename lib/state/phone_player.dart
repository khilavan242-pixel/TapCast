import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../services/native.dart';

/// One video (or song) in the phone's own queue.
class PhoneItem {
  PhoneItem(this.id, this.title);

  final String id;
  String title;
}

/// Plays a YouTube video or song on the phone itself (when no TV can be used).
/// Keeps playing in the background with notification buttons; the screen shows
/// a floating window (video) or a small in-app card (music).
class PhonePlayer extends ChangeNotifier {
  PhonePlayer(this.native) {
    _sub = native.events.listen(_onEvent);
  }

  final Native native;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  static const _legacyAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  final List<PhoneItem> queue = [];
  VideoPlayerController? _vc;
  bool _active = false;
  int index = 0;
  bool audioOnly = false;
  bool shorts = false;
  bool loading = false;
  bool inPip = false;
  bool pageOpen = false;
  int repeat = 0; // 0 off, 1 all, 2 one
  String? error;

  int _seq = 0;
  int _fillSeq = 0;
  bool _ended = false;
  bool _lastPlaying = false;
  int _lastPub = 0;

  bool get active => _active;
  VideoPlayerController? get controller => _vc;
  PhoneItem? get current => _active && index >= 0 && index < queue.length ? queue[index] : null;
  bool get playing => _vc?.value.isPlaying ?? false;

  void _onEvent(Map<dynamic, dynamic> e) {
    switch (e['type']) {
      case 'phoneCtl':
        if (_active) control(e['action'] as String? ?? '', (e['value'] as num?)?.toInt() ?? 0);
      case 'pip':
        final on = e['on'] == true;
        if (on != inPip) {
          inPip = on;
          notifyListeners();
        }
    }
  }

  void setPageOpen(bool v) {
    if (pageOpen == v) return;
    pageOpen = v;
    notifyListeners();
  }

  /// Starts [id] and fills the queue with what YouTube plays next.
  Future<void> start(String id, {bool audio = false, bool isShorts = false, String title = ''}) async {
    _dropController();
    queue
      ..clear()
      ..add(PhoneItem(id, title));
    index = 0;
    audioOnly = audio;
    shorts = isShorts;
    _active = true;
    error = null;
    notifyListeners();
    unawaited(_fill(id, ++_fillSeq));
    await _open();
  }

  Future<void> _fill(String id, int mine) async {
    List<Map<String, String>> list;
    try {
      list = await native.phoneNext(id, shorts: shorts);
    } catch (_) {
      return;
    }
    if (!_active || mine != _fillSeq) return;
    final known = queue.map((q) => q.id).toSet();
    for (final m in list) {
      final vid = m['id'] ?? '';
      if (vid.isEmpty || !known.add(vid)) continue;
      queue.add(PhoneItem(vid, m['title'] ?? ''));
    }
    notifyListeners();
    _publish(_lastPlaying ? 'playing' : 'paused');
  }

  void _dropController() {
    final old = _vc;
    _vc = null;
    if (old != null) {
      old.removeListener(_tick);
      // The screen may still draw it for one more frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  Future<(VideoPlayerController, Map<String, dynamic>)> _openStream(String id, {required bool legacy}) async {
    final info = await native.phoneResolve(id, legacy: legacy, audio: audioOnly);
    final vc = VideoPlayerController.networkUrl(
      Uri.parse(info['url'] as String),
      httpHeaders: legacy ? const {'User-Agent': _legacyAgent} : const <String, String>{},
    );
    try {
      await vc.initialize();
    } catch (_) {
      await vc.dispose();
      rethrow;
    }
    return (vc, info);
  }

  Future<void> _open({int skips = 0}) async {
    final seq = ++_seq;
    if (index < 0 || index >= queue.length) return;
    final item = queue[index];
    _ended = false;
    _lastPlaying = false;
    loading = true;
    error = null;
    _dropController();
    notifyListeners();
    _publish('loading');
    try {
      (VideoPlayerController, Map<String, dynamic>) opened;
      try {
        opened = await _openStream(item.id, legacy: false);
      } catch (_) {
        if (seq != _seq) return;
        opened = await _openStream(item.id, legacy: true);
      }
      if (seq != _seq) {
        await opened.$1.dispose();
        return;
      }
      final vc = opened.$1;
      final title = (opened.$2['title'] as String?) ?? '';
      if (title.isNotEmpty) item.title = title;
      _vc = vc;
      vc.addListener(_tick);
      await vc.setLooping(repeat == 2);
      await vc.play();
      loading = false;
      _lastPlaying = true;
      notifyListeners();
      _publish('playing');
      unawaited(native.setPhoneVideo(ready: !audioOnly, playing: true));
    } catch (_) {
      if (seq != _seq) return;
      loading = false;
      if (index + 1 < queue.length && skips < 3) {
        // This one cannot be played: go on to the next, like the YouTube app.
        index++;
        await _open(skips: skips + 1);
        return;
      }
      error = 'Could not play this video';
      notifyListeners();
    }
  }

  void _tick() {
    final vc = _vc;
    if (vc == null || !_active) return;
    final v = vc.value;
    final nowPlaying = v.isPlaying;
    if (nowPlaying != _lastPlaying) {
      _lastPlaying = nowPlaying;
      _publish(nowPlaying ? 'playing' : 'paused');
      unawaited(native.setPhoneVideo(ready: !audioOnly, playing: nowPlaying));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPub >= 1000 && v.isInitialized) {
      _lastPub = now;
      unawaited(native.phonePos(v.position.inSeconds, v.duration.inSeconds));
    }
    if (!_ended &&
        v.isInitialized &&
        v.duration.inSeconds > 0 &&
        !nowPlaying &&
        repeat != 2 &&
        v.position >= v.duration - const Duration(milliseconds: 400)) {
      _ended = true;
      unawaited(next(auto: true));
      return;
    }
    notifyListeners();
  }

  void _publish(String status) {
    final item = current;
    if (item == null) return;
    unawaited(native
        .phoneState(status: status, id: item.id, title: item.title, index: index, count: queue.length)
        .catchError((Object _) {}));
  }

  Future<void> next({bool auto = false}) async {
    if (!_active) return;
    if (index + 1 < queue.length) {
      index++;
      await _open();
    } else if (repeat == 1 && queue.isNotEmpty) {
      index = 0;
      await _open();
    } else if (auto) {
      await stop();
    }
  }

  Future<void> previous() async {
    if (!_active) return;
    final vc = _vc;
    if (vc != null && vc.value.position.inSeconds > 3) {
      await vc.seekTo(Duration.zero);
    } else if (index > 0) {
      index--;
      await _open();
    } else {
      await vc?.seekTo(Duration.zero);
    }
  }

  Future<void> jumpTo(int i) async {
    if (!_active || i < 0 || i >= queue.length) return;
    index = i;
    await _open();
  }

  void cycleRepeat() {
    repeat = (repeat + 1) % 3;
    _vc?.setLooping(repeat == 2);
    notifyListeners();
  }

  Future<void> seek(int seconds) async => _vc?.seekTo(Duration(seconds: seconds));

  void control(String action, int value) {
    switch (action) {
      case 'pause':
        _vc?.pause();
      case 'resume':
        _vc?.play();
      case 'next':
        unawaited(next());
      case 'previous':
        unawaited(previous());
      case 'seek':
        unawaited(seek(value));
      case 'stop':
        unawaited(stop());
    }
  }

  void togglePlay() => control(playing ? 'pause' : 'resume', 0);

  Future<void> stop() async {
    if (!_active) return;
    _seq++;
    _fillSeq++;
    _active = false;
    _dropController();
    queue.clear();
    loading = false;
    inPip = false;
    _lastPlaying = false;
    notifyListeners();
    try {
      await native.setPhoneVideo(ready: false, playing: false);
      await native.phoneEnd();
    } catch (_) {/* nothing to end */}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _vc?.dispose();
    super.dispose();
  }
}

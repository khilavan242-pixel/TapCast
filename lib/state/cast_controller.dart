import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/cast.dart';
import '../services/native.dart';
import '../services/store.dart';
import '../utils/url_utils.dart';

/// Everything about the TV: which one is chosen, what it plays, the buttons.
class CastController extends ChangeNotifier {
  CastController({required this.native, required this.store}) {
    _device = store.device;
    _shuffle = store.shuffle;
    _recent = List.of(store.recent);
    unawaited(native.setShuffle(_shuffle));
    _sub = native.events.listen(_onEvent);
    unawaited(_syncState());
  }

  final Native native;
  final Store store;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  CastDevice? _device;
  CastState _cast = const CastState.idle();
  CastProgress _progress = const CastProgress();
  int _shuffle = 0;
  List<RecentItem> _recent = [];
  List<CastDevice> _found = const [];
  bool _searching = false;
  String? _message;
  bool _unreachable = false;
  int _queueIndex = 0;
  List<QueueEntry> _queue = const [];
  String _queueKey = '';

  CastDevice? get device => _device;
  CastState get cast => _cast;
  CastProgress get progress => _progress;
  int get shuffle => _shuffle;
  List<RecentItem> get recent => _recent;
  List<CastDevice> get found => _found;
  List<QueueEntry> get queue => _queue;
  int get queueIndex => _queueIndex;
  bool get searching => _searching;

  /// A short message for the screen (shown once, then cleared).
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  /// True once after a cast failed because the TV did not answer.
  bool takeUnreachable() {
    final u = _unreachable;
    _unreachable = false;
    return u;
  }

  ThemeMode get themeMode => switch (store.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  void setThemeMode(String v) {
    store.themeMode = v;
    notifyListeners();
  }

  Future<void> _syncState() async {
    try {
      _cast = await native.state();
      notifyListeners();
    } catch (_) {/* not casting */}
  }

  void _onEvent(Map<dynamic, dynamic> e) {
    switch (e['type']) {
      case 'cast':
        _cast = CastState.fromMap(e);
        if (_cast.status == 'error' && _cast.error != null) _message = _cast.error;
        _noteTitle();
        notifyListeners();
        unawaited(_refreshQueue());
      case 'castPos':
        _progress = CastProgress(
          position: (e['position'] as num?)?.toInt() ?? 0,
          duration: (e['duration'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
    }
  }

  /// Keeps the titles in Recent filled in once the TV reports them.
  void _noteTitle() {
    final id = _cast.uri == null ? null : UrlUtils.videoId(_cast.uri!);
    final t = _cast.title;
    if (id == null || t == null || t.isEmpty || t == 'YouTube video') return;
    final i = _recent.indexWhere((r) => r.id == id);
    if (i >= 0 && _recent[i].title.isEmpty) {
      _recent[i] = RecentItem(id: id, title: t);
      store.recent = _recent;
    }
  }

  Future<void> _refreshQueue() async {
    if (!_cast.active) {
      if (_queue.isNotEmpty) {
        _queue = const [];
        _queueKey = '';
        notifyListeners();
      }
      return;
    }
    final key = '${_cast.index}/${_cast.count}/${_cast.uri}';
    if (key == _queueKey) return;
    _queueKey = key;
    try {
      final (index, list) = await native.queue();
      _queueIndex = index;
      _queue = list;
      notifyListeners();
    } catch (_) {/* keep the old list */}
  }

  Future<void> jumpTo(int index) => native.control('jump', value: index);

  /// Looks for TVs on the Wi-Fi.
  Future<void> search() async {
    if (_searching) return;
    _searching = true;
    notifyListeners();
    try {
      _found = await native.discover();
    } catch (_) {
      _found = const [];
    }
    _searching = false;
    notifyListeners();
  }

  void chooseDevice(CastDevice d) {
    _device = d;
    store.device = d;
    notifyListeners();
  }

  void forgetDevice() {
    _device = null;
    store.device = null;
    notifyListeners();
  }

  /// Plays a YouTube video on the chosen TV and keeps going with the next ones.
  Future<bool> castVideo(String id, {String? title, String? listUrl, bool shorts = false}) async {
    final d = _device;
    if (d == null) return false;
    try {
      await native.castYoutube(d, id, listUrl: listUrl, shorts: shorts);
    } catch (e) {
      _unreachable = e is PlatformException && e.code == 'unreachable';
      _message = 'Could not reach ${d.name}';
      notifyListeners();
      return false;
    }
    _remember(id, title ?? '');
    return true;
  }

  Future<bool> castFiles(List<CastItem> items) async {
    final d = _device;
    if (d == null || items.isEmpty) return false;
    try {
      await native.castFiles(d, items);
      return true;
    } catch (e) {
      _unreachable = e is PlatformException && e.code == 'unreachable';
      _message = 'Could not reach ${d.name}';
      notifyListeners();
      return false;
    }
  }

  void _remember(String id, String title) {
    _recent.removeWhere((r) => r.id == id);
    _recent.insert(0, RecentItem(id: id, title: title));
    if (_recent.length > 40) _recent = _recent.sublist(0, 40);
    store.recent = _recent;
    notifyListeners();
  }

  void clearRecent() {
    _recent = [];
    store.recent = _recent;
    notifyListeners();
  }

  Future<void> control(String action, {int value = 0}) => native.control(action, value: value);

  void setShuffle(int mode) {
    _shuffle = mode;
    store.shuffle = mode;
    unawaited(native.setShuffle(mode));
    notifyListeners();
  }

  Future<List<CastItem>> pickMedia() => native.pickMedia();

  Future<void> exitApp() => native.exitApp();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/cast.dart';

/// One video the user cast before (shown on the Recent page).
class RecentItem {
  const RecentItem({required this.id, required this.title});

  final String id;
  final String title;

  Map<String, Object?> toMap() => {'id': id, 'title': title};

  static RecentItem? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'];
    if (id is! String) return null;
    return RecentItem(id: id, title: (m['title'] as String?) ?? '');
  }
}

/// Small settings kept on the phone. The `last_device` key is also read by the share pop-up (native).
class Store {
  Store._(this._prefs);

  final SharedPreferences _prefs;

  static Future<Store> open() async => Store._(await SharedPreferences.getInstance());

  CastDevice? get device {
    final text = _prefs.getString('last_device');
    if (text == null) return null;
    try {
      return CastDevice.fromMap(jsonDecode(text) as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  set device(CastDevice? d) {
    if (d == null) {
      _prefs.remove('last_device');
    } else {
      _prefs.setString('last_device', jsonEncode(d.toMap()));
    }
  }

  /// 0 off, 1 random, 2 smart.
  int get shuffle => _prefs.getInt('shuffle') ?? 0;
  set shuffle(int v) => _prefs.setInt('shuffle', v);

  /// system | light | dark
  String get themeMode => _prefs.getString('theme_mode') ?? 'system';
  set themeMode(String v) => _prefs.setString('theme_mode', v);

  List<RecentItem> get recent {
    final text = _prefs.getString('recent');
    if (text == null) return const [];
    try {
      final list = jsonDecode(text) as List<dynamic>;
      final out = <RecentItem>[];
      for (final e in list) {
        final item = RecentItem.fromMap(e);
        if (item != null) out.add(item);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  set recent(List<RecentItem> v) => _prefs.setString('recent', jsonEncode([for (final e in v) e.toMap()]));
}

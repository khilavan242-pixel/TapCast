import 'dart:async';

import 'package:flutter/services.dart';

import '../models/cast.dart';

/// Thin typed wrapper around the Android channels (`MainActivity.kt`).
class Native {
  Native()
      : _methods = const MethodChannel('tapcast/native'),
        _events = const EventChannel('tapcast/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<Map<dynamic, dynamic>>? _stream;

  /// Broadcast stream of `{type:'cast', ...}` and `{type:'castPos', ...}` events.
  Stream<Map<dynamic, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => e as Map<dynamic, dynamic>)
      .asBroadcastStream();

  Future<List<CastDevice>> discover() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('castDiscover');
    return (raw ?? const []).map(CastDevice.fromMap).toList();
  }

  Future<void> castYoutube(CastDevice device, String id, {String? listUrl, bool shorts = false}) =>
      _methods.invokeMethod<void>(
          'castYoutube', {'device': device.toMap(), 'id': id, 'listUrl': listUrl, 'shorts': shorts});

  /// The titles waiting on the TV and which one plays now.
  Future<(int, List<QueueEntry>)> queue() async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>('castQueue');
    final list = (raw?['items'] as List?) ?? const [];
    return (
      (raw?['index'] as num?)?.toInt() ?? 0,
      list
          .whereType<Map>()
          .map((m) => QueueEntry(uri: m['uri'] as String? ?? '', title: m['title'] as String? ?? ''))
          .toList(),
    );
  }

  /// Opens a link or file with the phone's own player.
  Future<void> viewExternal(String uri, {String? mime}) =>
      _methods.invokeMethod<void>('viewExternal', {'uri': uri, 'mime': mime});

  Future<void> castFiles(CastDevice device, List<CastItem> items) =>
      _methods.invokeMethod<void>('castPlay', {'device': device.toMap(), 'items': items.map((e) => e.toMap()).toList()});

  Future<void> control(String action, {int value = 0}) =>
      _methods.invokeMethod<void>('castControl', {'action': action, 'value': value});

  Future<CastState> state() async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>('castState');
    return raw == null ? const CastState.idle() : CastState.fromMap(raw);
  }

  Future<void> setShuffle(int mode) => _methods.invokeMethod<void>('setShuffle', {'mode': mode});

  Future<List<CastItem>> pickMedia() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('pickMedia');
    return (raw ?? const [])
        .map((m) => CastItem(
              uri: m['uri'] as String? ?? '',
              title: m['title'] as String? ?? 'Media',
              mime: m['mime'] as String? ?? 'video/mp4',
            ))
        .toList();
  }

  Future<void> exitApp() => _methods.invokeMethod<void>('exitApp');

  // ---- playing on the phone itself ----

  Future<Map<String, dynamic>> phoneResolve(String id, {bool legacy = false, bool audio = false}) async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>(
      'phoneResolve',
      {'id': id, 'legacy': legacy, 'audio': audio},
    );
    return {for (final e in (raw ?? const {}).entries) e.key.toString(): e.value};
  }

  /// Ids and titles of the videos that should follow [id].
  Future<List<Map<String, String>>> phoneNext(String id, {bool shorts = false}) async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('phoneNext', {'id': id, 'shorts': shorts});
    return [
      for (final m in raw ?? const <Map<dynamic, dynamic>>[])
        {'id': m['id'] as String? ?? '', 'title': m['title'] as String? ?? ''},
    ];
  }

  Future<void> phoneState({
    required String status,
    required String id,
    required String title,
    required int index,
    required int count,
  }) =>
      _methods.invokeMethod<void>(
        'phoneState',
        {'status': status, 'id': id, 'title': title, 'index': index, 'count': count},
      );

  Future<void> phonePos(int pos, int dur) => _methods.invokeMethod<void>('phonePos', {'pos': pos, 'dur': dur});

  Future<void> phoneEnd() => _methods.invokeMethod<void>('phoneEnd');

  /// Lets Android float the video (picture-in-picture) when the app is left.
  Future<void> setPhoneVideo({required bool ready, required bool playing}) =>
      _methods.invokeMethod<void>('setPhoneVideo', {'ready': ready, 'playing': playing});
}

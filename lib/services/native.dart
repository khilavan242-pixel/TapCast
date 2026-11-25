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

  Future<void> castYoutube(CastDevice device, String id, {String? listUrl}) =>
      _methods.invokeMethod<void>('castYoutube', {'device': device.toMap(), 'id': id, 'listUrl': listUrl});

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
}

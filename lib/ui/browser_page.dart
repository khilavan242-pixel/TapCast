import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/cast.dart';
import '../state/cast_controller.dart';
import '../utils/url_utils.dart';
import 'devices_sheet.dart';

/// Runs inside the YouTube page: tells the app when a video page opens (so it plays on the TV),
/// keeps the phone's own player silent and paused, and hides YouTube's bottom bar and banners.
const _script = r'''
(function(){
  if (window.__tcInit) return;
  window.__tcInit = true;
  function post(o) { try { TapCast.postMessage(JSON.stringify(o)); } catch (e) {} }
  var yt = /(^|\.)youtube\.com$/.test(location.hostname);
  // The video or song that is playing (or the first one on the page).
  function media() {
    var l = document.querySelectorAll('video,audio'), best = null;
    for (var i = 0; i < l.length; i++) {
      if (!l[i].paused && !l[i].ended) return l[i];
      if (!best && isFinite(l[i].duration) && l[i].duration > 0) best = l[i];
    }
    return best;
  }
  if (yt) {
    try {
      var st = document.createElement('style');
      st.textContent = 'ytm-pivot-bar-renderer,ytm-app-promo-renderer,ytm-promoted-sparkles-web-renderer{display:none!important}';
      document.head.appendChild(st);
    } catch (e) {}
  }
  // Any other website: look for the video the page plays so it can be cast.
  var seen = {};
  function add(u, kind) {
    try {
      if (!u || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      u = new URL(u, location.href).href;
      if (seen[u]) return;
      seen[u] = 1;
      post({t: 'media', url: u, kind: kind});
    } catch (e) {}
  }
  if (!yt) {
    var okUrl = function(u) { return /\.(m3u8|mp4)(\?|#|$)/i.test(String(u || '')); };
    try {
      var of = window.fetch;
      if (of) window.fetch = function(a) {
        try { var u = (a && a.url) ? a.url : a; if (okUrl(u)) add(String(u), 'net'); } catch (e) {}
        return of.apply(this, arguments);
      };
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        try { if (okUrl(u)) add(String(u), 'net'); } catch (e) {}
        return oo.apply(this, arguments);
      };
    } catch (e) {}
  }
  // Playing on the phone like a normal browser: the page keeps playing with sound and
  // thinks it is always visible (so it does not pause when the app is left).
  try {
    var hid = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
    var vis = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
    Object.defineProperty(document, 'hidden', {configurable: true, get: function() {
      return window.__tcPhone ? false : hid.get.call(document); }});
    Object.defineProperty(document, 'visibilityState', {configurable: true, get: function() {
      return window.__tcPhone ? 'visible' : vis.get.call(document); }});
    document.addEventListener('visibilitychange', function(e) {
      if (window.__tcPhone) e.stopImmediatePropagation();
    }, true);
  } catch (e) {}
  window.__tcSetPhone = function(on) {
    window.__tcPhone = !!on;
    try {
      if (window.__tcPoll) { clearInterval(window.__tcPoll); window.__tcPoll = 0; }
      var v = media();
      if (on) {
        if (v) { v.muted = false; var pr = v.play(); if (pr && pr.catch) pr.catch(function(){}); }
        window.__tcPoll = setInterval(function() {
          try {
            var w = media();
            if (!w) return;
            post({t: 'pstate', playing: !w.paused && !w.ended,
              pos: Math.floor(w.currentTime || 0), dur: isFinite(w.duration) ? Math.floor(w.duration) : 0,
              title: document.title.replace(/\s*-\s*YouTube( Music)?$/, ''), href: location.href});
          } catch (x) {}
        }, 1000);
      } else if (v) { v.pause(); v.muted = true; }
    } catch (x) {}
  };
  window.__tcCmd = function(a, val) {
    try {
      var v = media();
      if (!v) return;
      if (a === 'pause') v.pause();
      else if (a === 'resume') v.play();
      else if (a === 'seek') v.currentTime = val;
      else if (a === 'next') {
        var n = document.querySelector('button[aria-label*="Next" i],.ytp-next-button,button[class*="next" i]');
        if (n) n.click(); else if (isFinite(v.duration)) v.currentTime = v.duration;
      } else if (a === 'previous') {
        if (v.currentTime > 3) { v.currentTime = 0; }
        else {
          var p = document.querySelector('button[aria-label*="Previous" i],.ytp-prev-button,button[class*="prev" i]');
          if (p) p.click(); else v.currentTime = 0;
        }
      }
    } catch (x) {}
  };
  // Any other website that plays music or video (JioSaavn, Spotify web ...): show it in the notification.
  if (!yt) {
    var wasPlaying = false;
    setInterval(function() {
      try {
        var m = media();
        var playing = !!m && !m.paused && !m.ended && !m.muted && m.volume > 0;
        if (!playing && !wasPlaying) return;
        wasPlaying = playing;
        window.__tcPhone = playing;
        if (!m) return;
        post({t: 'pstate', web: true, playing: playing,
          pos: Math.floor(m.currentTime || 0), dur: isFinite(m.duration) ? Math.floor(m.duration) : 0,
          title: document.title, href: location.href});
      } catch (x) {}
    }, 1000);
  }
  // Floating window: only the video is shown. Everything around the video is hidden and the
  // video's parents lose their transforms, so "fixed full size" really means the whole window.
  window.__tcPip = function(on) {
    try {
      if (window.__tcPipT) { clearInterval(window.__tcPipT); window.__tcPipT = 0; }
      var e = document.getElementById('tc-pip-style');
      if (!on) {
        if (e) e.remove();
        var h = document.querySelectorAll('[data-tc-h]');
        for (var i = 0; i < h.length; i++) h[i].removeAttribute('data-tc-h');
        var f = document.querySelectorAll('[data-tc-f]');
        for (var k = 0; k < f.length; k++) { f[k].style.cssText = f[k].getAttribute('data-tc-f'); f[k].removeAttribute('data-tc-f'); }
        return;
      }
      if (!e) {
        e = document.createElement('style');
        e.id = 'tc-pip-style';
        e.textContent = 'html,body{overflow:hidden!important;background:#000!important}' +
          '[data-tc-h]{display:none!important}' +
          'video{position:fixed!important;left:0!important;top:0!important;width:100vw!important;' +
          'height:100vh!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important}';
        document.head.appendChild(e);
      }
      var apply = function() {
        var v = media();
        if (!v) return;
        for (var el = v; el && el !== document.body; el = el.parentElement) {
          if (!el.hasAttribute('data-tc-f')) el.setAttribute('data-tc-f', el.style.cssText || '');
          el.style.setProperty('transform', 'none', 'important');
          el.style.setProperty('filter', 'none', 'important');
          el.style.setProperty('contain', 'none', 'important');
          el.style.setProperty('perspective', 'none', 'important');
          var p = el.parentElement;
          if (!p) break;
          for (var s = p.firstElementChild; s; s = s.nextElementSibling) {
            if (s !== el && !/^(SCRIPT|STYLE|LINK)$/.test(s.tagName)) s.setAttribute('data-tc-h', '1');
          }
        }
      };
      apply();
      window.__tcPipT = setInterval(apply, 1000);
    } catch (x) {}
  };
  var last = '';
  setInterval(function(){
    try {
      var vs = document.getElementsByTagName('video');
      for (var i = 0; i < vs.length; i++) {
        if (yt) {
          // The phone itself stays silent: sound comes from the TV.
          if (!window.__tcPhone) { vs[i].muted = true; if (!vs[i].paused) vs[i].pause(); }
        } else {
          add(vs[i].currentSrc || vs[i].src, 'video');
          var so = vs[i].getElementsByTagName('source');
          for (var j = 0; j < so.length; j++) add(so[j].src, 'source');
        }
      }
      if (!yt) {
        var og = document.querySelector('meta[property="og:video"],meta[property="og:video:url"]');
        if (og) add(og.content, 'og');
      }
      if (location.href !== last) {
        last = location.href;
        post({t: 'nav', href: last});
      }
    } catch (x) {}
  }, 600);
})();
''';


/// YouTube with an address bar and a cast button, like a browser made for casting.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.controller, required this.onMenu, required this.onCast});

  final CastController controller;
  final VoidCallback onMenu;
  final VoidCallback onCast;

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

class BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  static const _home = 'https://m.youtube.com/';

  late final WebViewController _web;
  final TextEditingController _address = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _url = _home;
  int _progress = 0;
  bool _canBack = false;
  String? _lastCastId;
  bool _phoneOn = false;
  bool _pip = false;
  bool _webActive = false;
  int _phonePos = 0;
  String _pubKey = '';
  StreamSubscription<Map<dynamic, dynamic>>? _ev;
  final List<String> _media = [];
  String _mediaPage = '';
  // Second page that plays "on phone" videos, so the main page can keep browsing.
  WebViewController? _player;
  final GlobalKey _playerKey = GlobalKey();
  bool _playerOn = false;
  bool _big = false;
  bool _playerPlaying = false;
  bool _playerMusic = false;
  String _playerId = '';
  String _playerTitle = '';
  bool _ctl = false;
  Timer? _ctlT;
  bool _wantPlay = true;
  bool _bg = false;
  int _lastResume = 0;
  double _fr = 12;
  double _fb = 12;

  CastController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('TapCast', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) => _setUrl(url),
        onPageFinished: (url) {
          _setUrl(url);
          _web.runJavaScript(_script);
        },
        onUrlChange: (change) {
          if (change.url != null) _setUrl(change.url!);
        },
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ))
      ..loadRequest(Uri.parse(_home));
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      // Sound may start without a tap on the page (used for "Play on phone").
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_syncPhone);
    _ev = c.native.events.listen(_onNativeEvent);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _bg = state != AppLifecycleState.resumed;
  }

  void _showCtl() {
    _ctlT?.cancel();
    setState(() => _ctl = true);
    _ctlT = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _ctl = false);
    });
  }

  bool get _music => _url.contains('music.youtube.com');

  void _onNativeEvent(Map<dynamic, dynamic> e) {
    switch (e['type']) {
      case 'phoneCtl':
        if (!c.phoneMode && !_webActive) return;
        final action = e['action'] as String? ?? '';
        final value = (e['value'] as num?)?.toInt() ?? 0;
        if (action == 'stop') {
          c.setPhoneMode(false);
          _stopPlayer();
          if (_webActive) {
            _webActive = false;
            _web.runJavaScript("window.__tcCmd&&window.__tcCmd('pause',0);");
            c.native.phoneEnd().catchError((Object _) {});
          }
        } else {
          if (action == 'pause') _wantPlay = false;
          if (action == 'resume') _wantPlay = true;
          final t = _webActive ? _web : (_playerOn ? (_player ?? _web) : _web);
          t.runJavaScript("window.__tcCmd&&window.__tcCmd('$action',$value);");
        }
      case 'pip':
        final on = e['on'] == true;
        if (on == _pip) return;
        setState(() => _pip = on);
        final pl = _player;
        if (_playerOn && pl != null) {
          pl.runJavaScript('window.__tcPip&&window.__tcPip(${on || !_big});');
          if (on && _playerPlaying) {
            // The page may pause itself when the app goes to the background: keep it playing.
            for (final ms in const [600, 1500, 3000]) {
              Future<void>.delayed(Duration(milliseconds: ms), () {
                if (mounted && _playerOn && _pip && _playerPlaying) _playerCmd('resume');
              });
            }
          }
        } else {
          _web.runJavaScript('window.__tcPip&&window.__tcPip($on);');
        }
    }
  }

  /// Starts or ends "playing on the phone" in the page; the notification follows it.
  void _syncPhone() {
    final on = c.phoneMode;
    if (on == _phoneOn) return;
    _phoneOn = on;
    if (on) {
      c.native.setPhoneVideo(ready: !_playerMusic, playing: true, keep: true).catchError((Object _) {});
    } else {
      _stopPlayer();
      _pubKey = '';
      c.native.setPhoneVideo(ready: false, playing: false, keep: false).catchError((Object _) {});
      c.native.phoneEnd().catchError((Object _) {});
    }
  }

  WebViewController _ensurePlayer() {
    final old = _player;
    if (old != null) return old;
    final p = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('TapCastPlayer', onMessageReceived: _onPlayerMessage)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (url) => _initPlayer(url)));
    final platform = p.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _player = p;
    return p;
  }

  Future<void> _initPlayer(String url) async {
    final p = _player;
    if (p == null || !_playerOn || url.startsWith('about:')) return;
    await p.runJavaScript('window.TapCast = window.TapCastPlayer;');
    await p.runJavaScript(_script);
    await p.runJavaScript(
        "try{var st=document.createElement('style');st.textContent='ytm-mobile-topbar-renderer,header.mobile-topbar-header-content,ytm-app-promo-renderer{display:none!important}';document.head.appendChild(st);}catch(e){}");
    await p.runJavaScript('window.__tcPip&&window.__tcPip(${_pip || !_big});');
    for (final ms in const [0, 1500, 3500]) {
      if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
      if (!mounted || !_playerOn) return;
      await p.runJavaScript('window.__tcSetPhone&&window.__tcSetPhone(true);');
    }
  }

  void _onPlayerMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      if (j['t'] != 'pstate' || !_playerOn) return;
      final playing = j['playing'] == true;
      final title = (j['title'] as String?) ?? '';
      final href = (j['href'] as String?) ?? '';
      final id = UrlUtils.videoId(href) ?? '';
      final music = href.contains('music.youtube.com');
      if (playing != _playerPlaying || title != _playerTitle || id != _playerId || music != _playerMusic) {
        setState(() {
          _playerPlaying = playing;
          _playerTitle = title;
          if (id.isNotEmpty) _playerId = id;
          _playerMusic = music;
        });
      }
      final key = '$id|$playing|$title|p';
      if (key != _pubKey) {
        _pubKey = key;
        c.native
            .phoneState(status: playing ? 'playing' : 'paused', id: id, title: title, index: 0, count: 1)
            .catchError((Object _) {});
        c.native.setPhoneVideo(ready: !music, playing: playing, keep: true).catchError((Object _) {});
      }
      _phonePos = (j['pos'] as num?)?.toInt() ?? 0;
      final dur = (j['dur'] as num?)?.toInt() ?? 0;
      c.native.phonePos(_phonePos, dur).catchError((Object _) {});
      // The page pauses itself when the window shrinks or the app is left: keep it playing
      // (unless the person paused it or the video has ended).
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!playing && _wantPlay && (_pip || _bg) && (dur == 0 || _phonePos < dur - 2) && now - _lastResume > 1200) {
        _lastResume = now;
        _player?.runJavaScript("window.__tcCmd&&window.__tcCmd('resume',0);");
      }
    } catch (_) {/* ignore */}
  }

  void _stopPlayer() {
    if (!_playerOn && _player == null) return;
    _playerOn = false;
    _big = false;
    _playerPlaying = false;
    _playerId = '';
    _playerTitle = '';
    _wantPlay = true;
    _player?.loadRequest(Uri.parse('about:blank'));
    if (mounted) setState(() {});
  }

  void _setBig(bool b) {
    setState(() => _big = b);
    if (b) _showCtl();
    _player?.runJavaScript('window.__tcPip&&window.__tcPip(${_pip || !b});');
  }

  void _playerCmd(String a) {
    if (a == 'pause') _wantPlay = false;
    if (a == 'resume') _wantPlay = true;
    _player?.runJavaScript("window.__tcCmd&&window.__tcCmd('$a',0);");
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctlT?.cancel();
    c.removeListener(_syncPhone);
    _ev?.cancel();
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setUrl(String url) {
    if (!mounted) return;
    _web.canGoBack().then((v) {
      if (mounted && v != _canBack) setState(() => _canBack = v);
    });
    if (url == _url && _address.text.isNotEmpty) return;
    _url = url;
    if (!_focus.hasFocus) _address.text = _pretty(url);
    setState(() {});
  }

  String _pretty(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final q = uri.queryParameters['search_query'] ??
        (uri.host.contains('google.') && uri.path == '/search' ? uri.queryParameters['q'] : null);
    if (q != null) return q;
    return '${uri.host}${uri.path == '/' ? '' : uri.path}';
  }

  /// Opens [url] in the page (from a bookmark).
  void open(String url) {
    _web.loadRequest(Uri.parse(url));
  }

  /// Back inside the page; false when there is nothing to go back to.
  Future<bool> goBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
      return true;
    }
    return false;
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      if (j['t'] == 'nav') {
        final href = (j['href'] as String?) ?? '';
        _setUrl(href);
        if (href != _mediaPage) {
          _mediaPage = href;
          if (_media.isNotEmpty) setState(_media.clear);
        }
        final id = UrlUtils.videoId(href);
        // A video page opened (tapped in the list or in "up next"): play it on the TV.
        if (id != null && id != _lastCastId) {
          _lastCastId = id;
          // In phone mode the page plays it itself; otherwise it goes to the TV.
          if (c.phoneMode) {
            _playOnPhone(id);
          } else {
            _play(id, '', href);
          }
        }
      } else if (j['t'] == 'pstate') {
        final web = j['web'] == true;
        if (!c.phoneMode && !web) return;
        if (web && c.cast.active) return;
        if (web) _webActive = true;
        final playing = j['playing'] == true;
        final title = (j['title'] as String?) ?? '';
        final href = (j['href'] as String?) ?? '';
        final id = UrlUtils.videoId(href) ?? '';
        final key = '$id|$playing|$title|$web';
        if (key != _pubKey) {
          _pubKey = key;
          c.native
              .phoneState(
                status: playing ? 'playing' : 'paused',
                id: id,
                title: title,
                index: 0,
                count: 1,
                uri: web ? href : null,
              )
              .catchError((Object _) {});
          c.native.setPhoneVideo(ready: !web && !_music, playing: playing, keep: true).catchError((Object _) {});
        }
        _phonePos = (j['pos'] as num?)?.toInt() ?? 0;
        c.native
            .phonePos(_phonePos, (j['dur'] as num?)?.toInt() ?? 0)
            .catchError((Object _) {});
      } else if (j['t'] == 'media') {
        final u = (j['url'] as String?) ?? '';
        if (u.isNotEmpty && !_media.contains(u) && _media.length < 12) setState(() => _media.add(u));
      }
    } catch (_) {/* ignore */}
  }

  String? _listFrom(String href) {
    final list = RegExp(r'[?&]list=([A-Za-z0-9_-]+)').firstMatch(href)?.group(1);
    if (list == null || list.startsWith('RD')) return null;
    return 'https://www.youtube.com/playlist?list=$list';
  }

  /// The cast button switches between the TV and the phone, keeping the place in the video:
  /// playing on the TV -> plays here; playing here -> goes to the TV. When nothing plays it sends the
  /// open video to the saved TV (or opens the TV list when there is nothing to cast).
  Future<void> _castTap() async {
    final pageId = UrlUtils.videoId(_url);
    if (c.cast.active) {
      final castId = c.cast.uri == null ? null : UrlUtils.videoId(c.cast.uri!);
      if (castId == null) {
        _snack('Only YouTube videos can switch to the phone');
        return;
      }
      await _toPhone(castId, c.progress.position);
    } else if (c.phoneMode && (pageId != null || _playerId.isNotEmpty)) {
      final id = _playerId.isNotEmpty ? _playerId : pageId!;
      _lastCastId = id;
      final pos = _phonePos;
      await _play(id, '', 'https://m.youtube.com/watch?v=$id');
      if (c.cast.active || c.phoneMode == false) unawaited(_seekWhenPlaying(pos));
    } else if (pageId != null) {
      _lastCastId = pageId;
      await _play(pageId, '', _url);
    } else if (c.device != null && !UrlUtils.isYoutube(_url) && _media.isNotEmpty) {
      await _castPage();
    } else {
      widget.onCast();
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  /// Moves the TV's video to the phone, from the same second.
  Future<void> _toPhone(String id, int pos) async {
    _lastCastId = id;
    await c.control('stop');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    await _playOnPhone(id, start: pos);
    _snack('Playing on this phone');
  }

  /// After a hand-over to the TV, jumps to where the phone was once the TV is playing.
  Future<void> _seekWhenPlaying(int pos) async {
    if (pos <= 5) return;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      if (c.cast.status == 'playing') {
        await c.control('seek', value: pos);
        return;
      }
    }
  }

  /// Casts [id] to the TV (asks which TV the first time).
  Future<void> castId(String id, {String title = '', String href = ''}) => _play(id, title, href);

  Future<void> _play(String id, String title, String href) async {
    if (c.device == null) {
      _snack('Looking for your TV…');
      await c.search();
      if (!mounted) return;
      if (c.found.length == 1) {
        c.chooseDevice(c.found.first);
      } else if (c.found.isEmpty) {
        await offerPhone(context, c, () => _playOnPhone(id), none: true, onChoose: () => showDevicesSheet(context, c));
        return;
      } else if (!await showDevicesSheet(context, c)) {
        return;
      }
    }
    final ok = await c.castVideo(id, title: title, listUrl: _listFrom(href), shorts: href.contains('/shorts/'));
    if (!mounted) return;
    if (!ok && c.takeUnreachable()) {
      await offerPhone(context, c, () => _playOnPhone(id));
      return;
    }
    final msg = ok ? 'Casting to ${c.device?.name ?? 'TV'}…' : (c.takeMessage() ?? 'Could not cast');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// The TV did not answer: the page plays here, like a normal browser (sound, notification
  /// buttons, keeps playing in the background, floating window when you leave the app).
  Future<void> _playOnPhone(String id, {int start = 0}) async {
    _lastCastId = id;
    if (c.cast.active) await c.control('stop');
    final p = _ensurePlayer();
    final host = _url.contains('music.youtube.com') ? 'music.youtube.com' : 'm.youtube.com';
    final t = start > 3 ? '&t=${start}s' : '';
    setState(() {
      _playerOn = true;
      _big = false;
      _playerId = id;
      _playerMusic = host.startsWith('music');
    });
    c.setPhoneMode(true);
    _syncPhone();
    await p.loadRequest(Uri.parse('https://$host/watch?v=$id$t'));
  }

  /// Any other website: casts the video found on the page (or the page itself).
  Future<void> _castPage() async {
    if (!await ensureDevice(context, c)) return;
    final title = (await _web.getTitle()) ?? '';
    final link = _media.isNotEmpty
        ? (_media.firstWhere((u) => u.toLowerCase().contains('.mp4'), orElse: () => _media.first))
        : _url;
    final ok = await c.castFiles([
      CastItem(uri: link, title: title.isEmpty ? 'Web video' : title, mime: 'video/mp4', stream: true),
    ]);
    if (!mounted) return;
    if (ok) {
      await _web.runJavaScript("try{var vs=document.getElementsByTagName('video');for(var i=0;i<vs.length;i++)vs[i].pause();}catch(e){}");
    } else if (c.takeUnreachable()) {
      await offerPhone(context, c, () => _web.runJavaScript("try{var v=document.getElementsByTagName('video')[0];if(v)v.play();}catch(e){}"));
      return;
    }
    if (!mounted) return;
    final msg = ok ? 'Casting to ${c.device?.name ?? 'TV'}…' : (c.takeMessage() ?? 'Could not cast this page');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _submit(String text) {
    final t = text.trim();
    _focus.unfocus();
    if (t.isEmpty) return;
    final id = UrlUtils.videoId(t);
    if (id != null) {
      _lastCastId = id;
      _play(id, '', t);
      return;
    }
    final looksLikeUrl = !t.contains(' ') && t.contains('.');
    final target = looksLikeUrl
        ? (t.startsWith('http') ? t : 'https://$t')
        : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
    _web.loadRequest(Uri.parse(target));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final casting = c.cast.active;
    final pageId = UrlUtils.videoId(_url);
    return Stack(children: [
      Column(
      children: [
        Visibility(
          visible: !_pip,
          maintainState: true,
          child: Material(
          color: scheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
                Expanded(
                  child: TextField(
                    controller: _address,
                    focusNode: _focus,
                    textInputAction: TextInputAction.go,
                    keyboardType: TextInputType.url,
                    onSubmitted: _submit,
                    onTap: () => _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search Google or type a URL',
                      suffixIcon: IconButton(
                        tooltip: 'Reload',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _web.reload(),
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                      ),
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                if (_media.isNotEmpty && pageId == null)
                  IconButton(
                    tooltip: 'Cast this video',
                    onPressed: _castPage,
                    icon: Icon(Icons.play_circle_fill_rounded, color: scheme.primary),
                  ),
                GestureDetector(
                  onLongPress: widget.onCast,
                  child: IconButton(
                    tooltip: casting
                        ? 'On TV. Tap: play on phone. Hold: change TV'
                        : c.phoneMode
                            ? 'On phone. Tap: play on TV. Hold: change TV'
                            : (c.device == null ? 'Choose a TV' : 'Tap: cast to ${c.device!.name}. Hold: change TV'),
                    onPressed: _castTap,
                    icon: Icon(
                      casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                      color: casting
                          ? scheme.primary
                          : c.phoneMode
                              ? scheme.tertiary
                              : (c.device != null ? scheme.primary : null),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'reload':
                        await _web.reload();
                      case 'home':
                        await _web.loadRequest(Uri.parse(_home));
                      case 'back':
                        await goBack();
                      case 'copy':
                        await Clipboard.setData(ClipboardData(text: _url));
                      case 'stopphone':
                        c.setPhoneMode(false);
                      case 'bookmark':
                        final title = (await _web.getTitle()) ?? '';
                        c.toggleBookmark(_url, title);
                      case 'cast':
                        if (pageId != null) {
                          await _play(pageId, '', _url);
                        } else {
                          await _castPage();
                        }
                    }
                  },
                  itemBuilder: (_) => [
                    if (pageId != null || !UrlUtils.isYoutube(_url))
                      PopupMenuItem(value: 'cast', child: Text(pageId != null ? 'Cast this video' : 'Cast this page')),
                    if (_canBack) const PopupMenuItem(value: 'back', child: Text('Back')),
                    if (c.phoneMode) const PopupMenuItem(value: 'stopphone', child: Text('Stop playing on phone')),
                    PopupMenuItem(
                      value: 'bookmark',
                      child: Text(c.isBookmarked(_url) ? 'Remove bookmark' : 'Add bookmark'),
                    ),
                    const PopupMenuItem(value: 'reload', child: Text('Reload')),
                    const PopupMenuItem(value: 'home', child: Text('YouTube home')),
                    const PopupMenuItem(value: 'copy', child: Text('Copy link')),
                  ],
                ),
              ],
            ),
          ),
        ),
        ),
        if (_progress < 100 && !_pip) LinearProgressIndicator(value: _progress / 100, minHeight: 2),
        Expanded(child: WebViewWidget(controller: _web)),
      ],
      ),
      if (_playerOn && _player != null) _playerLayer(scheme),
    ]);
  }

  Widget _playerLayer(ColorScheme scheme) {
    if (!_pip) {
      // No floating window inside the app: the page keeps playing out of sight
      // (sound + notification); the system floating window shows it when you leave the app.
      return Positioned(
        right: 0,
        bottom: 0,
        width: 80,
        height: 45,
        child: IgnorePointer(
          child: Opacity(opacity: 0.01, child: WebViewWidget(key: _playerKey, controller: _player!)),
        ),
      );
    }
    final full = _pip || _big;
    const w = 220.0;
    const h = 124.0;
    final size = MediaQuery.of(context).size;
    final video = WebViewWidget(key: _playerKey, controller: _player!);
    Widget btn(IconData i, VoidCallback f) => Expanded(
          child: InkWell(onTap: f, child: Center(child: Icon(i, color: Colors.white, size: 20))),
        );
    final children = <Widget>[Positioned.fill(child: video)];
    if (!_pip && !_big) {
      children.addAll([
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 28,
          child: GestureDetector(
            onPanUpdate: (d) => setState(() {
              _fr = (_fr - d.delta.dx).clamp(0.0, size.width - w);
              _fb = (_fb - d.delta.dy).clamp(0.0, size.height - h - 100);
            }),
            child: Container(
              color: Colors.black54,
              alignment: Alignment.centerRight,
              child: InkWell(
                onTap: () => c.setPhoneMode(false),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.close_rounded, color: Colors.white, size: 18),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 34,
          child: Container(
            color: Colors.black54,
            child: Row(children: [
              btn(Icons.skip_previous_rounded, () => _playerCmd('previous')),
              btn(_playerPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  () => _playerCmd(_playerPlaying ? 'pause' : 'resume')),
              btn(Icons.skip_next_rounded, () => _playerCmd('next')),
              btn(Icons.open_in_full_rounded, () => _setBig(true)),
            ]),
          ),
        ),
      ]);
    } else if (_big && !_pip) {
      Widget cbtn(IconData i, VoidCallback f, {double size = 30}) => IconButton(
            onPressed: () {
              f();
              _showCtl();
            },
            iconSize: size,
            color: Colors.white,
            icon: Icon(i),
          );
      children.add(Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: size.width * 9 / 16,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _ctl ? setState(() => _ctl = false) : _showCtl(),
          child: IgnorePointer(
            ignoring: !_ctl,
            child: AnimatedOpacity(
              opacity: _ctl ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                color: Colors.black38,
                child: Stack(children: [
                  Positioned(left: 4, top: 4, child: cbtn(Icons.keyboard_arrow_down_rounded, () => _setBig(false), size: 34)),
                  Positioned(right: 4, top: 4, child: cbtn(Icons.close_rounded, () => c.setPhoneMode(false))),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      cbtn(Icons.skip_previous_rounded, () => _playerCmd('previous'), size: 40),
                      const SizedBox(width: 12),
                      cbtn(_playerPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                          () => _playerCmd(_playerPlaying ? 'pause' : 'resume'), size: 60),
                      const SizedBox(width: 12),
                      cbtn(Icons.skip_next_rounded, () => _playerCmd('next'), size: 40),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ));
    }
    return Positioned(
      left: full ? 0 : null,
      top: full ? 0 : null,
      right: full ? 0 : _fr,
      bottom: full ? 0 : _fb,
      width: full ? null : w,
      height: full ? null : h,
      child: Material(
        color: Colors.black,
        elevation: full ? 0 : 8,
        borderRadius: full ? null : BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: children),
      ),
    );
  }
}

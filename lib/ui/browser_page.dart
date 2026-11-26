import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/cast.dart';
import '../state/cast_controller.dart';
import '../utils/url_utils.dart';
import 'devices_sheet.dart';
import 'phone_player_page.dart';

/// Runs inside the YouTube page: tells the app when a video page opens (so it plays on the TV),
/// keeps the phone's own player silent and paused, and hides YouTube's bottom bar and banners.
const _script = r'''
(function(){
  if (window.__tcInit) return;
  window.__tcInit = true;
  function post(o) { try { TapCast.postMessage(JSON.stringify(o)); } catch (e) {} }
  var yt = /(^|\.)youtube\.com$/.test(location.hostname);
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

class BrowserPageState extends State<BrowserPage> {
  static const _home = 'https://m.youtube.com/';

  late final WebViewController _web;
  final TextEditingController _address = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _url = _home;
  int _progress = 0;
  bool _canBack = false;
  String? _lastCastId;
  final List<String> _media = [];
  String _mediaPage = '';

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
  }

  @override
  void dispose() {
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
          if (c.phone.active) {
            _playOnPhone(id);
          } else {
            _play(id, '', href);
          }
        }
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

  /// Casts [id] to the TV (asks which TV the first time).
  Future<void> castId(String id, {String title = '', String href = ''}) => _play(id, title, href);

  Future<void> _play(String id, String title, String href) async {
    if (!await ensureDevice(context, c)) {
      // No TV chosen or found: still let the person watch on the phone.
      if (mounted && c.device == null && c.found.isEmpty && !c.searching) {
        await offerPhone(context, c, () => _playOnPhone(id));
      }
      return;
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

  /// The TV did not answer: play here with TapCast's own player (background, floating window).
  Future<void> _playOnPhone(String id) async {
    _lastCastId = id;
    if (c.cast.active) await c.control('stop');
    await c.phone.start(
      id,
      audio: _url.contains('music.youtube.com'),
      isShorts: _url.contains('/shorts/'),
    );
    if (!mounted) return;
    await openPhonePlayer(context, c);
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
    return Column(
      children: [
        Material(
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
                IconButton(
                  tooltip: c.device == null ? 'Choose a TV' : 'Cast to ${c.device!.name}',
                  onPressed: widget.onCast,
                  icon: Icon(
                    casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                    color: casting || c.device != null ? scheme.primary : null,
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
        if (_progress < 100) LinearProgressIndicator(value: _progress / 100, minHeight: 2),
        Expanded(child: WebViewWidget(controller: _web)),
      ],
    );
  }
}

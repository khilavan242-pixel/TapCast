import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/cast_controller.dart';
import '../utils/url_utils.dart';
import 'devices_sheet.dart';

/// Runs inside the YouTube page: tapping a video does not open it, it is cast to the TV instead.
const _script = r'''
(function(){
  if (window.__tcInit) return;
  window.__tcInit = true;
  function post(o) { try { TapCast.postMessage(JSON.stringify(o)); } catch (e) {} }
  document.addEventListener('click', function(e){
    try {
      var a = e.target && e.target.closest ? e.target.closest('a[href*="/watch?v="],a[href*="/shorts/"]') : null;
      if (!a) return;
      var href = a.getAttribute('href') || '';
      var m = /[?&]v=([A-Za-z0-9_-]{11})/.exec(href) || /\/shorts\/([A-Za-z0-9_-]{11})/.exec(href);
      if (!m) return;
      e.preventDefault();
      e.stopPropagation();
      var ttl = (a.getAttribute('aria-label') || a.textContent || '').replace(/\s+/g, ' ').trim();
      post({t: 'play', id: m[1], title: ttl.slice(0, 160), href: href});
    } catch (x) {}
  }, true);
  // The phone itself stays silent: sound comes from the TV.
  setInterval(function(){
    try {
      var vs = document.getElementsByTagName('video');
      for (var i = 0; i < vs.length; i++) { vs[i].muted = true; if (!vs[i].paused) vs[i].pause(); }
    } catch (x) {}
  }, 900);
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

  CastController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('TapCast', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigate,
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
    final q = uri.queryParameters['search_query'];
    if (q != null) return q;
    return '${uri.host}${uri.path == '/' ? '' : uri.path}';
  }

  /// Back inside the page; false when there is nothing to go back to.
  Future<bool> goBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
      return true;
    }
    return false;
  }

  NavigationDecision _onNavigate(NavigationRequest r) {
    final id = UrlUtils.videoId(r.url);
    if (id != null && r.isMainFrame) {
      _play(id, '', r.url);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      if (j['t'] == 'play') {
        final id = j['id'] as String?;
        if (id != null) _play(id, (j['title'] as String?) ?? '', (j['href'] as String?) ?? '');
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
    if (!await ensureDevice(context, c)) return;
    final ok = await c.castVideo(id, title: title, listUrl: _listFrom(href));
    if (!mounted) return;
    final msg = ok ? 'Casting to ${c.device?.name ?? 'TV'}…' : (c.takeMessage() ?? 'Could not cast');
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
      _play(id, '', t);
      return;
    }
    final looksLikeUrl = !t.contains(' ') && t.contains('.');
    final target = looksLikeUrl
        ? (t.startsWith('http') ? t : 'https://$t')
        : 'https://m.youtube.com/results?search_query=${Uri.encodeQueryComponent(t)}';
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
                      hintText: 'Search YouTube or paste a link',
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
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
                      case 'cast':
                        if (pageId != null) await _play(pageId, '', _url);
                    }
                  },
                  itemBuilder: (_) => [
                    if (pageId != null) const PopupMenuItem(value: 'cast', child: Text('Cast this video')),
                    if (_canBack) const PopupMenuItem(value: 'back', child: Text('Back')),
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

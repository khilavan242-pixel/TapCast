/// Helpers for pulling downloadable links out of arbitrary text (clipboard,
/// shared text, pasted lists).
class UrlUtils {
  UrlUtils._();

  static final RegExp _urlPattern = RegExp(
    r"https?://[^\s<>\x22']+",
    caseSensitive: false,
  );

  static const Set<String> _youtubeHosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };

  /// Returns every unique http(s) URL found in [text], in order of appearance.
  static List<String> extractUrls(String text) {
    final seen = <String>{};
    final result = <String>[];
    for (final m in _urlPattern.allMatches(text)) {
      var url = m.group(0)!;
      // Strip trailing punctuation that is almost never part of the URL.
      url = url.replaceAll(RegExp(r'[)\]}>.,;!?]+$'), '');
      if (Uri.tryParse(url)?.hasAuthority != true) continue;
      if (seen.add(url)) result.add(url);
    }
    return result;
  }

  static bool isYoutube(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    return host != null && _youtubeHosts.contains(host);
  }

  /// True when the link points at a playlist (or a video inside one).
  static bool hasPlaylist(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.queryParameters.containsKey('list') || uri.path.contains('/playlist');
  }

  /// True for a playlist page itself (no single video chosen).
  static bool isPlaylistPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !hasPlaylist(url)) return false;
    return uri.path.contains('/playlist') || videoId(url) == null;
  }

  /// The 11-character YouTube video id, or null (playlist pages, other sites).
  static String? videoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !isYoutube(url)) return null;
    final host = uri.host.toLowerCase();
    String? id;
    if (host.endsWith('youtu.be')) {
      id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    } else if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (uri.pathSegments.length >= 2 &&
        const {'shorts', 'embed', 'live', 'v'}.contains(uri.pathSegments.first)) {
      id = uri.pathSegments[1];
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return null;
    return id;
  }

  /// True when a page address is something TapCast can download (video or playlist).
  static bool isDownloadablePage(String url) =>
      isYoutube(url) && (videoId(url) != null || hasPlaylist(url));

  static String formatEta(int seconds) {
    if (seconds < 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }
}

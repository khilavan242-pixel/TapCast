import 'package:flutter_test/flutter_test.dart';
import 'package:tapcast/utils/url_utils.dart';

void main() {
  test('finds video ids in common YouTube links', () {
    expect(UrlUtils.videoId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(UrlUtils.videoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(UrlUtils.videoId('https://m.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(UrlUtils.videoId('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
  });

  test('extracts links from shared text', () {
    final urls = UrlUtils.extractUrls('look https://youtu.be/dQw4w9WgXcQ, nice');
    expect(urls, ['https://youtu.be/dQw4w9WgXcQ']);
  });
}

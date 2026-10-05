import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../models/extracted_stream.dart';
import '../../models/media_item.dart';
import '../../models/stream_server.dart';

class StreamExtractor {
  StreamExtractor._();

  static final StreamExtractor instance = StreamExtractor._();

  /// Regex pattern to detect direct video streams (.m3u8 HLS playlists or MP4 files)
  static final RegExp _mediaRegex = RegExp(
    r'(https?:\/\/[^\s"<>]+?\.(m3u8|mp4)[^\s"<>]*)',
    caseSensitive: false,
  );

  /// Attempts to extract a direct video stream from a given [StreamServer].
  /// If the server fails or times out, it can automatically try fallback servers.
  Future<ExtractedStream?> extractStream({
    required int tmdbId,
    required MediaType type,
    StreamServer? server,
    int season = 1,
    int episode = 1,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final primaryServer = server ?? StreamServers.all.first;

    // Try primary server first
    final stream = await _extractFromServer(
      primaryServer,
      tmdbId,
      type,
      season,
      episode,
      timeout,
    );

    if (stream != null) return stream;

    // Try fallback servers if primary didn't yield a stream
    final fallbacks = StreamServers.all.where((s) => s.id != primaryServer.id).take(3);
    for (final fallback in fallbacks) {
      final fallbackStream = await _extractFromServer(
        fallback,
        tmdbId,
        type,
        season,
        episode,
        const Duration(seconds: 6),
      );
      if (fallbackStream != null) return fallbackStream;
    }

    return null;
  }

  Future<ExtractedStream?> _extractFromServer(
    StreamServer server,
    int tmdbId,
    MediaType type,
    int season,
    int episode,
    Duration timeout,
  ) async {
    final embedUrl = server.buildUrl(tmdbId, type, season: season, episode: episode);
    final completer = Completer<ExtractedStream?>();
    HeadlessInAppWebView? headless;

    void finish(ExtractedStream? result) {
      if (!completer.isCompleted) {
        completer.complete(result);
        try {
          headless?.dispose();
        } catch (_) {}
      }
    }

    // Set extraction timeout
    final timer = Timer(timeout, () {
      finish(null);
    });

    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(embedUrl),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          },
        ),
        initialSettings: InAppWebViewSettings(
          allowsInlineMediaPlayback: true,
          mediaPlaybackRequiresUserGesture: false,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          useHybridComposition: true,
          isInspectable: false,
          // Block ads and anti-devtool scripts
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: r'.*(disable-devtool|devtool|devtools).*',
              ),
              action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: r'.*(popads|onclick|doubleclick|googlesyndication|adsterra|bet365|adroll|histats|amung|trafficjunky|propellerads).*',
              ),
              action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
          ],
        ),
        shouldInterceptRequest: (controller, request) async {
          final url = request.url.toString().toLowerCase();
          // Drop anti-devtool scripts before they can load or freeze the thread
          if (url.contains('disable-devtool') ||
              url.contains('devtool') ||
              url.contains('popads') ||
              url.contains('adsterra') ||
              url.contains('doubleclick') ||
              url.contains('propellerads')) {
            return WebResourceResponse(
              contentType: 'application/javascript',
              data: Uint8List(0),
            );
          }
          return null;
        },
        onConsoleMessage: (controller, consoleMessage) {
          // Suppress devtool detector noise and flood logs
        },
        onWebViewCreated: (controller) {
          // JS bridge to catch direct video source assignment or HLS player loadSource
          controller.addJavaScriptHandler(
            handlerName: 'onMediaUrlFound',
            callback: (args) {
              if (args.isNotEmpty && args[0] is String) {
                final mediaUrl = args[0] as String;
                if (_isMediaStream(mediaUrl)) {
                  timer.cancel();
                  finish(
                    ExtractedStream(
                      url: mediaUrl,
                      headers: {
                        'Referer': embedUrl,
                        'User-Agent':
                            'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
                      },
                      server: server,
                    ),
                  );
                }
              }
            },
          );
        },
        onLoadStart: (controller, url) {
          // Inject anti-devtool neutralization and stream capture hooks
          controller.evaluateJavascript(source: """
            (function() {
              // Neutralize DisableDevtool library
              try {
                window.DisableDevtool = {
                  isSuspend: true,
                  isRunning: false,
                  stop: function() {},
                  start: function() {}
                };
                Object.defineProperty(window, 'DisableDevtool', {
                  value: { isSuspend: true, isRunning: false, stop: function(){}, start: function(){} },
                  writable: false,
                  configurable: false
                });
              } catch(e) {}

              // Suppress console flood
              try {
                var noop = function() {};
                console.log = function() {
                  if (arguments.length > 5) return;
                };
                console.clear = noop;
                console.table = noop;
              } catch(e) {}

              function notify(url) {
                if (url && (url.includes('.m3u8') || url.includes('.mp4') || url.includes('/hls/') || url.includes('/stream/'))) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('onMediaUrlFound', url);
                  }
                }
              }

              // Hook HTML5 Video src
              var originalSrc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
              if (originalSrc) {
                Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                  set: function(val) {
                    notify(val);
                    return originalSrc.set.call(this, val);
                  },
                  get: originalSrc.get
                });
              }

              // Hook XHR & Fetch for m3u8 playlists
              var originalOpen = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(method, url) {
                notify(url);
                return originalOpen.apply(this, arguments);
              };

              var originalFetch = window.fetch;
              window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input ? input.url : '');
                notify(url);
                return originalFetch.apply(this, arguments);
              };
            })();
          """);
        },
        onLoadResource: (controller, resource) {
          final resUrl = resource.url?.toString() ?? '';
          if (_isMediaStream(resUrl)) {
            timer.cancel();
            finish(
              ExtractedStream(
                url: resUrl,
                headers: {
                  'Referer': embedUrl,
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
                },
                server: server,
              ),
            );
          }
        },
      );

      await headless.run();
    } catch (_) {
      timer.cancel();
      finish(null);
    }

    return completer.future;
  }

  static bool _isMediaStream(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.contains('google') ||
        lower.contains('doubleclick') ||
        lower.contains('tracker') ||
        lower.contains('analytics')) {
      return false;
    }
    return lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('/hls/') ||
        lower.contains('/playlist/') ||
        lower.contains('master.m3u8') ||
        _mediaRegex.hasMatch(url);
  }
}

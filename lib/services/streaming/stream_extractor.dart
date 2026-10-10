import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../models/extracted_stream.dart';
import '../../models/media_item.dart';
import '../../models/stream_server.dart';
import 'fourkhdhub/fourkhdhub_service.dart';
import 'moviebox/moviebox_service.dart';

class StreamExtractor {
  StreamExtractor._();

  static final StreamExtractor instance = StreamExtractor._();

  /// Regex pattern to detect direct video streams (.m3u8 HLS playlists or MP4 files)
  static final RegExp _mediaRegex = RegExp(
    r'(https?:\/\/[^\s"<>]+?\.(m3u8|mp4)[^\s"<>]*)',
    caseSensitive: false,
  );

  final Set<void Function()> _activeCancels = {};
  final Set<HeadlessInAppWebView> _live = {};
  int _epoch = 0;

  /// Force-disposes every hidden WebView that is still alive, regardless of
  /// extraction state, so nothing can keep playing in the background.
  Future<void> disposeAllWebViews() async {
    final views = _live.toList();
    _live.clear();
    for (final v in views) {
      try {
        await v.dispose().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    debugPrint('[Extractor] disposed ${views.length} leftover webview(s)');
  }

  /// Cancels any in-flight extraction and tears down hidden WebViews so they
  /// can never keep playing media in the background.
  void cancelAll() {
    _epoch++;
    for (final cancel in _activeCancels.toList()) {
      cancel();
    }
    _activeCancels.clear();
  }

  /// Extracts a stream from a single specific server.
  Future<ExtractedStream?> extractSingleServer({
    required StreamServer server,
    required int tmdbId,
    required MediaType type,
    String? title,
    int? year,
    int season = 1,
    int episode = 1,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    return _extractFromServer(
      server,
      tmdbId,
      type,
      title,
      year,
      season,
      episode,
      timeout,
    );
  }

  /// Attempts to extract a direct video stream from a given [StreamServer].
  /// If the server fails or times out, it can automatically try fallback servers.
  Future<ExtractedStream?> extractStream({
    required int tmdbId,
    required MediaType type,
    StreamServer? server,
    String? title,
    int? year,
    int season = 1,
    int episode = 1,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final myEpoch = _epoch;
    final primaryServer = server ?? StreamServers.all.first;

    // Try primary server first
    final stream = await _extractFromServer(
      primaryServer,
      tmdbId,
      type,
      title,
      year,
      season,
      episode,
      timeout,
    );

    if (stream != null) return stream;

    // Try fallback servers if primary didn't yield a stream
    final fallbacks = StreamServers.all.where((s) => s.id != primaryServer.id);
    for (final fallback in fallbacks) {
      if (myEpoch != _epoch) return null;
      final fallbackStream = await _extractFromServer(
        fallback,
        tmdbId,
        type,
        title,
        year,
        season,
        episode,
        const Duration(seconds: 15),
      );
      if (fallbackStream != null) return fallbackStream;
    }

    return null;
  }

  Future<ExtractedStream?> _extractFromServer(
    StreamServer server,
    int tmdbId,
    MediaType type,
    String? title,
    int? year,
    int season,
    int episode,
    Duration timeout,
  ) async {
    // 1. MovieBox Native API
    if (server.id == 'moviebox') {
      if (title == null || title.isEmpty) {
        debugPrint('[Extractor] MovieBox requires title');
        return null;
      }
      try {
        debugPrint('[Extractor] Calling MovieBoxService for "$title"');
        final mbStream = await MovieBoxService.instance
            .getStream(
              title: title,
              year: year,
              type: type,
              season: season,
              episode: episode,
              server: server,
            )
            .timeout(timeout, onTimeout: () => null);
        if (mbStream != null) return mbStream;
      } catch (e) {
        debugPrint('[Extractor] MovieBox error: $e');
      }
      return null;
    }

    // 2. 4KHDHub + HubCloud Native Resolver
    if (server.id == '4khdhub') {
      if (title == null || title.isEmpty) {
        debugPrint('[Extractor] 4KHDHub requires title');
        return null;
      }
      try {
        debugPrint('[Extractor] Calling FourKHdHubService for "$title"');
        final hdStream = await FourKHdHubService.instance
            .getStream(
              title: title,
              year: year,
              type: type,
              season: season,
              episode: episode,
              server: server,
            )
            .timeout(timeout, onTimeout: () => null);
        if (hdStream != null) return hdStream;
      } catch (e) {
        debugPrint('[Extractor] 4KHDHub error: $e');
      }
      return null;
    }

    // 3. Fallback Embed (vidfast) via Headless WebView
    final embedUrl = server.buildUrl(tmdbId, type, season: season, episode: episode);
    debugPrint('[Extractor] Starting webview extraction for ${server.name} ($embedUrl)');
    final completer = Completer<ExtractedStream?>();
    HeadlessInAppWebView? headless;

    bool isTornDown = false;
    Future<void> teardown() async {
      if (isTornDown) return;
      isTornDown = true;
      try {
        final h = headless;
        if (h != null) {
          _live.remove(h);
          await h.dispose().timeout(const Duration(seconds: 1));
        }
      } catch (_) {}
    }

    final discoveredSubtitles = <SubtitleTrack>[];

    void addSubtitle(String url, [String? label]) {
      if (url.isEmpty || discoveredSubtitles.any((s) => s.url == url)) return;
      final cleanLabel = label?.trim().isNotEmpty == true
          ? label!.trim()
          : (url.contains('.srt') ? 'Subtitles (SRT)' : 'Subtitles');
      discoveredSubtitles.add(SubtitleTrack(
        url: url,
        label: cleanLabel,
        language: 'en',
      ));
    }

    void finish(ExtractedStream? result) {
      if (!completer.isCompleted) {
        if (result != null && discoveredSubtitles.isNotEmpty) {
          completer.complete(result.copyWith(
            subtitles: [
              ...result.subtitles,
              ...discoveredSubtitles.where(
                (ds) => !result.subtitles.any((s) => s.url == ds.url),
              ),
            ],
          ));
        } else {
          completer.complete(result);
        }
        teardown();
      }
    }

    // Set extraction timeout
    final timer = Timer(timeout, () {
      finish(null);
    });

    void cancel() {
      timer.cancel();
      finish(null);
    }

    _activeCancels.add(cancel);

    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(embedUrl),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          },
        ),
        initialUserScripts: UnmodifiableListView([
          UserScript(
            source: """
              (function() {
                function dummyDevtool() {
                  return {
                    isSuspend: true,
                    isRunning: false,
                    stop: function() {},
                    start: function() {}
                  };
                }
                dummyDevtool.isSuspend = true;
                dummyDevtool.isRunning = false;
                dummyDevtool.stop = function() {};
                dummyDevtool.start = function() {};
                dummyDevtool.md5 = function() { return ''; };
                dummyDevtool.version = '0.3.7';

                try {
                  window.DisableDevtool = dummyDevtool;
                  Object.defineProperty(window, 'DisableDevtool', {
                    value: dummyDevtool,
                    writable: true,
                    configurable: true
                  });
                } catch(e) {}
              })();
            """,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: false,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          allowsInlineMediaPlayback: true,
          mediaPlaybackRequiresUserGesture: false,
          domStorageEnabled: true,
          databaseEnabled: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          useHybridComposition: true,
          isInspectable: false,
          // Block intrusive ads and popups
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: r'.*(disable-devtool).*',
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
          // Drop ad networks and anti-devtool scripts
          if (url.contains('disable-devtool') ||
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
          // WebView timers are process-global on Android; make sure they run.
          controller.resumeTimers();
          // JS bridge to catch direct video source assignment or HLS player loadSource
          controller.addJavaScriptHandler(
            handlerName: 'onMediaUrlFound',
            callback: (args) {
              if (args.isNotEmpty && args[0] is String) {
                final mediaUrl = args[0] as String;
                if (_isMediaStream(mediaUrl)) {
                  debugPrint('[Extractor] ${server.name} found stream via JS hook: $mediaUrl');
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
          controller.addJavaScriptHandler(
            handlerName: 'onSubtitleFound',
            callback: (args) {
              if (args.isNotEmpty) {
                if (args[0] is String) {
                  addSubtitle(args[0] as String);
                } else if (args[0] is Map) {
                  final m = args[0] as Map;
                  addSubtitle(m['url']?.toString() ?? '', m['label']?.toString());
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
                function dummyDevtool() {
                  return {
                    isSuspend: true,
                    isRunning: false,
                    stop: function() {},
                    start: function() {}
                  };
                }
                dummyDevtool.isSuspend = true;
                dummyDevtool.isRunning = false;
                dummyDevtool.stop = function() {};
                dummyDevtool.start = function() {};
                dummyDevtool.md5 = function() { return ''; };
                dummyDevtool.version = '0.3.7';

                window.DisableDevtool = dummyDevtool;
                Object.defineProperty(window, 'DisableDevtool', {
                  value: dummyDevtool,
                  writable: true,
                  configurable: true
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

              function notifySubtitle(url, label) {
                if (url && (url.includes('.vtt') || url.includes('.srt') || (url.includes('subtitle') && !url.includes('.js')))) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('onSubtitleFound', { url: url, label: label || 'Subtitles' });
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

              // Hook XHR & Fetch for m3u8 playlists and subtitles
              var originalOpen = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(method, url) {
                notify(url);
                notifySubtitle(url);
                return originalOpen.apply(this, arguments);
              };

              var originalFetch = window.fetch;
              window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input ? input.url : '');
                notify(url);
                notifySubtitle(url);
                return originalFetch.apply(this, arguments);
              };

              try {
                document.querySelectorAll('track').forEach(function(t) {
                  if (t.src) notifySubtitle(t.src, t.label || t.srclang);
                });
              } catch(e) {}

              // Auto-click play button every 400ms for lazy players
              try {
                var playInterval = setInterval(function() {
                  var selectors = [
                    '.play', '.play-btn', '.btn-play', '#play', '#player',
                    '.jw-display-icon-container', '.jw-preview',
                    '.vjs-big-play-button', '.vjs-play-control',
                    '.plyr__control--overlaid',
                    '.art-state', '.art-icon-play',
                    '[aria-label*="Play" i]', '[title*="Play" i]',
                    'button.play', '.play-button', '.play_button',
                    '#play-button', '.player-button'
                  ];
                  for (var i = 0; i < selectors.length; i++) {
                    var els = document.querySelectorAll(selectors[i]);
                    for (var j = 0; j < els.length; j++) {
                      try { els[j].click(); } catch(e) {}
                    }
                  }
                  var vids = document.querySelectorAll('video');
                  for (var k = 0; k < vids.length; k++) {
                    try {
                      if (vids[k].paused) {
                        vids[k].muted = true;
                        vids[k].play();
                      }
                    } catch(e) {}
                  }
                }, 400);
                setTimeout(function() { clearInterval(playInterval); }, 20000);
              } catch(e) {}
            })();
          """);
        },
        onLoadResource: (controller, resource) {
          final resUrl = resource.url?.toString() ?? '';
          if (_isSubtitle(resUrl)) {
            addSubtitle(resUrl);
          }
          if (_isMediaStream(resUrl)) {
            debugPrint('[Extractor] ${server.name} found stream via resource: $resUrl');
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
        onReceivedError: (controller, request, error) {
          final isMain = request.isForMainFrame ?? false;
          if (isMain) {
            debugPrint('[Extractor] main frame error on ${server.name}: ${error.description}');
            finish(null);
          }
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final isMain = request.isForMainFrame ?? false;
          if (isMain && (errorResponse.statusCode ?? 0) >= 400) {
            debugPrint('[Extractor] main frame HTTP error ${errorResponse.statusCode} on ${server.name}');
            finish(null);
          }
        },
        onLoadStop: (controller, url) async {
          try {
            final hasError = await controller.evaluateJavascript(source: """
              (function() {
                var body = document.body ? document.body.innerText.toLowerCase() : '';
                return body.includes('file not found') ||
                       body.includes('video not available') ||
                       body.includes('404 not found') ||
                       body.includes('this video has been removed');
              })();
            """);
            if (hasError == true) {
              debugPrint('[Extractor] video not available in DOM on ${server.name}');
              finish(null);
            }
          } catch (_) {}
        },
      );

      final h = headless;
      _live.add(h);
      await h.run();
      if (completer.isCompleted) teardown();
    } catch (_) {
      timer.cancel();
      finish(null);
    }

    final result = await completer.future;
    _activeCancels.remove(cancel);
    return result;
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

  static bool _isSubtitle(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.contains('google') ||
        lower.contains('doubleclick') ||
        lower.contains('tracker') ||
        lower.contains('analytics')) {
      return false;
    }
    return lower.contains('.vtt') ||
        lower.contains('.srt') ||
        (lower.contains('subtitle') && !lower.contains('.js') && !lower.contains('.css') && !lower.contains('.html'));
  }
}

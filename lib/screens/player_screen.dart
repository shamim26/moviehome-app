import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_theme.dart';
import '../models/extracted_stream.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/stream_server.dart';
import '../services/storage_service.dart';
import '../services/streaming/hls_and_subtitle_parser.dart';
import '../services/streaming/moviebox/moviebox_service.dart';
import '../services/streaming/stream_extractor.dart';

enum PlayerAspectRatio {
  fit('Fit (Default)', LucideIcons.minimize),
  zoom('Zoom (Fill)', LucideIcons.maximize),
  stretch('Stretch', LucideIcons.stretchHorizontal),
  sixteenNine('16:9', LucideIcons.tv),
  fourThree('4:3', LucideIcons.rectangleHorizontal);

  const PlayerAspectRatio(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum GestureHudType { volume, brightness, none }

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.item,
    this.initialSeason = 1,
    this.initialEpisode = 1,
    this.seasons = const [],
  });

  final MediaItem item;
  final int initialSeason;
  final int initialEpisode;
  final List<SeasonInfo> seasons;

  static void push(
    BuildContext context, {
    required MediaItem item,
    int season = 1,
    int episode = 1,
    List<SeasonInfo> seasons = const [],
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: item,
          initialSeason: season,
          initialEpisode: episode,
          seasons: seasons,
        ),
      ),
    );
  }

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _playerController;
  late StreamServer _currentServer;
  late int _season;
  late int _episode;
  late final StorageService _storage;

  bool _isExtracting = true;
  String? _extractionError;
  String _statusTitle = '';
  String _statusSubtitle = '';
  bool _showControls = true;
  Timer? _hideControlsTimer;
  Timer? _progressSaveTimer;
  bool _disposed = false;
  bool _isCleanedUp = false;
  int _generation = 0;

  // Custom player features
  PlayerAspectRatio _aspectRatioMode = PlayerAspectRatio.fit;
  ExtractedStream? _currentExtractedStream;
  List<StreamQuality> _availableQualities = [];
  StreamQuality? _currentQuality;

  List<SubtitleTrack> _availableSubtitles = [];
  SubtitleTrack? _selectedSubtitle;
  List<SubtitleCue> _subtitleCues = [];
  String? _currentSubtitleText;

  // Gesture Controls (Phone System Volume & Brightness)
  double _volume = 1.0;
  double _brightness = 1.0;
  double? _initialVolume;
  GestureHudType _gestureHudType = GestureHudType.none;
  int _lastVolumeSetMs = 0;
  Timer? _gestureHudTimer;

  // HUD toast banner
  String? _hudMessage;
  Timer? _hudMessageTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _storage = ref.read(storageServiceProvider);

    _season = widget.initialSeason;
    _episode = widget.initialEpisode;

    // Load saved preferences
    final saved = _storage.getWatchProgress(
      widget.item.id,
      widget.item.mediaType,
    );
    if (saved != null && saved['serverId'] is String) {
      _currentServer = StreamServers.byId(saved['serverId'] as String);
    } else {
      _currentServer = StreamServers.all.first;
    }

    // Keep screen awake during playback
    WakelockPlus.enable();

    // Lock player screen strictly to cinema landscape mode (no vertical mode)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _initSystemVolumeAndBrightness();
    _initStream();
  }

  Future<void> _initSystemVolumeAndBrightness() async {
    try {
      double b = await ScreenBrightness().system;
      if (b <= 0.05 || b > 1.0) {
        b = await ScreenBrightness().application;
      }
      if (b <= 0.05 || b > 1.0) {
        b = 0.8;
      }
      if (mounted) {
        setState(() {
          _brightness = b;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _brightness = 0.8;
        });
      }
    }

    try {
      VolumeController.instance.showSystemUI = false;
      final vol = await VolumeController.instance.getVolume();
      if (mounted) {
        setState(() {
          _volume = vol;
          _initialVolume = vol;
        });
      }
      VolumeController.instance.addListener((v) {
        if (!mounted || _disposed) return;
        if (_gestureHudType == GestureHudType.volume) return;
        setState(() {
          _volume = v;
        });
      });
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Note: Do NOT pause on AppLifecycleState.inactive (which happens when pulling
    // down Android control center / quick settings shade to adjust volume).
    // Only pause when app is genuinely backgrounded or hidden.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _playerController?.pause();
      _saveProgress();
    }
  }

  void _onPlayerTick() {
    if (!mounted) return;
    if (_subtitleCues.isEmpty) {
      if (_currentSubtitleText != null) {
        setState(() => _currentSubtitleText = null);
      }
      return;
    }

    final pos = _playerController?.value.position ?? Duration.zero;
    SubtitleCue? activeCue;
    for (final cue in _subtitleCues) {
      if (pos >= cue.start && pos <= cue.end) {
        activeCue = cue;
        break;
      }
    }

    final newText = activeCue?.text;
    if (newText != _currentSubtitleText) {
      setState(() {
        _currentSubtitleText = newText;
      });
    }
  }

  void _showHudMessage(String message) {
    _hudMessageTimer?.cancel();
    setState(() {
      _hudMessage = message;
    });
    _hudMessageTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) setState(() => _hudMessage = null);
    });
  }

  void _cycleAspectRatio() {
    final values = PlayerAspectRatio.values;
    final nextIndex = (values.indexOf(_aspectRatioMode) + 1) % values.length;
    setState(() {
      _aspectRatioMode = values[nextIndex];
    });
    _showHudMessage('Ratio: ${_aspectRatioMode.label}');
  }

  Future<void> _switchQuality(StreamQuality quality) async {
    if (_currentQuality?.url == quality.url && _playerController != null) {
      return;
    }
    final old = _playerController;
    if (old == null) return;

    final currentPos = old.value.position;
    final wasPlaying = old.value.isPlaying;
    final currentHeaders = _currentExtractedStream?.headers ?? {};

    setState(() {
      _currentQuality = quality;
      _isExtracting = true;
      _statusTitle = 'Switching to ${quality.label}...';
      _statusSubtitle = 'Applying video resolution';
    });

    old.removeListener(_onPlayerTick);
    old.pause();
    await old.dispose();
    _playerController = null;

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(quality.url),
        httpHeaders: currentHeaders,
      );
      await controller.initialize();
      if (!mounted || _disposed) {
        controller.dispose();
        return;
      }

      controller.addListener(_onPlayerTick);
      controller.setVolume(1.0);
      if (currentPos.inSeconds > 0) {
        await controller.seekTo(currentPos);
      }
      if (wasPlaying) {
        controller.play();
      }

      setState(() {
        _playerController = controller;
        _isExtracting = false;
      });
      _showHudMessage('Quality: ${quality.label}');
    } catch (_) {
      if (!mounted || _disposed) return;
      _initStream();
    }
  }

  Future<void> _selectSubtitle(SubtitleTrack? track) async {
    if (track == null) {
      setState(() {
        _selectedSubtitle = null;
        _subtitleCues = [];
        _currentSubtitleText = null;
      });
      _showHudMessage('Subtitles: Off');
      return;
    }

    setState(() {
      _selectedSubtitle = track;
      _showHudMessage('Subtitles: ${track.label}');
    });

    final cues = await HlsAndSubtitleHelper.fetchAndParseSubtitles(
      url: track.url,
      headers: _currentExtractedStream?.headers,
    );

    if (mounted && _selectedSubtitle?.url == track.url) {
      setState(() {
        _subtitleCues = cues;
      });
    }
  }

  void _fetchFallbackSubtitles(int gen) {
    MovieBoxService.instance.fetchSubtitles(
      title: widget.item.title,
      year: int.tryParse(widget.item.year),
      type: widget.item.mediaType,
      season: _season,
      episode: _episode,
    ).then((subs) {
      if (!mounted || _disposed || gen != _generation) return;
      if (subs.isNotEmpty) {
        setState(() {
          final merged = <SubtitleTrack>[...subs];
          if (_selectedSubtitle != null &&
              !merged.any((s) => s.url == _selectedSubtitle!.url)) {
            merged.insert(0, _selectedSubtitle!);
          }
          _availableSubtitles = merged;
        });
      }
    }).catchError((_) {});
  }

  void _cleanUp() {
    if (_isCleanedUp) return;
    _isCleanedUp = true;
    _disposed = true;

    _hideControlsTimer?.cancel();
    _progressSaveTimer?.cancel();
    _gestureHudTimer?.cancel();
    _hudMessageTimer?.cancel();

    // 1. Save progress and stop native video immediately
    final c = _playerController;
    _playerController = null;
    if (c != null) {
      try {
        c.removeListener(_onPlayerTick);
        final pos = c.value.position.inSeconds;
        _storage.saveWatchProgress(
          tmdbId: widget.item.id,
          type: widget.item.mediaType,
          serverId: _currentServer.id,
          season: _season,
          episode: _episode,
          positionSeconds: pos,
        );
      } catch (_) {}
      try {
        c.setVolume(0);
        c.pause();
        c.dispose();
      } catch (_) {}
    }

    // 2. Cancel and dispose any background stream extractors
    try {
      StreamExtractor.instance.cancelAll();
      StreamExtractor.instance.disposeAllWebViews();
    } catch (_) {}

    // 3. Reset system orientation and restore quick-settings status bar
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    try {
      WakelockPlus.disable();
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}

    // 4. Restore original phone system brightness
    try {
      ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {}

    // 5. Restore original phone system volume and system volume UI
    try {
      VolumeController.instance.removeListener();
      VolumeController.instance.showSystemUI = true;
      if (_initialVolume != null) {
        VolumeController.instance.setVolume(_initialVolume!);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _cleanUp();
    super.dispose();
  }

  Future<void> _initStream({
    StreamServer? preferredServer,
    bool allowAutoFallback = true,
  }) async {
    final gen = ++_generation;
    StreamExtractor.instance.cancelAll();

    final targetServer = preferredServer ?? _currentServer;
    final itemTitle = widget.item.title;

    setState(() {
      _currentServer = targetServer;
      _isExtracting = true;
      _extractionError = null;
      _statusTitle = 'Loading $itemTitle...';
      _statusSubtitle = 'Connecting to ${_currentServer.name}...';
      _currentSubtitleText = null;
    });

    final old = _playerController;
    _playerController = null;
    old?.removeListener(_onPlayerTick);
    old?.pause();
    await old?.dispose();

    // Rotational order: start with targetServer, then proceed in order without resetting to Server 1
    final startIndex = StreamServers.all.indexWhere((s) => s.id == targetServer.id);
    final effectiveIndex = startIndex >= 0 ? startIndex : 0;
    final serverQueue = allowAutoFallback
        ? List.generate(
            StreamServers.all.length,
            (i) => StreamServers.all[(effectiveIndex + i) % StreamServers.all.length],
          )
        : [targetServer];

    bool streamStarted = false;

    for (int i = 0; i < serverQueue.length; i++) {
      if (!mounted || _disposed || gen != _generation) return;

      final candidate = serverQueue[i];
      debugPrint('[Player] >>> Trying server [${candidate.name}] (${candidate.id}) for "$itemTitle"');

      setState(() {
        _currentServer = candidate;
        _statusTitle = 'Loading $itemTitle...';
        _statusSubtitle = i == 0
            ? 'Connecting to ${candidate.name}...'
            : 'Trying next server (${candidate.name})...';
      });

      // Allow server ample time (up to 30s) to decrypt and prepare stream
      final stream = await StreamExtractor.instance.extractSingleServer(
        server: candidate,
        tmdbId: widget.item.id,
        type: widget.item.mediaType,
        title: widget.item.title,
        year: int.tryParse(widget.item.year),
        season: _season,
        episode: _episode,
        timeout: const Duration(seconds: 30),
      );

      if (!mounted || _disposed || gen != _generation) return;

      if (stream == null) {
        debugPrint('[Player] <<< Server [${candidate.name}] failed or returned null');
        // Only switch when the server genuinely failed to extract
        if (i < serverQueue.length - 1) {
          setState(() {
            _statusSubtitle =
                '${candidate.name} could not load stream. Trying next server...';
          });
        }
        continue;
      }

      debugPrint('[Player] <<< Server [${candidate.name}] success: ${stream.url.substring(0, stream.url.length > 80 ? 80 : stream.url.length)}... (isHls: ${stream.isHls}, qualities: ${stream.qualities.length}, subs: ${stream.subtitles.length})');

      setState(() {
        _statusSubtitle = 'Preparing video player...';
        _currentExtractedStream = stream;
      });

      try {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(stream.url),
          httpHeaders: stream.headers,
        );

        await controller.initialize();
        if (!mounted || _disposed || gen != _generation) {
          controller.dispose();
          return;
        }

        controller.addListener(_onPlayerTick);
        controller.setVolume(1.0);

        setState(() {
          _playerController = controller;
          _isExtracting = false;
        });

        // Parse resolutions and subtitles asynchronously from source
        if (stream.isHls) {
          HlsAndSubtitleHelper.inspectHlsStream(
            url: stream.url,
            headers: stream.headers,
          ).then((hlsInfo) {
            if (!mounted || _disposed || gen != _generation) return;
            final allSubs = <SubtitleTrack>[
              ...stream.subtitles,
              ...hlsInfo.subtitles.where(
                (hs) => !stream.subtitles.any((s) => s.url == hs.url),
              ),
            ];
            setState(() {
              _availableQualities = hlsInfo.qualities.isNotEmpty
                  ? hlsInfo.qualities
                  : [StreamQuality(label: 'Auto', url: stream.url)];
              _currentQuality = _availableQualities.first;
              if (allSubs.isNotEmpty) {
                _availableSubtitles = allSubs;
              } else if (_availableSubtitles.isEmpty) {
                _fetchFallbackSubtitles(gen);
              }
            });
          });
        } else {
          setState(() {
            _availableQualities = stream.qualities.isNotEmpty
                ? stream.qualities
                : [
                    StreamQuality(
                      label: stream.quality.isNotEmpty ? stream.quality : 'Source',
                      url: stream.url,
                    ),
                  ];
            _currentQuality = _availableQualities.first;
            if (stream.subtitles.isNotEmpty) {
              _availableSubtitles = stream.subtitles;
            } else if (_availableSubtitles.isEmpty) {
              _fetchFallbackSubtitles(gen);
            }
          });
        }

        // Resume playback position if saved
        final saved = _storage.getWatchProgress(
          widget.item.id,
          widget.item.mediaType,
        );
        if (saved != null && saved['positionSeconds'] is int) {
          final pos = saved['positionSeconds'] as int;
          if (pos > 10 && pos < (controller.value.duration.inSeconds - 30)) {
            controller.seekTo(Duration(seconds: pos));
          }
        }

        controller.play();
        _startHideTimer();
        debugPrint('[Player] Player initialized and playing successfully for [${candidate.name}] (duration: ${controller.value.duration.inSeconds}s)');

        if (candidate.id == '4khdhub') {
          final urlLower = stream.url.toLowerCase();
          final isDolbyOrDts = (urlLower.contains('ddp') ||
                  urlLower.contains('dd%2b') ||
                  urlLower.contains('dts') ||
                  urlLower.contains('atmos') ||
                  urlLower.contains('truehd')) &&
              !urlLower.contains('aac');
          if (isDolbyOrDts) {
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (mounted && !_disposed && _playerController == controller) {
                _showHudMessage('Note: If no audio, switch to Server 1 or 3');
              }
            });
          }
        }

        // Periodic progress saving every 10 seconds
        _progressSaveTimer?.cancel();
        _progressSaveTimer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _saveProgress(),
        );

        streamStarted = true;
        break; // Successfully connected and initialized!
      } catch (e, st) {
        debugPrint('[Player] VideoPlayerController error for [${candidate.name}]: $e\n$st');
        if (!mounted || _disposed || gen != _generation) return;
        if (i < serverQueue.length - 1) {
          setState(() {
            _statusSubtitle =
                '${candidate.name} stream error. Trying next server...';
          });
        }
        continue;
      }
    }

    if (!streamStarted && mounted && !_disposed && gen == _generation) {
      setState(() {
        _isExtracting = false;
        _extractionError = allowAutoFallback
            ? 'We couldn\'t load this title right now across available servers. Please try again or switch servers manually.'
            : '${targetServer.name} could not play this title. Please try another server or retry.';
      });
    }
  }

  void _saveProgress() {
    final c = _playerController;
    if (c == null) return;
    try {
      final pos = c.value.position.inSeconds;
      _storage.saveWatchProgress(
        tmdbId: widget.item.id,
        type: widget.item.mediaType,
        serverId: _currentServer.id,
        season: _season,
        episode: _episode,
        positionSeconds: pos,
      );
    } catch (_) {}
  }

  void _switchServer(StreamServer server, {bool allowAutoFallback = false}) {
    if (_currentServer.id == server.id &&
        !_isExtracting &&
        _playerController != null) {
      return;
    }
    _saveProgress();
    _initStream(preferredServer: server, allowAutoFallback: allowAutoFallback);
  }

  void _switchToNextServer() {
    final currentIndex = StreamServers.all.indexWhere((s) => s.id == _currentServer.id);
    final nextIndex = (currentIndex + 1) % StreamServers.all.length;
    final nextServer = StreamServers.all[nextIndex];
    _switchServer(nextServer, allowAutoFallback: false);
  }

  void _changeEpisode(int ep) {
    if (ep < 1) return;
    setState(() {
      _episode = ep;
      _availableSubtitles = [];
      _selectedSubtitle = null;
      _subtitleCues = [];
      _currentSubtitleText = null;
    });
    _saveProgress();
    _initStream();
  }

  void _togglePlayPause() {
    final controller = _playerController;
    if (controller == null) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
        _showControls = true;
        _hideControlsTimer?.cancel();
      } else {
        controller.play();
        _startHideTimer();
      }
    });
  }

  void _seekRelative(int seconds) {
    final controller = _playerController;
    if (controller == null) return;
    final current = controller.value.position;
    final target = current + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > controller.value.duration
              ? controller.value.duration
              : target);
    controller.seekTo(clamped);
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_playerController?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _onVerticalDragStart(
    DragStartDetails details,
    BoxConstraints constraints,
  ) {
    _gestureHudTimer?.cancel();
    final isLeft = details.localPosition.dx < (constraints.maxWidth / 2);
    setState(() {
      _gestureHudType = isLeft
          ? GestureHudType.brightness
          : GestureHudType.volume;
    });
  }

  void _onVerticalDragUpdate(
    DragUpdateDetails details,
    BoxConstraints constraints,
  ) {
    final delta = -details.primaryDelta! / 200.0;
    if (_gestureHudType == GestureHudType.brightness) {
      final newBrightness = (_brightness + delta).clamp(0.1, 1.0);
      setState(() {
        _brightness = newBrightness;
      });
      try {
        ScreenBrightness().setApplicationScreenBrightness(newBrightness);
      } catch (_) {}
    } else if (_gestureHudType == GestureHudType.volume) {
      final newVol = (_volume + delta).clamp(0.0, 1.0);
      setState(() {
        _volume = newVol;
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastVolumeSetMs > 40) {
        _lastVolumeSetMs = now;
        try {
          VolumeController.instance.setVolume(newVol);
        } catch (_) {}
      }
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_gestureHudType == GestureHudType.volume) {
      try {
        VolumeController.instance.setVolume(_volume);
      } catch (_) {}
    }
    _gestureHudTimer?.cancel();
    _gestureHudTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _gestureHudType = GestureHudType.none;
        });
      }
    });
  }

  void _showServerSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        LucideIcons.server,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Select Video Server',
                        style: Theme.of(ctx).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const Divider(color: AppColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.primary),
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(LucideIcons.skipForward, size: 16),
                      label: Text(
                        'Switch to Next Server (${StreamServers.all[(StreamServers.all.indexWhere((s) => s.id == _currentServer.id) + 1) % StreamServers.all.length].name})',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _switchToNextServer();
                      },
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: StreamServers.all.length,
                    itemBuilder: (_, idx) {
                      final s = StreamServers.all[idx];
                      final isSelected = s.id == _currentServer.id;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: isSelected
                              ? AppColors.primary
                              : AppColors.secondary,
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : AppColors.foreground,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        title: Text(
                          s.name.toUpperCase(),
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.foreground,
                          ),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.secondary,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            s.quality,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _switchServer(s, allowAutoFallback: false);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showQualitySelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        LucideIcons.slidersHorizontal,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Video Quality',
                        style: Theme.of(ctx).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const Divider(color: AppColors.border),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _availableQualities.length,
                    itemBuilder: (_, idx) {
                      final q = _availableQualities[idx];
                      final isSelected = q.label == _currentQuality?.label;
                      return ListTile(
                        leading: Icon(
                          isSelected
                              ? LucideIcons.checkCircle2
                              : LucideIcons.circle,
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.mutedForeground,
                          size: 20,
                        ),
                        title: Text(
                          q.label,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.foreground,
                          ),
                        ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _switchQuality(q);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSubtitleSelector() {
    if (_availableSubtitles.isEmpty) {
      _fetchFallbackSubtitles(_generation);
    }
    final displaySubtitles = <SubtitleTrack>[..._availableSubtitles];
    if (_selectedSubtitle != null &&
        !displaySubtitles.any((s) => s.url == _selectedSubtitle!.url)) {
      displaySubtitles.insert(0, _selectedSubtitle!);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        LucideIcons.subtitles,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Subtitles',
                        style: Theme.of(ctx).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const Divider(color: AppColors.border),
                ListTile(
                  leading: Icon(
                    _selectedSubtitle == null
                        ? LucideIcons.checkCircle2
                        : LucideIcons.circle,
                    color: _selectedSubtitle == null
                        ? AppColors.primary
                        : AppColors.mutedForeground,
                    size: 20,
                  ),
                  title: Text(
                    'Off',
                    style: TextStyle(
                      fontWeight: _selectedSubtitle == null
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: _selectedSubtitle == null
                          ? AppColors.primary
                          : AppColors.foreground,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _selectSubtitle(null);
                  },
                ),
                if (displaySubtitles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Text(
                      'No subtitles available for this source stream.',
                      style: TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: displaySubtitles.length,
                      itemBuilder: (_, idx) {
                        final sub = displaySubtitles[idx];
                        final isSelected = _selectedSubtitle?.url == sub.url;
                        return ListTile(
                          leading: Icon(
                            isSelected
                                ? LucideIcons.checkCircle2
                                : LucideIcons.circle,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.mutedForeground,
                            size: 20,
                          ),
                          title: Text(
                            sub.label,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.foreground,
                            ),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.secondary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              sub.language.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _selectSubtitle(sub);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoPlayerWidget(VideoPlayerController controller) {
    final videoSize = controller.value.size;
    final videoAspect = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : (16 / 9);
    final safeWidth = videoSize.width > 0 ? videoSize.width : 1280.0;
    final safeHeight = videoSize.height > 0 ? videoSize.height : 720.0;

    switch (_aspectRatioMode) {
      case PlayerAspectRatio.fit:
        return Center(
          child: AspectRatio(
            aspectRatio: videoAspect,
            child: VideoPlayer(controller),
          ),
        );

      case PlayerAspectRatio.zoom:
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: safeWidth,
              height: safeHeight,
              child: VideoPlayer(controller),
            ),
          ),
        );

      case PlayerAspectRatio.stretch:
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: safeWidth,
              height: safeHeight,
              child: VideoPlayer(controller),
            ),
          ),
        );

      case PlayerAspectRatio.sixteenNine:
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: safeWidth,
                height: safeHeight,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        );

      case PlayerAspectRatio.fourThree:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: safeWidth,
                height: safeHeight,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        );
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _playerController;
    final isTv = widget.item.mediaType == MediaType.tv;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _cleanUp();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
              return GestureDetector(
                onTap: () {
                  setState(() => _showControls = !_showControls);
                  if (_showControls) _startHideTimer();
                },
                onVerticalDragStart: (details) =>
                    _onVerticalDragStart(details, constraints),
                onVerticalDragUpdate: (details) =>
                    _onVerticalDragUpdate(details, constraints),
                onVerticalDragEnd: _onVerticalDragEnd,
                behavior: HitTestBehavior.opaque,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 1. Native Video Surface with Aspect Ratio support
                    if (controller != null && controller.value.isInitialized)
                      _buildVideoPlayerWidget(controller)
                    else if (!_isExtracting && _extractionError == null)
                      const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      ),

                    // 3. Buffering Overlay
                    if (controller != null && controller.value.isInitialized)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (context, val, _) {
                          if (val.isBuffering) {
                            return Center(
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  shape: BoxShape.circle,
                                ),
                                child: const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3.5,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),

                    // 4. Subtitle Overlay
                    if (_currentSubtitleText != null &&
                        _currentSubtitleText!.isNotEmpty)
                      Positioned(
                        bottom: _showControls ? 96 : 38,
                        left: 24,
                        right: 24,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _currentSubtitleText!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                shadows: [
                                  Shadow(
                                    color: Colors.black,
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 5. Volume Gesture HUD (Right side)
                    if (_gestureHudType == GestureHudType.volume)
                      Positioned(
                        right: 36,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 54,
                            padding: const EdgeInsets.symmetric(
                              vertical: 18,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(27),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(
                                  _volume == 0
                                      ? LucideIcons.volumeX
                                      : (_volume < 0.5
                                            ? LucideIcons.volume1
                                            : LucideIcons.volume2),
                                  color: Colors.white,
                                  size: 22,
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  width: 6,
                                  height: 90,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    width: 6,
                                    height: (90 * _volume).clamp(0.0, 90.0),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    '${(_volume * 100).round()}%',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // 6. Brightness Gesture HUD (Left side)
                    if (_gestureHudType == GestureHudType.brightness)
                      Positioned(
                        left: 36,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 54,
                            padding: const EdgeInsets.symmetric(
                              vertical: 18,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(27),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                const Icon(
                                  LucideIcons.sun,
                                  color: Colors.white,
                                  size: 22,
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  width: 6,
                                  height: 90,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    width: 6,
                                    height: (90 * _brightness).clamp(0.0, 90.0),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    '${(_brightness * 100).round()}%',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // 7. HUD Banner Message (Ratio / Quality / Subtitle toast)
                    if (_hudMessage != null)
                      Positioned(
                        bottom: (_currentSubtitleText != null &&
                                _currentSubtitleText!.isNotEmpty)
                            ? (_showControls ? 136.0 : 78.0)
                            : (_showControls ? 88.0 : 36.0),
                        left: 32,
                        right: 32,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Text(
                              _hudMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 8. User-Friendly Loading Overlay
                    if (_isExtracting)
                      Container(
                        color: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 44,
                                height: 44,
                                child: CircularProgressIndicator(
                                  color: AppColors.primary,
                                  strokeWidth: 3.5,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                _statusTitle.isNotEmpty
                                    ? _statusTitle
                                    : 'Loading video...',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 8),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Text(
                                  _statusSubtitle.isNotEmpty
                                      ? _statusSubtitle
                                      : 'Connecting to ${_currentServer.name}...',
                                  key: ValueKey(_statusSubtitle),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppColors.mutedForeground,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 9. Error Overlay
                    if (_extractionError != null)
                      Container(
                        color: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                LucideIcons.videoOff,
                                size: 48,
                                color: AppColors.primarySoft,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _extractionError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () => _initStream(preferredServer: _currentServer),
                                    icon: const Icon(
                                      LucideIcons.rotateCw,
                                      size: 16,
                                    ),
                                    label: const Text('Retry'),
                                  ),
                                  const SizedBox(width: 12),
                                  OutlinedButton.icon(
                                    onPressed: _showServerSelector,
                                    icon: const Icon(
                                      LucideIcons.server,
                                      size: 16,
                                    ),
                                    label: const Text('Change Server'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 10. Custom Cinema Controls Overlay
                    if (controller != null && controller.value.isInitialized)
                      AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        child: IgnorePointer(
                          ignoring: !_showControls,
                          child: Stack(
                            children: [
                              // Top Bar Overlay
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black87,
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                  child: SafeArea(
                                    top: false,
                                    bottom: false,
                                    minimum: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          LucideIcons.arrowLeft,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                        onPressed: () {
                                          _cleanUp();
                                          Navigator.of(context).pop();
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              widget.item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 15,
                                              ),
                                            ),
                                            if (isTv)
                                              Text(
                                                'Season $_season • Episode $_episode',
                                                style: const TextStyle(
                                                  color:
                                                      AppColors.mutedForeground,
                                                  fontSize: 12,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      // Action buttons docked to the far right end
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Subtitles button
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.all(4),
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            icon: Icon(
                                              LucideIcons.subtitles,
                                              color: _selectedSubtitle != null
                                                  ? AppColors.primary
                                                  : Colors.white,
                                              size: 18,
                                            ),
                                            tooltip: 'Subtitles',
                                            onPressed: _showSubtitleSelector,
                                          ),
                                          const SizedBox(width: 4),

                                          // Quality / Resolution Selector
                                          GestureDetector(
                                            onTap: _showQualitySelector,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: AppColors.secondary,
                                                borderRadius: BorderRadius.circular(14),
                                                border: Border.all(color: AppColors.border),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    LucideIcons.slidersHorizontal,
                                                    size: 11,
                                                    color: Colors.white70,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  ConstrainedBox(
                                                    constraints: const BoxConstraints(maxWidth: 70),
                                                    child: Text(
                                                      _currentQuality?.label ?? 'Auto',
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w700,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),

                                          // Server Selector
                                          GestureDetector(
                                            onTap: _showServerSelector,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: AppColors.secondary,
                                                borderRadius: BorderRadius.circular(14),
                                                border: Border.all(color: AppColors.primarySoft),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    LucideIcons.server,
                                                    size: 11,
                                                    color: AppColors.primary,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  ConstrainedBox(
                                                    constraints: const BoxConstraints(maxWidth: 85),
                                                    child: Text(
                                                      _currentServer.name.toUpperCase(),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w700,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 2),
                                                  const Icon(
                                                    LucideIcons.chevronDown,
                                                    size: 11,
                                                    color: Colors.white70,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                              // Center Actions: -10s, Play/Pause, +10s
                              Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      iconSize: 36,
                                      icon: const Icon(
                                        LucideIcons.rotateCcw,
                                        color: Colors.white,
                                      ),
                                      onPressed: () => _seekRelative(-10),
                                    ),
                                    const SizedBox(width: 36),
                                    ValueListenableBuilder<VideoPlayerValue>(
                                      valueListenable: controller,
                                      builder: (context, val, _) {
                                        if (val.isBuffering) {
                                          return Container(
                                            width: 64,
                                            height: 64,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.9),
                                            ),
                                            child: const Center(
                                              child: SizedBox(
                                                width: 28,
                                                height: 28,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 3,
                                                      color: Colors.white,
                                                    ),
                                              ),
                                            ),
                                          );
                                        }
                                        return Container(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: AppColors.primary.withValues(
                                              alpha: 0.9,
                                            ),
                                          ),
                                          child: IconButton(
                                            iconSize: 48,
                                            icon: Icon(
                                              val.isPlaying
                                                  ? LucideIcons.pause
                                                  : LucideIcons.play,
                                              color: Colors.white,
                                            ),
                                            onPressed: _togglePlayPause,
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 36),
                                    IconButton(
                                      iconSize: 36,
                                      icon: const Icon(
                                        LucideIcons.rotateCw,
                                        color: Colors.white,
                                      ),
                                      onPressed: () => _seekRelative(10),
                                    ),
                                  ],
                                ),
                              ),

                              // Bottom Bar: Scrubber + Timing + Fullscreen next to timer + TV Controls
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [
                                        Colors.black87,
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                  child: SafeArea(
                                    top: false,
                                    bottom: false,
                                    minimum: const EdgeInsets.fromLTRB(
                                      12,
                                      10,
                                      12,
                                      12,
                                    ),
                                    child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Slider Seekbar with fullscreen button next to the timer
                                      ValueListenableBuilder<VideoPlayerValue>(
                                        valueListenable: controller,
                                        builder: (context, val, _) {
                                          final max = val
                                              .duration
                                              .inMilliseconds
                                              .toDouble();
                                          final current = val
                                              .position
                                              .inMilliseconds
                                              .toDouble()
                                              .clamp(0.0, max);
                                          return Row(
                                            children: [
                                              Text(
                                                _formatDuration(val.position),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              Expanded(
                                                child: SliderTheme(
                                                  data: SliderTheme.of(context).copyWith(
                                                    trackHeight: 3,
                                                    thumbShape:
                                                        const RoundSliderThumbShape(
                                                          enabledThumbRadius: 6,
                                                        ),
                                                    overlayShape:
                                                        const RoundSliderOverlayShape(
                                                          overlayRadius: 12,
                                                        ),
                                                    activeTrackColor:
                                                        AppColors.primary,
                                                    inactiveTrackColor:
                                                        Colors.white24,
                                                    thumbColor:
                                                        AppColors.primary,
                                                  ),
                                                  child: Slider(
                                                    value: max > 0
                                                        ? current
                                                        : 0.0,
                                                    min: 0.0,
                                                    max: max > 0 ? max : 1.0,
                                                    onChanged: (pos) {
                                                      controller.seekTo(
                                                        Duration(
                                                          milliseconds: pos
                                                              .toInt(),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                _formatDuration(val.duration),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                icon: Icon(
                                                  _aspectRatioMode.icon,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                tooltip: 'Screen Size (${_aspectRatioMode.label})',
                                                onPressed: _cycleAspectRatio,
                                              ),
                                            ],
                                          );
                                        },
                                      ),

                                      // TV Episodes Next / Prev
                                      if (isTv) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Flexible(
                                              child: TextButton.icon(
                                                onPressed: _episode > 1
                                                    ? () => _changeEpisode(
                                                        _episode - 1,
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  LucideIcons.chevronLeft,
                                                  size: 15,
                                                ),
                                                label: const Text(
                                                  'Prev Episode',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                style: TextButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 4,
                                                  ),
                                                  foregroundColor: _episode > 1
                                                      ? Colors.white
                                                      : Colors.white24,
                                                ),
                                              ),
                                            ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                              ),
                                              child: Text(
                                                'Episode $_episode',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors.primary,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                            Flexible(
                                              child: TextButton(
                                                onPressed: () =>
                                                    _changeEpisode(_episode + 1),
                                                style: TextButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 4,
                                                  ),
                                                  foregroundColor:
                                                      Colors.white,
                                                ),
                                                child: const Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      'Next Episode',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    SizedBox(width: 3),
                                                    Icon(
                                                      LucideIcons.chevronRight,
                                                      size: 15,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
  }
}

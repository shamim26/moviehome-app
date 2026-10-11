import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart' hide SubtitleTrack;
import 'package:media_kit/media_kit.dart' as mk show SubtitleTrack;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_theme.dart';
import '../models/extracted_stream.dart';
import '../models/media_details.dart' hide Video;
import '../models/media_item.dart';
import '../models/stream_server.dart';
import '../services/storage_service.dart';
import '../services/streaming/hls_and_subtitle_parser.dart';
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
  Player? _player;
  VideoController? _videoController;
  late StreamServer _currentServer;
  late int _season;
  late int _episode;
  late final StorageService _storage;

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<String>? _errorSubscription;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;

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
  int _videoRenderKeyIndex = 0;

  List<SubtitleTrack> _availableSubtitles = [];
  SubtitleTrack? _selectedSubtitle;
  List<SubtitleCue> _subtitleCues = [];
  String? _currentSubtitleText;
  int _lastSubtitleCueIndex = 0;
  int _lastPositionUiUpdateMs = 0;
  bool _userExplicitlyDisabledSubtitles = false;

  // Multi-Audio Tracks
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  List<AudioTrack> _availableAudioTracks = [];
  AudioTrack? _selectedAudioTrack;

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

  // Seek and error recovery state
  bool _isDraggingSlider = false;
  double? _dragSliderValueMs;
  bool _isSeeking = false;
  int _seekRequestId = 0;
  Duration _lastKnownPosition = Duration.zero;
  bool _isRecovering = false;
  int _errorRecoveryAttempts = 0;
  bool _triedSoftwareFallback = false;
  String? _playerErrorMessage;

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

    // Lock player screen strictly to cinema landscape mode
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
      if (b < 0.0 || b > 1.0) {
        b = await ScreenBrightness().application;
      }
      if (b < 0.0 || b > 1.0) {
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _player?.pause();
      _saveProgress();
    }
  }

  void _ensurePlayerInitialized() {
    if (_player != null) return;
    // Set minimal log level to eliminate JNI/Dart bridge log spam
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
      ),
    );

    // Mobile-optimized MPV demuxer and decoder tuning:
    // Low RAM/CPU footprint, prevents aggressive network spinning & decoder flush loops
    try {
      final dynamic native = player.platform;
      native?.setProperty('demuxer-max-bytes', '16777216'); // 16 MB read-ahead (sufficient for ~40s 1080p)
      native?.setProperty('demuxer-max-back-bytes', '4194304'); // 4 MB back buffer
      native?.setProperty('cache', 'yes');
      native?.setProperty('cache-secs', '15'); // 15 seconds buffer avoids constant CPU & Wi-Fi wake
      native?.setProperty('demuxer-readahead-secs', '10');
      native?.setProperty('network-timeout', '15');

      // Video sync & decoder anti-thrash
      native?.setProperty('video-sync', 'audio');
      native?.setProperty('framedrop', 'vo');
      native?.setProperty('hr-seek', 'no');
      native?.setProperty('demuxer-lavf-analyzeduration', '1');
      native?.setProperty('demuxer-lavf-probesize', '1048576');
      native?.setProperty('audio-pitch-correction', 'no');
    } catch (e) {
      debugPrint('[Player] Note: could not apply custom MPV cache properties: $e');
    }

    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: 'mediacodec',
      ),
    );
    _player = player;
    _videoController = controller;
    _attachPlayerListeners(player);
  }

  void _attachPlayerListeners(Player player) {
    _positionSubscription?.cancel();
    _positionSubscription = player.stream.position.listen((pos) {
      if (!mounted || _disposed) return;
      _lastKnownPosition = pos;
      if (pos > Duration.zero) {
        _errorRecoveryAttempts = 0;
      }

      // 1. Efficient subtitle cue check (O(1) fast path)
      _updateSubtitleCue(pos);

      // 2. Battery & CPU optimization: only rebuild the widget tree when controls are visible
      // and throttled to at most once per 300ms.
      // When controls are hidden during playback, updating _position in memory requires 0 UI rebuilds!
      if (!_isDraggingSlider) {
        if (_showControls) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastPositionUiUpdateMs >= 300 || pos.inSeconds != _position.inSeconds) {
            _lastPositionUiUpdateMs = nowMs;
            setState(() {
              _position = pos;
            });
          }
        } else {
          _position = pos;
        }
      }
    });

    _durationSubscription?.cancel();
    _durationSubscription = player.stream.duration.listen((dur) {
      if (!mounted || _disposed) return;
      if (_duration != dur) {
        setState(() {
          _duration = dur;
        });
      }
    });

    _playingSubscription?.cancel();
    _playingSubscription = player.stream.playing.listen((playing) {
      if (!mounted || _disposed) return;
      if (_isPlaying != playing) {
        setState(() {
          _isPlaying = playing;
        });
        if (playing) {
          _startHideTimer();
        }
      }
    });

    _bufferingSubscription?.cancel();
    _bufferingSubscription = player.stream.buffering.listen((buffering) {
      if (!mounted || _disposed) return;
      if (_isBuffering != buffering) {
        setState(() {
          _isBuffering = buffering;
        });
      }
    });

    _errorSubscription?.cancel();
    _errorSubscription = player.stream.error.listen((err) {
      if (!mounted || _disposed) return;
      debugPrint('[Player] media_kit stream error: $err');
      _handlePlayerRuntimeError(err);
    });

    _tracksSubscription?.cancel();
    _tracksSubscription = player.stream.tracks.listen((tracks) {
      if (!mounted || _disposed) return;
      final updatedSubs = List<SubtitleTrack>.from(_availableSubtitles);
      for (final st in tracks.subtitle) {
        if (st.id != 'no' && st.id != 'auto') {
          final embeddedUrl = 'embedded://${st.id}';
          if (!updatedSubs.any((s) => s.url == embeddedUrl)) {
            final title = st.title?.trim();
            final lang = st.language?.trim();
            final label = title != null && title.isNotEmpty
                ? '$title (Embedded)'
                : (lang != null && lang.isNotEmpty ? '${lang.toUpperCase()} (Embedded)' : 'Track ${st.id} (Embedded)');
            updatedSubs.add(SubtitleTrack(
              url: embeddedUrl,
              label: label,
              language: lang ?? 'und',
            ));
          }
        }
      }

      setState(() {
        _availableAudioTracks = tracks.audio;
        _availableSubtitles = updatedSubs;
      });

      if (!_userExplicitlyDisabledSubtitles && _selectedSubtitle == null && updatedSubs.isNotEmpty) {
        final englishSub = updatedSubs.firstWhere(
          (s) => s.label.toLowerCase().contains('english') || s.language.toLowerCase().startsWith('en'),
          orElse: () => updatedSubs.first,
        );
        _selectSubtitle(englishSub, showToast: false);
      }
    });

    _trackSubscription?.cancel();
    _trackSubscription = player.stream.track.listen((track) {
      if (!mounted || _disposed) return;
      if (_selectedAudioTrack != track.audio) {
        setState(() {
          _selectedAudioTrack = track.audio;
        });
      }
    });
  }

  void _updateSubtitleCue(Duration pos) {
    if (_subtitleCues.isEmpty) {
      if (_currentSubtitleText != null) {
        setState(() => _currentSubtitleText = null);
      }
      return;
    }

    // O(1) fast-path: test current cue or next adjacent cue
    if (_lastSubtitleCueIndex >= 0 && _lastSubtitleCueIndex < _subtitleCues.length) {
      final cue = _subtitleCues[_lastSubtitleCueIndex];
      if (pos >= cue.start && pos <= cue.end) {
        if (_currentSubtitleText != cue.text) {
          setState(() => _currentSubtitleText = cue.text);
        }
        return;
      }
      if (_lastSubtitleCueIndex + 1 < _subtitleCues.length) {
        final next = _subtitleCues[_lastSubtitleCueIndex + 1];
        if (pos >= next.start && pos <= next.end) {
          _lastSubtitleCueIndex++;
          if (_currentSubtitleText != next.text) {
            setState(() => _currentSubtitleText = next.text);
          }
          return;
        }
      }
    }

    // Binary search fallback for seeks / jumps across timeline
    int low = 0;
    int high = _subtitleCues.length - 1;
    SubtitleCue? activeCue;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final cue = _subtitleCues[mid];
      if (pos >= cue.start && pos <= cue.end) {
        activeCue = cue;
        _lastSubtitleCueIndex = mid;
        break;
      } else if (pos < cue.start) {
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    final newText = activeCue?.text;
    if (newText != _currentSubtitleText) {
      setState(() {
        _currentSubtitleText = newText;
      });
    }
  }

  Future<void> _handlePlayerRuntimeError(String? errorDescription) async {
    if (_isRecovering || _disposed || !mounted) return;
    _isRecovering = true;
    _hideControlsTimer?.cancel();

    debugPrint('[Player] Detected player runtime error: $errorDescription');
    setState(() {
      _showControls = true;
    });

    if (errorDescription?.contains('Could not open codec') == true) {
      // 1. If lower resolutions are available, try the next lower one
      final currentIdx =
          _availableQualities.indexWhere((q) => q.url == _currentQuality?.url);
      if (currentIdx >= 0 && currentIdx < _availableQualities.length - 1) {
        final nextLower = _availableQualities[currentIdx + 1];
        _showHudMessage('Resolution unsupported. Trying ${nextLower.label}...');
        await _switchQuality(nextLower);
        _isRecovering = false;
        return;
      }

      // 2. If hardware decoding failed on this stream (e.g. 10-bit HEVC / Dolby Vision),
      // fall back to FFmpeg software decoding.
      final native = _player?.platform;
      if (native is NativePlayer && !_triedSoftwareFallback) {
        _triedSoftwareFallback = true;
        _showHudMessage('Hardware codec failed. Switching to software decoder...');
        try {
          await native.setProperty('hwdec', 'no');
        } catch (_) {}
        await _recoverPlayerAtPosition(_lastKnownPosition);
        _isRecovering = false;
        return;
      }
    }

    final isStreamOpenFailure = errorDescription?.contains('Failed to open') == true ||
        errorDescription?.contains('403') == true ||
        errorDescription?.contains('HTTP error') == true ||
        errorDescription?.contains('Cannot open') == true;

    if (isStreamOpenFailure) {
      _showHudMessage('${_currentServer.name} stream error. Auto-switching to next server...');
      _isRecovering = false;
      _switchToNextServer();
      return;
    }

    if (_errorRecoveryAttempts < 1) {
      _errorRecoveryAttempts++;
      _showHudMessage('Playback interrupted. Reconnecting stream...');
      await _recoverPlayerAtPosition(_lastKnownPosition);
      _isRecovering = false;
    } else {
      _isRecovering = false;
      _showHudMessage('${_currentServer.name} stream interrupted. Trying next server...');
      _switchToNextServer();
    }
  }

  Future<void> _recoverPlayerAtPosition(Duration targetPos) async {
    if (_disposed || !mounted) return;

    final currentStream = _currentExtractedStream;
    final qualityUrl = _currentQuality?.url ?? currentStream?.url;
    final headers = currentStream?.headers ?? {};

    if (qualityUrl == null || qualityUrl.isEmpty) {
      _initStream(preferredServer: _currentServer, allowAutoFallback: false);
      return;
    }

    setState(() {
      _isExtracting = true;
      _statusTitle = 'Restoring playback...';
      _statusSubtitle = 'Reconnecting at ${_formatDuration(targetPos)}';
      _playerErrorMessage = null;
    });

    try {
      _ensurePlayerInitialized();

      if (_triedSoftwareFallback) {
        final native = _player?.platform;
        if (native is NativePlayer) {
          try {
            await native.setProperty('hwdec', 'no');
          } catch (_) {}
        }
      }

      await _player!.open(
        Media(
          qualityUrl,
          httpHeaders: headers,
          start: targetPos > Duration.zero ? targetPos : null,
        ),
        play: true,
      );
      _player!.setVolume((_volume * 100.0).clamp(0.0, 100.0));

      setState(() {
        _isExtracting = false;
        _playerErrorMessage = null;
      });
      _startHideTimer();
    } catch (e) {
      debugPrint('[Player] Failed to restore stream: $e');
      if (!mounted || _disposed) return;
      setState(() {
        _isExtracting = false;
        _playerErrorMessage =
            'Could not restore playback. Tap Reload to try again or switch server.';
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
    if (_currentQuality?.url == quality.url && _player != null) {
      return;
    }
    final player = _player;
    if (player == null) return;

    final currentPos = _lastKnownPosition > Duration.zero ? _lastKnownPosition : _position;
    final wasPlaying = _isPlaying;
    final currentHeaders = _currentExtractedStream?.headers ?? {};

    setState(() {
      _currentQuality = quality;
      _isExtracting = true;
      _statusTitle = 'Switching to ${quality.label}...';
      _statusSubtitle = 'Applying video resolution';
    });

    try {
      await player.open(
        Media(
          quality.url,
          httpHeaders: currentHeaders,
          start: currentPos > Duration.zero ? currentPos : null,
        ),
        play: wasPlaying,
      );
      if (!mounted || _disposed) return;
      setState(() {
        _isExtracting = false;
        _videoRenderKeyIndex++;
      });
      _showHudMessage('Quality: ${quality.label}');
    } catch (e) {
      debugPrint('[Player] Failed to load quality ${quality.label}: $e');
      if (!mounted || _disposed) return;
      _showHudMessage('${quality.label} failed, reloading current server...');
      _initStream(preferredServer: _currentServer, allowAutoFallback: false);
    }
  }

  Future<void> _selectSubtitle(SubtitleTrack? track, {bool showToast = true}) async {
    if (track == null) {
      _userExplicitlyDisabledSubtitles = true;
      setState(() {
        _selectedSubtitle = null;
        _subtitleCues = [];
        _currentSubtitleText = null;
      });
      try {
        _player?.setSubtitleTrack(mk.SubtitleTrack.no());
      } catch (_) {}
      if (showToast) _showHudMessage('Subtitles: Off');
      return;
    }

    _userExplicitlyDisabledSubtitles = false;
    setState(() {
      _selectedSubtitle = track;
      if (showToast) _showHudMessage('Subtitles: ${track.label}');
    });

    if (track.url.startsWith('embedded://')) {
      final trackId = track.url.replaceFirst('embedded://', '');
      try {
        final subTracks = _player?.state.tracks.subtitle ?? [];
        final target = subTracks.firstWhere(
          (t) => t.id == trackId,
          orElse: () => mk.SubtitleTrack.no(),
        );
        _player?.setSubtitleTrack(target);
      } catch (e) {
        debugPrint('[Player] Error setting embedded subtitle track: $e');
      }
      setState(() {
        _subtitleCues = [];
        _currentSubtitleText = null;
      });
      return;
    }

    // External WebVTT track: disable internal subtitles so they don't collide
    try {
      _player?.setSubtitleTrack(mk.SubtitleTrack.no());
    } catch (_) {}

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

  Future<void> _disposePlayer({bool saveProgress = false}) async {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;

    final p = _player;
    _player = null;
    _videoController = null;

    _positionSubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription?.cancel();
    _durationSubscription = null;
    _playingSubscription?.cancel();
    _playingSubscription = null;
    _bufferingSubscription?.cancel();
    _bufferingSubscription = null;
    _errorSubscription?.cancel();
    _errorSubscription = null;
    _tracksSubscription?.cancel();
    _tracksSubscription = null;
    _trackSubscription?.cancel();
    _trackSubscription = null;

    if (p != null) {
      if (saveProgress) {
        final pos = (_lastKnownPosition > Duration.zero)
            ? _lastKnownPosition.inSeconds
            : _position.inSeconds;
        if (pos > 0) {
          try {
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
      }
      try {
        await p.stop();
        await p.dispose();
      } catch (e) {
        debugPrint('[Player] Error disposing player: $e');
      }
    }
  }

  void _cleanUp() {
    if (_isCleanedUp) return;
    _isCleanedUp = true;
    _disposed = true;

    _hideControlsTimer?.cancel();
    _gestureHudTimer?.cancel();
    _hudMessageTimer?.cancel();

    // 1. Save progress and stop native video immediately
    _disposePlayer(saveProgress: true);

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

    // 1. Immediately halt previous playback, demuxer & background downloading
    await _disposePlayer(saveProgress: false);

    // 2. Clear all subtitles & cues so no cross-server subtitle pollution occurs
    _availableSubtitles = [];
    _selectedSubtitle = null;
    _subtitleCues = [];
    _currentSubtitleText = null;
    _availableAudioTracks = [];
    _selectedAudioTrack = null;

    // 3. Increment video render key so Flutter mounts a completely fresh Video texture
    _videoRenderKeyIndex++;

    final targetServer = preferredServer ?? _currentServer;
    final itemTitle = widget.item.title;

    if (!mounted || _disposed || gen != _generation) return;

    setState(() {
      _currentServer = targetServer;
      _isExtracting = true;
      _extractionError = null;
      _statusTitle = 'Loading $itemTitle...';
      _statusSubtitle = 'Connecting to ${_currentServer.name}...';
      _currentSubtitleText = null;
      _position = Duration.zero;
      _lastKnownPosition = Duration.zero;
    });

    final startIndex = StreamServers.all.indexWhere((s) => s.id == targetServer.id);
    final effectiveIndex = startIndex >= 0 ? startIndex : 0;
    final serverQueue = allowAutoFallback
        ? List.generate(
            StreamServers.all.length,
            (i) => StreamServers.all[(effectiveIndex + i) % StreamServers.all.length],
          )
        : [targetServer];

    _triedSoftwareFallback = false;
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

      final stream = await StreamExtractor.instance.extractSingleServer(
        server: candidate,
        tmdbId: widget.item.id,
        type: widget.item.mediaType,
        title: widget.item.title,
        year: int.tryParse(widget.item.year),
        season: _season,
        episode: _episode,
        timeout: const Duration(seconds: 8),
      );

      if (!mounted || _disposed || gen != _generation) return;

      if (stream == null) {
        debugPrint('[Player] <<< Server [${candidate.name}] failed or returned null');
        if (i < serverQueue.length - 1) {
          setState(() {
            _statusSubtitle =
                '${candidate.name} could not load stream. Trying next server...';
          });
        }
        continue;
      }

      debugPrint('[Player] <<< Server [${candidate.name}] extracted URL: ${stream.url} (isHls: ${stream.isHls})');
      debugPrint('[Player] <<< Server [${candidate.name}] headers: ${stream.headers}');

      setState(() {
        _statusSubtitle = 'Preparing video player...';
        _currentExtractedStream = stream;
      });

      try {
        _ensurePlayerInitialized();

        String playableUrl = stream.url;
        List<StreamQuality> qualities = [];
        List<SubtitleTrack> subtitles = [...stream.subtitles];

        // For HLS streams (e.g. VidFast), inspect master playlist to filter out
        // unplayable oversized variants (4K 3840x1600 or 2592x1080) and select the highest safe variant (1080p/720p).
        if (stream.isHls) {
          try {
            final hlsInfo = await HlsAndSubtitleHelper.inspectHlsStream(
              url: stream.url,
              headers: stream.headers,
            );
            if (hlsInfo.qualities.isNotEmpty) {
              qualities = hlsInfo.qualities;
              // Crucial: Select the highest safe variant (<= 2048x1200) so Qualcomm MediaCodec doesn't crash on 4K/3840p
              playableUrl = qualities.first.url;
            }
            if (hlsInfo.subtitles.isNotEmpty) {
              subtitles = [
                ...subtitles,
                ...hlsInfo.subtitles.where(
                  (hs) => !subtitles.any((s) => s.url == hs.url),
                ),
              ];
            }
          } catch (e) {
            debugPrint('[Player] inspectHlsStream error: $e');
          }
        } else {
          qualities = stream.qualities.isNotEmpty
              ? stream.qualities
              : [
                  StreamQuality(
                    label: stream.quality.isNotEmpty ? stream.quality : 'Source',
                    url: stream.url,
                  ),
                ];
        }

        // Resume playback position if saved for this specific media & episode
        Duration? startPos;
        final saved = (widget.item.mediaType == MediaType.tv)
            ? (_storage.getWatchProgress(
                    widget.item.id,
                    widget.item.mediaType,
                    season: _season,
                    episode: _episode,
                  ) ??
                  _storage.getWatchProgress(
                    widget.item.id,
                    widget.item.mediaType,
                  ))
            : _storage.getWatchProgress(
                widget.item.id,
                widget.item.mediaType,
              );
        if (saved != null && saved['positionSeconds'] is int) {
          final isSameEp = widget.item.mediaType != MediaType.tv ||
              (saved['season'] == _season && saved['episode'] == _episode);
          if (isSameEp) {
            final pos = saved['positionSeconds'] as int;
            if (pos > 10) {
              startPos = Duration(seconds: pos);
              _lastKnownPosition = startPos;
            }
          }
        }

        // Open media through media_kit. httpHeaders are handled natively by libmpv on_load hook.
        await _player!.open(
          Media(
            playableUrl,
            httpHeaders: stream.headers,
            start: startPos,
          ),
          play: true,
        );
        _player!.setVolume((_volume * 100.0).clamp(0.0, 100.0));

        // Fast-fail check: verify stream does not immediately fail (e.g. HTTP 403 Forbidden on broken link)
        final playCompleter = Completer<bool>();
        final errorSub = _player!.stream.error.listen((err) {
          if (!playCompleter.isCompleted) {
            debugPrint('[Player] Immediate stream error for [${candidate.name}]: $err');
            playCompleter.complete(false);
          }
        });
        final playSub = _player!.stream.playing.listen((isPlaying) {
          if (isPlaying && !playCompleter.isCompleted) {
            playCompleter.complete(true);
          }
        });
        final posSub = _player!.stream.position.listen((pos) {
          if (pos > Duration.zero && !playCompleter.isCompleted) {
            playCompleter.complete(true);
          }
        });

        final openOk = await playCompleter.future.timeout(
          const Duration(milliseconds: 1800),
          onTimeout: () => true,
        );

        await errorSub.cancel();
        await playSub.cancel();
        await posSub.cancel();

        if (!openOk) {
          throw Exception('Stream URL rejected by player (HTTP 403 / unplayable link) for [${candidate.name}]');
        }

        if (!mounted || _disposed || gen != _generation) return;

        setState(() {
          _isExtracting = false;
          _availableQualities = qualities.isNotEmpty
              ? qualities
              : [StreamQuality(label: 'Source', url: playableUrl)];
          _currentQuality = _availableQualities.first;
          _availableSubtitles = subtitles;
        });

        if (!_userExplicitlyDisabledSubtitles && _selectedSubtitle == null && subtitles.isNotEmpty) {
          final englishSub = subtitles.firstWhere(
            (s) => s.label.toLowerCase().contains('english'),
            orElse: () => subtitles.first,
          );
          _selectSubtitle(englishSub, showToast: false);
        }

        _startHideTimer();
        debugPrint('[Player] media_kit initialized and playing successfully for [${candidate.name}]');

        // Periodic progress saving every 10 seconds
        _progressSaveTimer?.cancel();
        _progressSaveTimer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _saveProgress(),
        );

        streamStarted = true;
        break;
      } catch (e, st) {
        debugPrint('[Player] media_kit error for [${candidate.name}]: $e\n$st');
        if (!mounted || _disposed || gen != _generation) return;
        await _disposePlayer(saveProgress: false);
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
      await _disposePlayer(saveProgress: false);
      setState(() {
        _isExtracting = false;
        _extractionError = allowAutoFallback
            ? 'We couldn\'t load this title right now across available servers. Please try again or switch servers manually.'
            : '${targetServer.name} could not play this title. Please try another server or retry.';
      });
    }
  }

  void _saveProgress() {
    final pos = (_lastKnownPosition > Duration.zero)
        ? _lastKnownPosition.inSeconds
        : _position.inSeconds;
    if (pos <= 0) return;
    try {
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
        _player != null) {
      return;
    }
    _saveProgress();
    _initStream(preferredServer: server, allowAutoFallback: allowAutoFallback);
  }

  void _switchToNextServer() {
    final currentIndex = StreamServers.all.indexWhere((s) => s.id == _currentServer.id);
    final nextIndex = (currentIndex + 1) % StreamServers.all.length;
    final nextServer = StreamServers.all[nextIndex];
    _switchServer(nextServer, allowAutoFallback: true);
  }

  void _changeEpisode(int ep) {
    if (ep < 1 || ep == _episode) return;
    _saveProgress();
    _disposePlayer(saveProgress: false);

    setState(() {
      _episode = ep;
      _position = Duration.zero;
      _lastKnownPosition = Duration.zero;
      _duration = Duration.zero;
      _availableSubtitles = [];
      _selectedSubtitle = null;
      _subtitleCues = [];
      _currentSubtitleText = null;
    });

    _initStream();
  }

  void _togglePlayPause() {
    final player = _player;
    if (player == null) return;

    if (_playerErrorMessage != null) {
      _recoverPlayerAtPosition(_lastKnownPosition);
      return;
    }

    player.playOrPause();
    if (!_isPlaying) {
      _startHideTimer();
    } else {
      setState(() => _showControls = true);
      _hideControlsTimer?.cancel();
    }
  }

  Future<void> _safeSeekTo(Duration target) async {
    final player = _player;
    if (player == null) return;

    final max = _duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (max > Duration.zero && target > max ? max : target);

    _lastKnownPosition = clamped;
    _lastSubtitleCueIndex = 0;
    final reqId = ++_seekRequestId;

    setState(() {
      _position = clamped;
      _isSeeking = true;
    });

    try {
      await player.seek(clamped).timeout(const Duration(seconds: 4));
      _startHideTimer();
    } catch (e) {
      debugPrint('[Player] Seek completed or timed out: $e');
    } finally {
      if (mounted && reqId == _seekRequestId) {
        setState(() {
          _isSeeking = false;
        });
      }
    }
  }

  void _seekRelative(int seconds) {
    final player = _player;
    if (player == null) return;
    final current = _isDraggingSlider && _dragSliderValueMs != null
        ? Duration(milliseconds: _dragSliderValueMs!.toInt())
        : (_lastKnownPosition > Duration.zero ? _lastKnownPosition : _position);
    final target = current + Duration(seconds: seconds);
    _safeSeekTo(target);
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          _player != null &&
          _isPlaying &&
          !_isBuffering &&
          !_isDraggingSlider &&
          _playerErrorMessage == null) {
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
      final newBrightness = (_brightness + delta).clamp(0.0, 1.0);
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
      _player?.setVolume((newVol * 100.0).clamp(0.0, 100.0));
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_gestureHudType == GestureHudType.volume) {
      try {
        VolumeController.instance.setVolume(_volume);
      } catch (_) {}
      _player?.setVolume((_volume * 100.0).clamp(0.0, 100.0));
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
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final screenHeight = MediaQuery.of(ctx).size.height;
        return SizedBox(
          height: screenHeight * 0.88,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
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
                  Expanded(
                    child: ListView.builder(
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
          ),
        );
      },
    );
  }

  void _showQualitySelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final screenHeight = MediaQuery.of(ctx).size.height;
        return SizedBox(
          height: screenHeight * 0.85,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
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
                  Expanded(
                    child: ListView.builder(
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
          ),
        );
      },
    );
  }

  void _showSubtitleSelector() {
    final displaySubtitles = <SubtitleTrack>[..._availableSubtitles];
    final selected = _selectedSubtitle;
    if (selected != null &&
        !displaySubtitles.any((s) => s.url == selected.url)) {
      displaySubtitles.insert(0, selected);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final screenHeight = MediaQuery.of(ctx).size.height;
        return SizedBox(
          height: screenHeight * 0.88,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
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
                      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Text(
                        'No subtitles provided by this server',
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (displaySubtitles.isNotEmpty)
                    Expanded(
                      child: ListView.builder(
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
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.secondary,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                sub.language.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
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
          ),
        );
      },
    );
  }

  String _formatAudioTrackName(AudioTrack track, int index) {
    if (track.title != null && track.title!.trim().isNotEmpty) {
      return track.title!.trim();
    }
    if (track.language != null && track.language!.trim().isNotEmpty) {
      return 'Audio ${index + 1} (${track.language!.toUpperCase()})';
    }
    if (track.id == 'auto') return 'Auto (Default)';
    if (track.id == 'no') return 'Disabled';
    return 'Audio Track ${index + 1}';
  }

  Future<void> _selectAudioTrack(AudioTrack track) async {
    final player = _player;
    if (player == null) return;
    try {
      await player.setAudioTrack(track);
      setState(() {
        _selectedAudioTrack = track;
      });
      final name = _formatAudioTrackName(track, 0);
      _showHudMessage('Audio: $name');
    } catch (e) {
      debugPrint('[Player] Failed to select audio track: $e');
    }
  }

  void _showAudioTrackSelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final screenHeight = MediaQuery.of(ctx).size.height;
        return SizedBox(
          height: screenHeight * 0.85,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
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
                          Icons.audiotrack,
                          size: 18,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Audio Track',
                          style: Theme.of(ctx).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: AppColors.border),
                  if (_availableAudioTracks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: Text(
                        'Default audio stream (No alternative tracks)',
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (_availableAudioTracks.isNotEmpty)
                    Expanded(
                      child: ListView.builder(
                        itemCount: _availableAudioTracks.length,
                        itemBuilder: (_, idx) {
                          final track = _availableAudioTracks[idx];
                          final isSelected = (_selectedAudioTrack?.id == track.id) ||
                              (_selectedAudioTrack == null && idx == 0);
                          final trackName = _formatAudioTrackName(track, idx);

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
                              trackName,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.foreground,
                              ),
                            ),
                            trailing: track.language != null
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.secondary,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: AppColors.border),
                                    ),
                                    child: Text(
                                      track.language!.toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.mutedForeground,
                                      ),
                                    ),
                                  )
                                : null,
                            onTap: () async {
                              Navigator.of(ctx).pop();
                              await _selectAudioTrack(track);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoPlayerWidget(VideoController controller) {
    BoxFit fit;
    switch (_aspectRatioMode) {
      case PlayerAspectRatio.fit:
        fit = BoxFit.contain;
        break;
      case PlayerAspectRatio.zoom:
        fit = BoxFit.cover;
        break;
      case PlayerAspectRatio.stretch:
        fit = BoxFit.fill;
        break;
      case PlayerAspectRatio.sixteenNine:
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(
              key: ValueKey('video_surface_$_videoRenderKeyIndex'),
              controller: controller,
              controls: NoVideoControls,
              fit: BoxFit.fill,
            ),
          ),
        );
      case PlayerAspectRatio.fourThree:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Video(
              key: ValueKey('video_surface_$_videoRenderKeyIndex'),
              controller: controller,
              controls: NoVideoControls,
              fit: BoxFit.fill,
            ),
          ),
        );
    }

    return Video(
      key: ValueKey('video_surface_$_videoRenderKeyIndex'),
      controller: controller,
      controls: NoVideoControls,
      fit: fit,
    );
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
    final controller = _videoController;
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
                  if (controller != null)
                    _buildVideoPlayerWidget(controller)
                  else if (!_isExtracting && _extractionError == null)
                    const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    ),

                  // 3. Buffering Overlay
                  if (_isBuffering && !_isSeeking && _playerErrorMessage == null)
                    Center(
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
                            color: Colors.white,
                          ),
                        ),
                      ),
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
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/images/app_logo.png',
                                height: 52,
                                width: 52,
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(height: 18),
                            const SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                color: AppColors.primary,
                                strokeWidth: 3,
                              ),
                            ),
                            const SizedBox(height: 20),
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

                  // 9.5 In-Player Codec / Runtime Error Overlay
                  if (_playerErrorMessage != null)
                    Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              LucideIcons.alertTriangle,
                              size: 48,
                              color: AppColors.primarySoft,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _playerErrorMessage!,
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
                                  onPressed: () =>
                                      _recoverPlayerAtPosition(_lastKnownPosition),
                                  icon: const Icon(
                                    LucideIcons.rotateCw,
                                    size: 16,
                                  ),
                                  label: const Text('Reload Stream'),
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
                  if (controller != null)
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
                                          // Audio Track button
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.all(4),
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            icon: Icon(
                                              Icons.audiotrack,
                                              color: _availableAudioTracks.length > 1
                                                  ? AppColors.primary
                                                  : Colors.white,
                                              size: 18,
                                            ),
                                            tooltip: 'Audio Track',
                                            onPressed: _showAudioTrackSelector,
                                          ),
                                          const SizedBox(width: 4),

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
                                  if (_playerErrorMessage != null)
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black.withValues(alpha: 0.45),
                                      ),
                                      child: IconButton(
                                        iconSize: 44,
                                        icon: const Icon(
                                          LucideIcons.rotateCw,
                                          color: Colors.white,
                                        ),
                                        tooltip: 'Reload Stream',
                                        onPressed: () =>
                                            _recoverPlayerAtPosition(_lastKnownPosition),
                                      ),
                                    )
                                  else if (!_isBuffering || _isSeeking)
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black.withValues(
                                          alpha: 0.45,
                                        ),
                                      ),
                                      child: IconButton(
                                        iconSize: 52,
                                        icon: Icon(
                                          _isPlaying
                                              ? LucideIcons.pause
                                              : LucideIcons.play,
                                          color: Colors.white,
                                        ),
                                        onPressed: _togglePlayPause,
                                      ),
                                    )
                                  else
                                    const SizedBox(width: 64, height: 64),
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
                                      // Slider Seekbar with Aspect Ratio button next to the timer
                                      Builder(
                                        builder: (context) {
                                          final max = _duration.inMilliseconds.toDouble();
                                          final current = _position.inMilliseconds
                                              .toDouble()
                                              .clamp(0.0, max > 0 ? max : 1.0);
                                          final displayPos = _isDraggingSlider &&
                                                  _dragSliderValueMs != null
                                              ? _dragSliderValueMs!.clamp(
                                                  0.0, max > 0 ? max : 1.0)
                                              : current;
                                          return Row(
                                            children: [
                                              Text(
                                                _formatDuration(
                                                  _isDraggingSlider &&
                                                          _dragSliderValueMs !=
                                                              null
                                                      ? Duration(
                                                          milliseconds:
                                                              _dragSliderValueMs!
                                                                  .toInt(),
                                                        )
                                                      : _position,
                                                ),
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
                                                        ? displayPos
                                                        : 0.0,
                                                    min: 0.0,
                                                    max: max > 0 ? max : 1.0,
                                                    onChangeStart: (pos) {
                                                      _hideControlsTimer?.cancel();
                                                      setState(() {
                                                        _isDraggingSlider = true;
                                                        _dragSliderValueMs = pos;
                                                      });
                                                    },
                                                    onChanged: (pos) {
                                                      setState(() {
                                                        _dragSliderValueMs = pos;
                                                      });
                                                    },
                                                    onChangeEnd: (pos) {
                                                      setState(() {
                                                        _isDraggingSlider = false;
                                                        _dragSliderValueMs = null;
                                                      });
                                                      _safeSeekTo(
                                                        Duration(
                                                          milliseconds:
                                                              pos.toInt(),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                _formatDuration(_duration),
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

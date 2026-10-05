import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_theme.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/stream_server.dart';
import '../services/storage_service.dart';
import '../services/streaming/stream_extractor.dart';

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

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  VideoPlayerController? _playerController;
  late StreamServer _currentServer;
  late int _season;
  late int _episode;

  bool _isExtracting = true;
  String? _extractionError;
  bool _showControls = true;
  bool _isLandscape = false;
  Timer? _hideControlsTimer;
  Timer? _progressSaveTimer;

  @override
  void initState() {
    super.initState();
    _season = widget.initialSeason;
    _episode = widget.initialEpisode;

    // Load saved preferences
    final storage = ref.read(storageServiceProvider);
    final saved = storage.getWatchProgress(widget.item.id, widget.item.mediaType);
    if (saved != null && saved['serverId'] is String) {
      _currentServer = StreamServers.byId(saved['serverId'] as String);
    } else {
      _currentServer = StreamServers.all.first;
    }

    // Keep screen awake during playback
    WakelockPlus.enable();

    // Orientations
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _initStream();
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _progressSaveTimer?.cancel();
    _saveProgress();
    _playerController?.dispose();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initStream() async {
    setState(() {
      _isExtracting = true;
      _extractionError = null;
    });

    await _playerController?.dispose();
    _playerController = null;

    final stream = await StreamExtractor.instance.extractStream(
      tmdbId: widget.item.id,
      type: widget.item.mediaType,
      server: _currentServer,
      season: _season,
      episode: _episode,
    );

    if (!mounted) return;

    if (stream == null) {
      setState(() {
        _isExtracting = false;
        _extractionError = 'Could not extract direct stream from ${_currentServer.name}. Try switching servers.';
      });
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        httpHeaders: stream.headers,
      );

      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }

      setState(() {
        _playerController = controller;
        _isExtracting = false;
      });

      controller.play();
      _startHideTimer();

      // Periodic progress saving every 10 seconds
      _progressSaveTimer?.cancel();
      _progressSaveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _extractionError = 'Playback error: Unable to load stream.';
      });
    }
  }

  void _saveProgress() {
    final pos = _playerController?.value.position.inSeconds ?? 0;
    ref.read(storageServiceProvider).saveWatchProgress(
          tmdbId: widget.item.id,
          type: widget.item.mediaType,
          serverId: _currentServer.id,
          season: _season,
          episode: _episode,
          positionSeconds: pos,
        );
  }

  void _switchServer(StreamServer server) {
    if (_currentServer.id == server.id && !_isExtracting && _playerController != null) return;
    setState(() {
      _currentServer = server;
    });
    _saveProgress();
    _initStream();
  }

  void _changeEpisode(int ep) {
    if (ep < 1) return;
    setState(() {
      _episode = ep;
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
        : (target > controller.value.duration ? controller.value.duration : target);
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

  void _toggleLandscape() {
    setState(() {
      _isLandscape = !_isLandscape;
    });
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.server, size: 18, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Text(
                        'Select Video Server',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: AppColors.border),
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
                          backgroundColor:
                              isSelected ? AppColors.primary : AppColors.secondary,
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              color: isSelected ? Colors.white : AppColors.foreground,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        title: Text(
                          s.name.toUpperCase(),
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected ? AppColors.primary : AppColors.foreground,
                          ),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.secondary,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            s.quality,
                            style: const TextStyle(fontSize: 11, color: AppColors.mutedForeground),
                          ),
                        ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _switchServer(s);
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: !_isLandscape,
        bottom: !_isLandscape,
        child: GestureDetector(
          onTap: () {
            setState(() => _showControls = !_showControls);
            if (_showControls) _startHideTimer();
          },
          behavior: HitTestBehavior.opaque,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Native Video Surface
              if (controller != null && controller.value.isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                )
              else if (!_isExtracting && _extractionError == null)
                const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),

              // 2. Extraction Loading Overlay
              if (_isExtracting)
                Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: AppColors.primary,
                          strokeWidth: 3,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Connecting to ${_currentServer.name}...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Extracting native HLS stream',
                          style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),

              // 3. Error Overlay
              if (_extractionError != null)
                Container(
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(LucideIcons.videoOff, size: 48, color: AppColors.primarySoft),
                        const SizedBox(height: 16),
                        Text(
                          _extractionError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: _initStream,
                              icon: const Icon(LucideIcons.rotateCw, size: 16),
                              label: const Text('Retry'),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              onPressed: _showServerSelector,
                              icon: const Icon(LucideIcons.server, size: 16),
                              label: const Text('Change Server'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              // 4. Custom Cinema Controls Overlay
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
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.black87, Colors.transparent],
                              ),
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(LucideIcons.arrowLeft, color: Colors.white, size: 22),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
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
                                            color: AppColors.mutedForeground,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _showServerSelector,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: AppColors.secondary,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: AppColors.primarySoft),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(LucideIcons.server, size: 13, color: AppColors.primary),
                                        const SizedBox(width: 5),
                                        Text(
                                          _currentServer.name.toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        const Icon(LucideIcons.chevronDown, size: 13, color: Colors.white70),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    _isLandscape ? LucideIcons.minimize2 : LucideIcons.maximize2,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  onPressed: _toggleLandscape,
                                ),
                              ],
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
                                icon: const Icon(LucideIcons.rotateCcw, color: Colors.white),
                                onPressed: () => _seekRelative(-10),
                              ),
                              const SizedBox(width: 36),
                              Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withValues(alpha: 0.9),
                                ),
                                child: IconButton(
                                  iconSize: 48,
                                  icon: Icon(
                                    controller.value.isPlaying
                                        ? LucideIcons.pause
                                        : LucideIcons.play,
                                    color: Colors.white,
                                  ),
                                  onPressed: _togglePlayPause,
                                ),
                              ),
                              const SizedBox(width: 36),
                              IconButton(
                                iconSize: 36,
                                icon: const Icon(LucideIcons.rotateCw, color: Colors.white),
                                onPressed: () => _seekRelative(10),
                              ),
                            ],
                          ),
                        ),

                        // Bottom Bar: Scrubber + Timing + TV Controls
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.black87, Colors.transparent],
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Slider Seekbar
                                ValueListenableBuilder<VideoPlayerValue>(
                                  valueListenable: controller,
                                  builder: (context, val, _) {
                                    final max = val.duration.inMilliseconds.toDouble();
                                    final current = val.position.inMilliseconds.toDouble().clamp(0.0, max);
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
                                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                              activeTrackColor: AppColors.primary,
                                              inactiveTrackColor: Colors.white24,
                                              thumbColor: AppColors.primary,
                                            ),
                                            child: Slider(
                                              value: max > 0 ? current : 0.0,
                                              min: 0.0,
                                              max: max > 0 ? max : 1.0,
                                              onChanged: (pos) {
                                                controller.seekTo(Duration(milliseconds: pos.toInt()));
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
                                      ],
                                    );
                                  },
                                ),

                                // TV Episodes Next / Prev
                                if (isTv) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      TextButton.icon(
                                        onPressed: _episode > 1 ? () => _changeEpisode(_episode - 1) : null,
                                        icon: const Icon(LucideIcons.chevronLeft, size: 16),
                                        label: const Text('Prev Episode'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: _episode > 1 ? Colors.white : Colors.white24,
                                        ),
                                      ),
                                      Text(
                                        'Episode $_episode',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () => _changeEpisode(_episode + 1),
                                        icon: const Icon(LucideIcons.chevronRight, size: 16),
                                        label: const Text('Next Episode'),
                                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

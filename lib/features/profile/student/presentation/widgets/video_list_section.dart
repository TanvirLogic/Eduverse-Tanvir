import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:edtech/global/core/providers/video_player_provider.dart';
import '../../data/entities/user_profile_entity.dart';
import 'video_player_screen.dart';

bool _isVideoUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.mkv');
}

class VideosHorizontalListView extends StatefulWidget {
  final List<ProfileVideo> videos;

  const VideosHorizontalListView({super.key, required this.videos});

  @override
  State<VideosHorizontalListView> createState() =>
      _VideosHorizontalListViewState();
}

class _VideosHorizontalListViewState extends State<VideosHorizontalListView> {
  int _activeIndex = -1;
  bool _showControls = true;
  Timer? _controlHideTimer;

  final Map<int, Uint8List> _thumbnailCache = {};

  @override
  void initState() {
    super.initState();
    _generateThumbnails();
  }

  @override
  void didUpdateWidget(VideosHorizontalListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videos != widget.videos) {
      _thumbnailCache.clear();
      _generateThumbnails();
    }
  }

  @override
  void dispose() {
    _controlHideTimer?.cancel();
    context.read<VideoPlayerProvider>().dismiss();
    super.dispose();
  }

  Future<void> _generateThumbnails() async {
    for (int i = 0; i < widget.videos.length; i++) {
      if (_thumbnailCache.containsKey(i)) continue;
      if (!_isVideoUrl(widget.videos[i].video)) continue;

      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: widget.videos[i].video,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 218,
          quality: 80,
        );
        if (bytes != null && mounted) {
          _thumbnailCache[i] = bytes;
          setState(() {});
        }
      } catch (_) {}
    }
  }

  void _startControlHideTimer() {
    _controlHideTimer?.cancel();
    _controlHideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      try {
        final provider = context.read<VideoPlayerProvider>();
        if (provider.isPlaying) {
          setState(() => _showControls = false);
        }
      } catch (_) {
        // Timer callback fired during widget deactivation — safe to ignore.
        // The element's internal widget reference is null even though
        // mounted is true, so context.read<VideoPlayerProvider>() throws.
        // This is harmless; controls just won't auto-hide this time.
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startControlHideTimer();
  }

  void _playAtIndex(int index) {
    if (index == _activeIndex) return;

    final video = widget.videos[index];
    if (!_isVideoUrl(video.video)) return;

    context.read<VideoPlayerProvider>().openVideo(
      url: video.video,
      title: video.title,
    );
    setState(() {
      _activeIndex = index;
      _showControls = true;
    });
    _startControlHideTimer();
  }

  void _stopActive() {
    context.read<VideoPlayerProvider>().dismiss();
    if (mounted) {
      setState(() {
        _activeIndex = -1;
        _showControls = true;
      });
    }
  }

  void _togglePlayPause() {
    context.read<VideoPlayerProvider>().togglePlayPause();
    if (mounted) {
      setState(() => _showControls = true);
      _startControlHideTimer();
    }
  }

  void _openFullScreen() {
    if (_activeIndex < 0) return;

    final video = widget.videos[_activeIndex];
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          videoUrl: video.video,
          title: video.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videos.isEmpty) return const SizedBox.shrink();

    final provider = context.watch<VideoPlayerProvider>();

    if (_activeIndex >= 0 && !provider.isActive && provider.currentVideoUrl == null) {
      Future.microtask(() {
        if (mounted) setState(() => _activeIndex = -1);
      });
    }

    return SizedBox(
      height: 71 + 8 + 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: widget.videos.length,
        itemBuilder: (context, index) {
          final video = widget.videos[index];
          final isLast = index == widget.videos.length - 1;
          final isActive = index == _activeIndex;
          return Padding(
            padding: EdgeInsets.only(right: isLast ? 0 : 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 109,
                  height: 71,
                  child: _VideoCard(
                    video: video,
                    thumbnailBytes: _thumbnailCache[index],
                    isActive: isActive,
                    isInitialized: isActive ? provider.isInitialized : false,
                    isPlaying: isActive ? provider.isPlaying : false,
                    hasError: isActive ? provider.hasError : false,
                    showControls: isActive ? _showControls : false,
                    videoController:
                        isActive && provider.isInitialized ? provider.controller : null,
                    onTap: () => _playAtIndex(index),
                    onPlayPause: isActive ? _togglePlayPause : null,
                    onFullScreen: isActive ? _openFullScreen : null,
                    onClose: isActive ? _stopActive : null,
                    onToggleControls: isActive ? _toggleControls : null,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 109,
                  child: Text(
                    video.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface,
                      letterSpacing: -0.1,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  final ProfileVideo video;
  final Uint8List? thumbnailBytes;
  final bool isActive;
  final bool isInitialized;
  final bool isPlaying;
  final bool hasError;
  final bool showControls;
  final VideoController? videoController;
  final VoidCallback onTap;
  final VoidCallback? onPlayPause;
  final VoidCallback? onFullScreen;
  final VoidCallback? onClose;
  final VoidCallback? onToggleControls;

  const _VideoCard({
    required this.video,
    this.thumbnailBytes,
    required this.isActive,
    required this.isInitialized,
    required this.isPlaying,
    required this.hasError,
    required this.showControls,
    required this.videoController,
    required this.onTap,
    this.onPlayPause,
    this.onFullScreen,
    this.onClose,
    this.onToggleControls,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 71,
      child: isActive ? _buildActivePlayer(cs) : _buildPlaceholder(cs),
    );
  }

  Widget _buildPlaceholder(ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cs.outlineVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailBytes != null)
              Image.memory(
                thumbnailBytes!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              )
            else
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.1),
                      Colors.black.withValues(alpha: 0.6),
                    ],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.4),
                  ],
                  stops: const [0.6, 1.0],
                ),
              ),
            ),
            Center(
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0xCC000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivePlayer(ColorScheme cs) {
    return GestureDetector(
      onTap: onToggleControls,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasError)
              const Center(
                child: Icon(
                  Icons.videocam_off,
                  color: Colors.white54,
                  size: 20,
                ),
              )
            else if (isInitialized && videoController != null)
              Video(
                controller: videoController!,
                fit: BoxFit.cover,
                controls: null,
              )
            else
              const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ),

            if (showControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Color(0x99000000),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 12,
                    ),
                  ),
                ),
              ),

              Center(
                child: GestureDetector(
                  onTap: onPlayPause,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: isPlaying ? 16 : 18,
                    ),
                  ),
                ),
              ),

              Positioned(
                bottom: 2,
                right: 2,
                child: GestureDetector(
                  onTap: onFullScreen,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Color(0x99000000),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.fullscreen,
                      color: Colors.white,
                      size: 12,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

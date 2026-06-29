import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:edtech/app/app_colors.dart';
import 'package:edtech/global/core/providers/video_player_provider.dart';
import 'package:edtech/global/core/services/logger_service.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  final String title;
  final Duration initialPosition;
  final int? lessonId;
  final int? courseId;
  final VoidCallback? onCompleted;
  final String? nextVideoUrl;
  final String? nextVideoTitle;

  const VideoPlayerScreen({
    super.key,
    required this.videoUrl,
    required this.title,
    this.initialPosition = Duration.zero,
    this.lessonId,
    this.courseId,
    this.onCompleted,
    this.nextVideoUrl,
    this.nextVideoTitle,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  Timer? _controlHideTimer;
  bool _showControls = true;
  bool _autoPlayNext = false;

  bool _isOrientationLocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        _enterFullScreen();
        final provider = context.read<VideoPlayerProvider>();

        final sameVideo = provider.currentVideoUrl == widget.videoUrl;
        if (!sameVideo || !provider.isActive) {
          await provider.openVideo(
            url: widget.videoUrl,
            title: widget.title,
            initialPosition: widget.initialPosition,
            lessonId: widget.lessonId,
            courseId: widget.courseId,
            onCompleted: () {
              widget.onCompleted?.call();
              _handleAutoPlayNext();
            },
            nextVideoUrl: widget.nextVideoUrl,
            nextVideoTitle: widget.nextVideoTitle,
          );
        } else {
          provider.seek(Duration.zero);
          if (!provider.isPlaying) {
            provider.play();
          }
        }
      } catch (e) {
        AppLogger.e('VideoPlayerScreen init: $e');
      }
    });
  }

  void _handleAutoPlayNext() {
    if (!_autoPlayNext || widget.nextVideoUrl == null) return;
    try {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            videoUrl: widget.nextVideoUrl!,
            title: widget.nextVideoTitle ?? '',
            lessonId: widget.lessonId,
            courseId: widget.courseId,
            onCompleted: widget.onCompleted,
          ),
        ),
      );
    } catch (e) {
      AppLogger.e('_handleAutoPlayNext: $e');
    }
  }

  // void _toggleAutoPlayNext() {
  //   setState(() => _autoPlayNext = !_autoPlayNext);
  // }

  void _enterFullScreen() {
    try {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
  }

  void _exitFullScreen() {
    try {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  @override
  void dispose() {
    _controlHideTimer?.cancel();
    try {
      context.read<VideoPlayerProvider>().pause();
    } catch (_) {}
    _exitFullScreen();
    super.dispose();
  }

  void _scheduleControlHide() {
    _controlHideTimer?.cancel();
    _controlHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        final provider = context.read<VideoPlayerProvider>();
        if (provider.isPlaying) {
          setState(() => _showControls = false);
        }
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleControlHide();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$minutes:$seconds';
  }

  void _toggleOrientationLock() {
    setState(() {
      _isOrientationLocked = !_isOrientationLocked;
    });
  }

  void _showVideoSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _VideoSettingsSheet(
        isOrientationLocked: _isOrientationLocked,
        onToggleOrientationLock: _toggleOrientationLock,
      ),
    );
  }

  void _onBack() {
    _exitFullScreen();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        context.read<VideoPlayerProvider>().pause();
      },
      child: Consumer<VideoPlayerProvider>(
        builder: (context, provider, _) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: _buildBody(provider),
          );
        },
      ),
    );
  }

  Widget _buildBody(VideoPlayerProvider provider) {
    if (!provider.isInitialized && !provider.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              'Loading video\u2026',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (provider.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                'Unable to play video',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.title,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: _onBack,
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    label: const Text(
                      'Go Back',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 16),
                  TextButton.icon(
                    onPressed: provider.retry,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    label: const Text(
                      'Retry',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _toggleControls,
      onDoubleTapDown: (details) {
        final screenWidth = MediaQuery.of(context).size.width;
        if (details.localPosition.dx < screenWidth / 2) {
          provider.skipBack();
        } else {
          provider.skipForward();
        }
        _showControls = true;
        _scheduleControlHide();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Video(
              controller: provider.controller,
              fit: BoxFit.contain,
              controls: null,
            ),
          ),

          if (provider.isBuffering)
            Positioned.fill(
              child: Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),

          if (_showControls) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 8,
                  right: 16,
                  bottom: 16,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: _onBack,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.settings_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _showVideoSettings,
                    ),
                  ],
                ),
              ),
            ),

            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SkipButton(icon: Icons.replay_10, onTap: provider.skipBack),
                  const SizedBox(width: 24),
                  GestureDetector(
                    onTap: provider.togglePlayPause,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        provider.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  _SkipButton(
                    icon: Icons.forward_10,
                    onTap: provider.skipForward,
                  ),
                ],
              ),
            ),

            if (provider.isInitialized)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: MediaQuery.of(context).padding.bottom + 12,
                    top: 24,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.8),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppColors.themeColor,
                          inactiveTrackColor: Colors.white30,
                          thumbColor: AppColors.themeColor,
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          value: provider.position.inMilliseconds
                              .toDouble()
                              .clamp(
                                0,
                                provider.duration.inMilliseconds.toDouble(),
                              ),
                          min: 0,
                          max: provider.duration.inMilliseconds
                              .toDouble()
                              .clamp(1, double.infinity),
                          onChanged: (value) {
                            provider.seek(
                              Duration(milliseconds: value.toInt()),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(provider.position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SpeedButton(
                                rate: provider.rate,
                                onChanged: provider.setRate,
                              ),
                              // const SizedBox(width: 16),
                              // if (widget.nextVideoUrl != null)
                              //   _AutoNextToggle(
                              //     enabled: _autoPlayNext,
                              //     onToggle: _toggleAutoPlayNext,
                              //   ),
                            ],
                          ),
                          Text(
                            _formatDuration(provider.duration),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _SkipButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

class _SpeedButton extends StatefulWidget {
  final double rate;
  final ValueChanged<double> onChanged;

  const _SpeedButton({required this.rate, required this.onChanged});

  @override
  State<_SpeedButton> createState() => _SpeedButtonState();
}

class _SpeedButtonState extends State<_SpeedButton> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  void _nextSpeed() {
    final currentIndex = _speeds.indexOf(widget.rate);
    final nextIndex = (currentIndex + 1) % _speeds.length;
    widget.onChanged(_speeds[nextIndex]);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _nextSpeed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${widget.rate}x',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

// class _AutoNextToggle extends StatelessWidget {
//   final bool enabled;
//   final VoidCallback onToggle;

//   const _AutoNextToggle({required this.enabled, required this.onToggle});

//   @override
//   Widget build(BuildContext context) {
//     return GestureDetector(
//       onTap: onToggle,
//       child: Row(
//         mainAxisSize: MainAxisSize.min,
//         children: [
//           Text(
//             'Auto',
//             style: TextStyle(
//               color: Colors.white.withValues(alpha: 0.7),
//               fontSize: 11,
//             ),
//           ),
//           const SizedBox(width: 4),
//           Icon(
//             enabled ? Icons.playlist_play : Icons.playlist_add,
//             color: enabled ? Colors.white : Colors.white54,
//             size: 18,
//           ),
//         ],
//       ),
//     );
//   }
// }

class _VideoSettingsSheet extends StatefulWidget {
  final bool isOrientationLocked;
  final VoidCallback onToggleOrientationLock;

  const _VideoSettingsSheet({
    required this.isOrientationLocked,
    required this.onToggleOrientationLock,
  });

  @override
  State<_VideoSettingsSheet> createState() => _VideoSettingsSheetState();
}

class _VideoSettingsSheetState extends State<_VideoSettingsSheet> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  String? _expandedSection;

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerProvider>(
      builder: (context, provider, _) {
        return SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(context).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _SettingsCategory(
                icon: Icons.speed,
                title: 'Playback Speed',
                subtitle: '${provider.rate}x',
                isExpanded: _expandedSection == 'speed',
                onTap: () {
                  setState(() {
                    _expandedSection = _expandedSection == 'speed'
                        ? null
                        : 'speed';
                  });
                },
                children: _speeds
                    .map(
                      (s) => _SettingsTile(
                        label: '${s}x',
                        isSelected: provider.rate == s,
                        onTap: () {
                          provider.setRate(s);
                          Navigator.pop(context);
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 4),
              _SettingsCategory(
                icon: Icons.screen_lock_rotation,
                title: 'Lock Orientation',
                subtitle: null,
                isExpanded: false,
                trailing: SizedBox(
                  height: 28,
                  child: Switch.adaptive(
                    value: widget.isOrientationLocked,
                    onChanged: (_) {
                      widget.onToggleOrientationLock();
                      Navigator.pop(context);
                    },
                    activeTrackColor: AppColors.themeColor,
                  ),
                ),
                onTap: () {
                  widget.onToggleOrientationLock();
                  Navigator.pop(context);
                },
                children: null,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsCategory extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool isExpanded;
  final VoidCallback onTap;
  final Widget? trailing;
  final List<Widget>? children;

  const _SettingsCategory({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.isExpanded,
    required this.onTap,
    this.trailing,
    this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (trailing != null) trailing!,
                if (children != null)
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white.withValues(alpha: 0.5),
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
        if (isExpanded && children != null)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: children!),
          ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppColors.themeColor : Colors.white,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check, color: AppColors.themeColor, size: 20),
          ],
        ),
      ),
    );
  }
}

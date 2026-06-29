import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:edtech/global/core/services/video_progress_service.dart';
import 'package:edtech/global/core/services/course_progress_service.dart';
import 'package:edtech/app/setup_network_caller.dart';
import 'package:edtech/app/urls.dart';

class VideoPlayerProvider extends ChangeNotifier {
  late final Player _player;
  late final VideoController _videoController;

  VideoController get controller => _videoController;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;
  bool isInitialized = false;
  bool isBuffering = false;
  bool hasError = false;
  double rate = 1.0;
  bool isActive = false;

  String? currentVideoUrl;
  String? currentTitle;
  int? currentLessonId;
  int? currentCourseId;
  String? nextVideoUrl;
  String? nextVideoTitle;
  VoidCallback? onCompleted;

  Timer? _saveTimer;
  bool _hasCompleted = false;

  VideoPlayerProvider() {
    _player = Player(
      configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
    );
    _videoController = VideoController(_player);
    _initStreams();
  }

  void _initStreams() {
    _player.stream.position.listen((pos) {
      position = pos;
      notifyListeners();
      _checkCompletion();
    });

    _player.stream.duration.listen((dur) {
      duration = dur;
      notifyListeners();
    });

    _player.stream.playing.listen((playing) {
      isPlaying = playing;
      isInitialized = true;
      if (isBuffering) isBuffering = false;
      notifyListeners();
    });

    _player.stream.buffering.listen((buffering) {
      isBuffering = buffering;
      notifyListeners();
    });

    _player.stream.error.listen((_) {
      hasError = true;
      isBuffering = false;
      notifyListeners();
    });
  }

  Future<void> openVideo({
    required String url,
    required String title,
    Duration initialPosition = Duration.zero,
    int? lessonId,
    int? courseId,
    VoidCallback? onCompleted,
    String? nextVideoUrl,
    String? nextVideoTitle,
  }) async {
    if (url.isEmpty) {
      hasError = true;
      notifyListeners();
      return;
    }
    currentVideoUrl = url;
    currentTitle = title;
    currentLessonId = lessonId;
    currentCourseId = courseId;
    this.nextVideoUrl = nextVideoUrl;
    this.nextVideoTitle = nextVideoTitle;
    this.onCompleted = onCompleted;
    _hasCompleted = false;

    isActive = true;
    isInitialized = false;
    hasError = false;
    isBuffering = false;
    notifyListeners();

    try {
      Duration start = initialPosition;
      if (lessonId != null && start == Duration.zero) {
        start = await VideoProgressService.getPosition(lessonId);
      }

      await _player.open(Media(url));
      if (start > Duration.zero) {
        await _player.seek(start);
      }
      _player.play();
      _startAutoSave();
    } catch (e) {
      AppLogger.e('openVideo error: $e');
      hasError = true;
      notifyListeners();
    }
  }

  void _startAutoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      final lessonId = currentLessonId;
      if (lessonId != null && position > Duration.zero) {
        VideoProgressService.savePosition(lessonId, position);
      }
    });
  }

  void _checkCompletion() {
    if (_hasCompleted) return;
    if (duration.inMilliseconds <= 0) return;
    if (position.inMilliseconds >= duration.inMilliseconds * 0.99) {
      _hasCompleted = true;
      _saveTimer?.cancel();
      final lessonId = currentLessonId;
      if (lessonId != null) {
        VideoProgressService.clearPosition(lessonId);
      }
      if (currentCourseId != null && lessonId != null) {
        _markLessonCompleted(lessonId);
      }
      onCompleted?.call();
    }
  }

  Future<void> _markLessonCompleted(int lessonId) async {
    final cid = currentCourseId;
    if (cid != null) {
      await CourseProgressService.markLessonCompleted(cid, lessonId);
    }
    try {
      await getNetworkCaller().postRequest(
        url: '${Urls.courseLessonUrl}/complete',
        body: {'lessonId': lessonId, if (cid != null) 'courseId': cid},
      );
    } catch (_) {}
  }

  void play() {
    _player.play();
  }

  void pause() {
    _player.pause();
    notifyListeners();
  }

  void togglePlayPause() {
    if (isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
    notifyListeners();
  }

  void seek(Duration pos) {
    _player.seek(pos);
    notifyListeners();
  }

  void skipBack() {
    final newPos = position - const Duration(seconds: 10);
    _player.seek(newPos >= Duration.zero ? newPos : Duration.zero);
    notifyListeners();
  }

  void skipForward() {
    final newPos = position + const Duration(seconds: 10);
    _player.seek(newPos <= duration ? newPos : duration);
    notifyListeners();
  }

  void setRate(double r) {
    rate = r;
    _player.setRate(r);
    notifyListeners();
  }

  void retry() {
    final url = currentVideoUrl;
    final title = currentTitle;
    if (url == null || title == null) return;
    openVideo(
      url: url,
      title: title,
      lessonId: currentLessonId,
      courseId: currentCourseId,
      onCompleted: onCompleted,
      nextVideoUrl: nextVideoUrl,
      nextVideoTitle: nextVideoTitle,
    );
  }

  void stop() {
    _saveTimer?.cancel();
    if (!isActive) return;
    _player.stop();
    isActive = false;
    isInitialized = false;
    currentVideoUrl = null;
    currentTitle = null;
    currentLessonId = null;
    currentCourseId = null;
    nextVideoUrl = null;
    nextVideoTitle = null;
    onCompleted = null;
    notifyListeners();
  }

  void dismiss() {
    _saveTimer?.cancel();
    if (!isActive) return;
    _player.stop();
    isActive = false;
    isInitialized = false;
    currentVideoUrl = null;
    currentTitle = null;
    currentLessonId = null;
    currentCourseId = null;
    nextVideoUrl = null;
    nextVideoTitle = null;
    onCompleted = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}

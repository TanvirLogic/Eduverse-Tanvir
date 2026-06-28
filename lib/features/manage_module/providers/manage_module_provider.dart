import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:edtech/features/courses/data/models/upload_task.dart';
import 'package:edtech/features/courses/data/repositories/upload_queue_repository.dart';
import 'package:edtech/features/courses/providers/unified_upload_queue_provider.dart';
import 'package:edtech/features/manage_module/data/manage_module_models.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:edtech/app/urls.dart';
import 'package:edtech/app/setup_network_caller.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:edtech/global/core/services/toast_service.dart';

class ManageModuleProvider extends ChangeNotifier {
  final int courseId;
  int _nextModuleId = 1;
  int _nextLessonId = 1;
  bool _isLoading = true;

  final List<CourseModule> _modules = [];
  final Map<int, String> _videoUrlCache = {};
  final Map<int, PendingLesson> _pendingLessons = {};
  Timer? _progressTimer;
  bool _hasUnsavedChanges = false;
  bool _isRestoringPending = false;
  bool _isRefreshing = false;
  bool _isQueuing = false;
  final Set<int> _notifiedCompletions = {};

  String _courseTitle = '';
  String _courseShortDescription = '';
  String _courseDescription = '';
  String _courseRequirements = '';
  String _courseLanguage = '';
  String _courseLevel = '';
  String _courseType = '';
  String _courseStatus = '';
  double _coursePrice = 0;
  String? _courseThumbnailUrl;
  String? _courseIntroVideoUrl;

  ManageModuleProvider({this.courseId = 0}) {
    _fetchCourse();
  }

  List<CourseModule> get modules => _modules;
  bool get hasUnsavedChanges => _hasUnsavedChanges;
  bool get isLoading => _isLoading;

  Map<int, PendingLesson> get pendingLessons => _pendingLessons;

  List<PendingLesson> pendingLessonsForModule(int moduleId) {
    return _pendingLessons.values.where((p) => p.moduleId == moduleId).toList();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  String get courseTitle => _courseTitle;
  String get courseShortDescription => _courseShortDescription;
  String get courseDescription => _courseDescription;
  String get courseRequirements => _courseRequirements;
  String get courseLanguage => _courseLanguage;
  String get courseLevel => _courseLevel;
  String get courseType => _courseType;
  String get courseStatus => _courseStatus;
  double get coursePrice => _coursePrice;
  String? get courseThumbnailUrl => _courseThumbnailUrl;
  String? get courseIntroVideoUrl => _courseIntroVideoUrl;

  int get nextModuleId => _nextModuleId;
  int get nextLessonId => _nextLessonId;

  void incrementModuleId() => _nextModuleId++;
  void incrementLessonId() => _nextLessonId++;

  Future<void> refresh() => _fetchCourse(silent: _pendingLessons.isNotEmpty);

  Future<void> _silentRefresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      await _fetchCourse(silent: true);
    } finally {
      _isRefreshing = false;
    }
    // Restore any pending items that are still in the DB after a silent
    // refresh so they don't disappear from the UI.
    await _restorePendingUploads();
  }

  Future<void> _fetchCourse({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      notifyListeners();
    }
    final response = await getNetworkCaller().getRequest(
      // TODO : Use the actual courseId instead of hardcoding 2
      url: '${Urls.updateCourseUrl}?courseID=$courseId',
      // url: '${Urls.updateCourseUrl}?courseID=2',
    );
    if (response.isSuccess) {
      final data = response.responseData['data'];
      if (data is Map) {
        _courseTitle = data['title'] as String? ?? '';
        _courseShortDescription = data['shortDescription'] as String? ?? '';
        _courseDescription = data['description'] as String? ?? '';
        _courseRequirements = data['requirements'] as String? ?? '';
        _courseLanguage = data['language'] as String? ?? '';
        _courseLevel = data['level'] as String? ?? '';
        _courseType = data['type'] as String? ?? '';
        _courseStatus = data['status'] as String? ?? '';
        _coursePrice = (data['price'] as num?)?.toDouble() ?? 0;
        _courseThumbnailUrl = data['thumbnailUrl'] as String?;
        _courseIntroVideoUrl = data['introVideoUrl'] as String?;

        final modulesList = data['modules'] as List? ?? [];
        _modules.clear();
        for (final item in modulesList) {
          final lessons =
              (item['lessons'] as List?)?.map((l) {
                final lessonId = l['id'] as int? ?? _nextLessonId++;
                final video = l['video'] as Map?;
                final duration =
                    video?['duration'] as int? ?? l['duration'] as int?;
                final videoUrl =
                    l['videoUrl'] as String? ??
                    video?['videoUrl'] as String? ??
                    video?['url'] as String? ??
                    video?['fileUrl'] as String? ??
                    l['fileUrl'] as String? ??
                    l['url'] as String? ??
                    _videoUrlCache[lessonId];
                if (videoUrl != null) _videoUrlCache[lessonId] = videoUrl;
                return Lesson(
                  id: lessonId,
                  title: l['title'] as String? ?? '',
                  duration: duration != null
                      ? _formatDuration(duration)
                      : '0:00',
                  type: LessonType.video,
                  videoUrl: videoUrl,
                );
              }).toList() ??
              [];
          final resources =
              (item['resources'] as List?)?.map((r) {
                return Lesson(
                  id: r['id'] as int? ?? _nextLessonId++,
                  title: r['title'] as String? ?? '',
                  duration: '',
                  type: LessonType.resource,
                  fileUrl: r['fileUrl'] as String?,
                  fileType: r['fileType'] as String?,
                );
              }).toList() ??
              [];
          _modules.add(
            CourseModule(
              id: item['id'] as int? ?? _nextModuleId++,
              title: item['title'] as String? ?? '',
              order: item['order'] as int? ?? _modules.length,
              courseId: courseId,
              lessons: [...lessons, ...resources],
              isExpanded: false,
            ),
          );
        }
      }
    }
    if (!silent) {
      _isLoading = false;
    }
    for (final module in _modules) {
      if (module.id >= _nextModuleId) {
        _nextModuleId = module.id + 1;
      }
      for (final lesson in module.lessons) {
        if (lesson.id >= _nextLessonId) {
          _nextLessonId = lesson.id + 1;
        }
      }
    }

    _removeCompletedPendingLessons();
    notifyListeners();
    if (!silent) {
      _restorePendingUploads();
    }
  }

  void _removeCompletedPendingLessons() {
    final toRemove = <int>[];
    for (final entry in _pendingLessons.entries) {
      if (entry.value.uploadStatus == 'completed') {
        toRemove.add(entry.key);
      }
    }
    for (final queueId in toRemove) {
      _pendingLessons.remove(queueId);
    }
  }

  Future<void> _restorePendingUploads() async {
    if (_isRestoringPending) return;
    _isRestoringPending = true;
    try {
      final allItems = await UploadQueueRepository.getActive();
      final lessonItems = allItems
          .where(
            (i) =>
                i.uploadType == 'module_lesson' || i.uploadType == 'resource',
          )
          .toList();
      if (lessonItems.isEmpty) {
        AppLogger.i('_restorePendingUploads: no active lesson items found');
        return;
      }
      AppLogger.i(
        '_restorePendingUploads: found ${lessonItems.length} item(s) to restore',
      );
      for (final item in lessonItems) {
        final pct = item.fileSize > 0
            ? ((item.bytesUploaded / item.fileSize) * 100).round()
            : 0;
        AppLogger.i(
          '_restorePendingUploads:   candidate id=${item.id} '
          'type=${item.uploadType} status=${item.status} '
          'progress=$pct% title="${item.title}"',
        );
      }

      bool hasUpdates = false;

      for (final item in lessonItems) {
        if (item.id == null ||
            _pendingLessons.containsKey(item.id) ||
            item.status == 'cancelled') {
          continue;
        }

        final meta = item.parseMetadata(ModuleLessonMetadata.fromJson);
        if (meta == null) {
          AppLogger.w(
            '_restorePendingUploads: could not parse metadata for item ${item.id}',
          );
          continue;
        }
        if (meta.courseId != courseId) continue;

        final moduleIndex = _modules.indexWhere((m) => m.id == meta.moduleId);
        if (moduleIndex < 0) {
          AppLogger.w(
            '_restorePendingUploads: module ${meta.moduleId} not found for item ${item.id}',
          );
          continue;
        }

        final restoredLessonId = meta.lessonId;
        final alreadyExistsById = restoredLessonId != null
            ? _modules[moduleIndex].lessons.any((l) => l.id == restoredLessonId)
            : false;
        final alreadyExistsByUrl =
            item.fileUrl != null && item.fileUrl!.isNotEmpty
            ? _modules[moduleIndex].lessons.any(
                (l) => l.videoUrl == item.fileUrl || l.fileUrl == item.fileUrl,
              )
            : false;
        if (alreadyExistsById || alreadyExistsByUrl) {
          if (alreadyExistsByUrl && item.id != null) {
            await UploadQueueRepository.markCompleted(item.id!);
          }
          AppLogger.i(
            '_restorePendingUploads: skipping "${meta.lessonTitle}" — already exists on server',
          );
          continue;
        }

        final isResource = item.uploadType == 'resource';

        // Try to get real-time progress from background_downloader's database.
        // This catches the case where the native upload finished (100% in
        // notification tray) but the app was killed before the Dart callback
        // could write the final progress to SQLite.
        double restoredProgress = item.fileSize > 0
            ? (item.bytesUploaded / item.fileSize)
            : 0.0;
        if (item.workerId != null && item.workerId!.isNotEmpty) {
          try {
            final record = await FileDownloader().database.recordForId(
              item.workerId!,
            );
            if (record != null) {
              AppLogger.i(
                '_restorePendingUploads: native record for queueId=${item.id} '
                'status=${record.status} progress=${(record.progress * 100).toInt()}%',
              );
              // Native upload already complete — skip creating PendingLesson.
              // The upload pipeline in _loadQueue() will process the callback.
              if (record.status == TaskStatus.complete ||
                  record.progress >= 1.0) {
                AppLogger.i(
                  '_restorePendingUploads: skipping queueId=${item.id} '
                  '"${meta.lessonTitle}" — native upload already complete',
                );
                continue;
              }
              if (record.progress > restoredProgress) {
                restoredProgress = record.progress;
                if (item.fileSize > 0) {
                  await UploadQueueRepository.updateProgress(
                    id: item.id!,
                    bytesUploaded:
                        (record.progress * item.fileSize).round(),
                  );
                }
              }
            }
          } catch (_) {}
        }
        AppLogger.i(
          '_restorePendingUploads: restoring ${isResource ? "resource" : "lesson"} '
          '"${meta.lessonTitle}" queueId=${item.id} '
          'status=${item.status} progress=${(restoredProgress * 100).toInt()}% '
          'bytes=${item.bytesUploaded}/${item.fileSize} '
          'moduleId=${meta.moduleId}',
        );

        final lessonId = restoredLessonId ?? _nextLessonId++;
        if (restoredLessonId != null && restoredLessonId >= _nextLessonId) {
          _nextLessonId = lessonId + 1;
        }
        final pending = PendingLesson(
          queueId: item.id!,
          lessonId: lessonId,
          title: meta.lessonTitle,
          type: isResource ? LessonType.resource : LessonType.video,
          filePath: item.filePath,
          uploadProgress: restoredProgress,
          uploadStatus: item.status,
          fileUrl: item.fileUrl,
          moduleId: meta.moduleId,
        );

        _pendingLessons[item.id!] = pending;
        hasUpdates = true;
      }

      if (hasUpdates) {
        _startProgressPolling();
        notifyListeners();
      }
    } catch (e) {
      AppLogger.e('_restorePendingUploads error: $e');
    } finally {
      _isRestoringPending = false;
    }
  }

  List<Map<String, dynamic>> getSerializedOrder() {
    return _modules.asMap().entries.map((entry) {
      final module = entry.value;
      return {
        'module_id': module.id,
        'sort_order': entry.key,
        'title': module.title,
        'lessons': module.lessons.asMap().entries.map((le) {
          return {
            'lesson_id': le.value.id,
            'sort_order': le.key,
            'title': le.value.title,
            'type': le.value.type.name,
          };
        }).toList(),
      };
    }).toList();
  }

  void saveOrder() {
    final serialized = getSerializedOrder();
    debugPrint('Saving order: $serialized');
    _hasUnsavedChanges = false;
    notifyListeners();
    ToastService.showInfo("Module Managed Succesfully");
  }

  void addLessonToModule(
    int moduleIndex,
    LessonType type, {
    String? customTitle,
  }) {
    _modules[moduleIndex].lessons.add(
      Lesson(
        id: _nextLessonId++,
        title:
            customTitle ??
            (type == LessonType.video
                ? "Setting Up Your Environment"
                : "HTML Fundamentals"),
        duration: "18:20",
        type: type,
      ),
    );
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void reorderModule(int oldIndex, int newIndex) {
    final module = _modules.removeAt(oldIndex);
    _modules.insert(newIndex, module);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void toggleExpand(CourseModule module) {
    for (final m in _modules) {
      if (m != module) m.isExpanded = false;
    }
    module.isExpanded = !module.isExpanded;
    notifyListeners();
  }

  void renameModule(CourseModule module, String newName) {
    module.title = newName;
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void reorderLesson(
    CourseModule module,
    int oldLessonIndex,
    int newLessonIndex,
  ) {
    if (newLessonIndex > oldLessonIndex) newLessonIndex--;
    final lesson = module.lessons.removeAt(oldLessonIndex);
    module.lessons.insert(newLessonIndex, lesson);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  Future<bool> addModule(String title) async {
    final nextOrder = _modules.isEmpty
        ? 0
        : _modules.map((m) => m.order).reduce((a, b) => a > b ? a : b) + 1;
    final response = await getNetworkCaller().postRequest(
      url: Urls.courseModuleUrl,
      body: {'title': title, 'order': nextOrder, 'courseID': courseId},
    );
    if (response.isSuccess) {
      final data = response.responseData['data'];
      final moduleId = data['id'] as int? ?? _nextModuleId++;
      final serverCourseId = data['courseId'] as int? ?? courseId;
      _modules.add(
        CourseModule(
          id: moduleId,
          title: title,
          order: nextOrder,
          courseId: serverCourseId,
          lessons: [],
          isExpanded: true,
        ),
      );
      notifyListeners();
      ToastService.showSuccess('Module added successfully');
      return true;
    } else {
      ToastService.showError(response.errorMessage ?? 'Failed to add module');
      return false;
    }
  }

  Future<bool> deleteModule(CourseModule module) async {
    final response = await getNetworkCaller().deleteRequest(
      url: Urls.courseModuleUrl,
      body: {'moduleID': module.id},
    );
    if (response.isSuccess) {
      // Mark pending items for this module as cancelled in SQLite
      for (final entry in _pendingLessons.entries) {
        if (entry.value.moduleId == module.id) {
          await UploadQueueRepository.updateStatus(
            id: entry.key,
            status: 'cancelled',
          );
        }
      }
      _modules.removeWhere((m) => m.id == module.id);
      _pendingLessons.removeWhere((_, p) => p.moduleId == module.id);
      notifyListeners();
      ToastService.showSuccess('Module deleted successfully');
      return true;
    } else {
      ToastService.showError(
        response.errorMessage ?? 'Failed to delete module',
      );
      return false;
    }
  }

  Future<bool> editModule(CourseModule module, String title) async {
    final response = await getNetworkCaller().putRequest(
      url: Urls.courseModuleUrl,
      body: {'moduleID': module.id, 'title': title},
    );
    if (response.isSuccess) {
      module.title = title;
      notifyListeners();
      ToastService.showSuccess('Module updated successfully');
      return true;
    } else {
      ToastService.showError(
        response.errorMessage ?? 'Failed to update module',
      );
      return false;
    }
  }

  Future<bool> updateCourse(Map<String, dynamic> body) async {
    final response = await getNetworkCaller().putRequest(
      url: Urls.updateCourseUrl,
      body: body,
    );
    if (response.isSuccess) {
      await refresh();
      ToastService.showSuccess('Course updated successfully');
      return true;
    } else {
      ToastService.showError(
        response.errorMessage ?? 'Failed to update course',
      );
      return false;
    }
  }

  Future<bool> renameLesson(
    CourseModule module,
    int lessonIndex,
    String newName,
  ) async {
    final lesson = module.lessons[lessonIndex];
    final isResource = lesson.type == LessonType.resource;
    final response = await getNetworkCaller().putRequest(
      url: isResource
          ? Urls.courseModuleResourceUrl
          : Urls.courseModuleLessonUrl,
      body: isResource
          ? {'resourceId': lesson.id, 'title': newName}
          : {'lessonId': lesson.id, 'title': newName},
    );
    if (response.isSuccess) {
      module.lessons[lessonIndex].title = newName;
      notifyListeners();
      ToastService.showSuccess(
        isResource
            ? 'Resource updated successfully'
            : 'Lesson renamed successfully',
      );
      return true;
    } else {
      ToastService.showError(response.errorMessage ?? 'Failed to rename');
      return false;
    }
  }

  Future<bool> deleteLesson(CourseModule module, int lessonIndex) async {
    final allModuleLessons = module.lessons;
    if (lessonIndex < 0 || lessonIndex >= allModuleLessons.length) {
      return false;
    }
    final lesson = allModuleLessons[lessonIndex];

    final isResource = lesson.type == LessonType.resource;
    final response = await getNetworkCaller().deleteRequest(
      url: isResource
          ? Urls.courseModuleResourceUrl
          : Urls.courseModuleLessonUrl,
      body: isResource ? {'resourceId': lesson.id} : {'lessonId': lesson.id},
    );
    if (response.isSuccess) {
      module.lessons.removeAt(lessonIndex);
      notifyListeners();
      ToastService.showSuccess(
        isResource
            ? 'Resource deleted successfully'
            : 'Lesson deleted successfully',
      );
      return true;
    } else {
      ToastService.showError(response.errorMessage ?? 'Failed to delete');
      return false;
    }
  }

  Future<void> deletePendingLesson(
    int queueId, {
    UnifiedUploadQueueProvider? queueProvider,
  }) async {
    final pending = _pendingLessons[queueId];
    if (pending == null) return;

    if (queueProvider != null) {
      await queueProvider.cancelTask(queueId);
    } else {
      await UploadQueueRepository.updateStatus(
        id: queueId,
        status: 'cancelled',
      );
    }

    _pendingLessons.remove(queueId);

    if (_pendingLessons.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
    }
    notifyListeners();
    ToastService.showSuccess('Upload cancelled');
  }

  Future<void> retryPendingLesson(
    int queueId, {
    UnifiedUploadQueueProvider? queueProvider,
  }) async {
    if (_isQueuing) {
      ToastService.showError('Please wait, another operation is in progress');
      return;
    }
    final pending = _pendingLessons[queueId];
    if (pending == null) return;
    if (queueProvider == null) return;

    _isQueuing = true;
    try {
      // Delegate to the central queue provider so presigned URLs are refreshed
      // and the heartbeat timer stays active
      await queueProvider.retryFailed(queueId);

      _pendingLessons[queueId] = PendingLesson(
        queueId: pending.queueId,
        lessonId: pending.lessonId,
        title: pending.title,
        type: pending.type,
        filePath: pending.filePath,
        moduleId: pending.moduleId,
        uploadProgress: 0.0,
        uploadStatus: 'pending',
      );
      _startProgressPolling();
      notifyListeners();
      ToastService.showInfo('Retrying upload...');
    } finally {
      _isQueuing = false;
    }
  }

  Future<bool> addVideoLesson(
    int moduleIndex,
    String title,
    XFile videoFile, {
    UnifiedUploadQueueProvider? queueProvider,
  }) async {
    if (_isQueuing) {
      ToastService.showError('Please wait, another file is being queued');
      return false;
    }

    _isQueuing = true;
    try {
      final module = _modules[moduleIndex];

      if (queueProvider == null) return false;

      // Check ALL statuses for same filePath — prevents duplicates even after failure/cancellation
      if (!await _checkDedupOrCleanup(videoFile.path)) return false;

      final lessonId = _nextLessonId++;
      int queueId;
      try {
        queueId = await queueProvider.addModuleLessonToQueue(
          videoPath: videoFile.path,
          lessonTitle: title,
          moduleId: module.id,
          courseId: courseId,
          lessonId: lessonId,
        );
      } catch (e) {
        AppLogger.e('addVideoLesson queue error: $e');
        ToastService.showError('Failed to queue video lesson');
        return false;
      }

      if (queueId <= 0) return false;

      final pending = PendingLesson(
        queueId: queueId,
        lessonId: lessonId,
        title: title,
        type: LessonType.video,
        filePath: videoFile.path,
        uploadProgress: 0.0,
        uploadStatus: 'pending',
        moduleId: module.id,
      );

      _pendingLessons[queueId] = pending;
      _hasUnsavedChanges = true;
      notifyListeners();
      _startProgressPolling();
      return true;
    } finally {
      _isQueuing = false;
    }
  }

  void _startProgressPolling() {
    _progressTimer?.cancel();
    _pollProgress();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollProgress();
    });
  }

  Future<void> _pollProgress() async {
    try {
      final allDb = await UploadQueueRepository.getActive();
      final dbMap = {for (final item in allDb) item.id: item};
      // Also fetch failed items we're tracking so they remain visible
      // in the UI (otherwise getActive() excludes 'failed' status and
      // the item silently vanishes from the pending list below).
      if (_pendingLessons.isNotEmpty) {
        final failedIds = _pendingLessons.keys.where(
          (id) => !dbMap.containsKey(id),
        ).toList();
        if (failedIds.isNotEmpty) {
          final allItems = await UploadQueueRepository.getAll();
          for (final item in allItems) {
            if (failedIds.contains(item.id)) {
              dbMap[item.id!] = item;
            }
          }
        }
      }
      bool updated = false;
      final completedIds = <int>[];

      for (final entry in _pendingLessons.entries) {
        final queueId = entry.key;
        final pending = entry.value;
        final dbItem = dbMap[queueId];

        if (dbItem == null) {
          AppLogger.w(
            '_pollProgress: queueId=$queueId vanished from DB — removing from pending',
          );
          _pendingLessons.remove(queueId);
          updated = true;
          continue;
        }

        final status = dbItem.status;
        var progress = dbItem.fileSize > 0
            ? (dbItem.bytesUploaded / dbItem.fileSize)
            : 0.0;

        // If the item has a workerId, try background_downloader's DB for
        // real progress — this works even if Dart callbacks aren't firing.
        if (dbItem.workerId != null && dbItem.workerId!.isNotEmpty) {
          try {
            final record = await FileDownloader().database.recordForId(
              dbItem.workerId!,
            );
            if (record != null && record.progress > progress) {
              progress = record.progress;
              if (dbItem.fileSize > 0) {
                await UploadQueueRepository.updateProgress(
                  id: queueId,
                  bytesUploaded: (record.progress * dbItem.fileSize).round(),
                );
              }
            }
          } catch (_) {}
        }

        if (pending.uploadStatus != status ||
            pending.uploadProgress != progress) {
          AppLogger.i(
            '_pollProgress: queueId=$queueId status=$status '
            'progress=${(progress * 100).toInt()}% '
            'title="${pending.title}"',
          );
          pending.uploadStatus = status;
          pending.uploadProgress = progress;
          updated = true;
        }

        if (dbItem.fileUrl != null && dbItem.fileUrl!.isNotEmpty) {
          pending.fileUrl = dbItem.fileUrl;
        }

        if (status == 'completed') {
          AppLogger.i(
            '_pollProgress: queueId=$queueId completed '
            'url=${dbItem.fileUrl ?? "N/A"}',
          );
          pending.uploadStatus = 'completed';
          pending.uploadProgress = 1.0;
          updated = true;
          completedIds.add(queueId);
          if (_notifiedCompletions.add(queueId)) {
            ToastService.showSuccess('Upload completed successfully');
          }
        } else if (status == 'failed') {
          pending.uploadStatus = 'failed';
          pending.uploadProgress = 0.0;
          updated = true;
        }
      }

      for (final queueId in completedIds) {
        _pendingLessons.remove(queueId);
      }

      if (completedIds.isNotEmpty) {
        await _silentRefresh();
      }

      if (updated) notifyListeners();

      if (_pendingLessons.isEmpty) {
        _progressTimer?.cancel();
        _progressTimer = null;
        if (completedIds.isNotEmpty) {
          Future.delayed(const Duration(seconds: 10), () async {
            await _silentRefresh();
          });
        }
      }
    } catch (e) {
      AppLogger.e('_startProgressPolling error: $e');
    }
  }

  /// Checks if a filePath is already in the queue (any status).
  /// If it exists with a terminal status (failed/cancelled/completed),
  /// auto-cleans the old row to allow re-upload.
  /// Returns true if the file is safe to queue, false if blocked.
  Future<bool> _checkDedupOrCleanup(String filePath) async {
    final existingItems = await UploadQueueRepository.getByFileType(
      filePath: filePath,
    );
    final existing = existingItems.cast<UploadQueueItem?>().firstWhere(
      (item) =>
          item!.uploadType == 'module_lesson' || item.uploadType == 'resource',
      orElse: () => null,
    );
    if (existing == null) return true;

    if (existing.status == 'pending' || existing.status == 'uploading') {
      ToastService.showError('This file is already being uploaded');
      return false;
    }

    // Terminal status — clean up old row and cached file, allow re-upload
    if (existing.id != null) {
      await UploadQueueRepository.cleanupFileIfCached(existing.filePath);
      await UploadQueueRepository.deleteItem(existing.id!);
    }
    _pendingLessons.remove(existing.id);
    return true;
  }

  Future<bool> addResourceLesson(
    int moduleIndex,
    String title,
    XFile resourceFile, {
    UnifiedUploadQueueProvider? queueProvider,
  }) async {
    if (_isQueuing) {
      ToastService.showError('Please wait, another file is being queued');
      return false;
    }

    _isQueuing = true;
    try {
      final module = _modules[moduleIndex];

      if (queueProvider == null) return false;

      if (!await _checkDedupOrCleanup(resourceFile.path)) return false;

      final lessonId = _nextLessonId++;
      int queueId;
      try {
        final contentType = _inferResourceContentType(resourceFile.name);
        queueId = await queueProvider.addResourceToQueue(
          filePath: resourceFile.path,
          lessonTitle: title,
          moduleId: module.id,
          courseId: courseId,
          contentType: contentType,
          lessonId: lessonId,
        );
      } catch (e) {
        AppLogger.e('addResourceLesson queue error: $e');
        ToastService.showError('Failed to queue resource lesson');
        return false;
      }

      if (queueId <= 0) return false;

      final pending = PendingLesson(
        queueId: queueId,
        lessonId: lessonId,
        title: title,
        type: LessonType.resource,
        filePath: resourceFile.path,
        uploadProgress: 0.0,
        uploadStatus: 'pending',
        moduleId: module.id,
      );

      _pendingLessons[queueId] = pending;
      _hasUnsavedChanges = true;
      notifyListeners();
      _startProgressPolling();
      return true;
    } finally {
      _isQueuing = false;
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _inferResourceContentType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        return 'application/octet-stream';
    }
  }
}

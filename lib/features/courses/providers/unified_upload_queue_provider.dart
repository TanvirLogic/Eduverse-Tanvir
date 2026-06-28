import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:edtech/app/app.dart';
import 'package:edtech/app/urls.dart';
import 'package:edtech/features/auth/data/models/auth_controller.dart';
import 'package:edtech/features/courses/data/helpers/video_metadata_helper.dart';
import 'package:edtech/features/courses/data/models/upload_task.dart';
import 'package:edtech/features/courses/data/repositories/upload_queue_repository.dart';
import 'package:edtech/features/courses/services/background_upload_service.dart';
import 'package:edtech/features/courses/services/background_uploader_service.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:edtech/global/core/services/toast_service.dart';
import 'package:edtech/global/core/services/upload_notification_service.dart';
import 'package:flutter/material.dart';

class UnifiedUploadQueueProvider extends ChangeNotifier {
  List<UploadQueueItem> _queue = [];
  UploadQueueItem? _activeItem;
  int _activeProgress = 0;
  bool _isUploading = false;
  DateTime? _isUploadingSince;
  int _progressUpdateCount = 0;
  Timer? _queuePumpTimer;
  // Guards against concurrent _handleNativeComplete for the same item,
  // which would send the server callback twice (creating duplicate lessons).
  final Set<int> _handlingNativeComplete = {};

  List<UploadQueueItem> get queue => List.unmodifiable(_queue);
  UploadQueueItem? get activeItem => _activeItem;
  int get activeProgress => _activeProgress;
  bool get isBackgroundRunning => false;
  bool get isPaused => false;

  int get pendingCount =>
      _queue.where((item) => item.status == 'pending').length;

  int get completedCount =>
      _queue.where((item) => item.status == 'completed').length;

  int get failedCount => _queue.where((item) => item.status == 'failed').length;

  double get totalProgress {
    if (_activeItem == null) return 0.0;
    return _activeProgress / 100.0;
  }

  UnifiedUploadQueueProvider() {
    _init();
  }

  @override
  void dispose() {
    _queuePumpTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    // Register callbacks and notification config BEFORE start() so they
    // are in place even if a task is enqueued before _init() completes.
    // If a task starts without a notification config the native foreground
    // service may fail (no notification = crash on Android 12+).
    FileDownloader().registerCallbacks(
      taskStatusCallback: (update) {
        unawaited(_onNativeTaskStatus(update));
      },
      taskProgressCallback: (update) {
        unawaited(_onNativeTaskProgress(update));
      },
    );
    FileDownloader().configureNotificationForGroup(
      'upload_queue',
      running: TaskNotification(
        'Uploading {displayName}',
        '{progress} completed',
      ),
      complete: TaskNotification(
        'Upload complete',
        '{displayName} uploaded successfully',
      ),
      error: TaskNotification(
        'Upload failed',
        '{displayName} — tap to retry',
      ),
      progressBar: true,
    );

    // Resume tracking of previously enqueued tasks and re-deliver
    // any status/progress updates that fired while the app was suspended.
    await FileDownloader().start(
      doTrackTasks: true,
      doRescheduleKilledTasks: true,
    );

    // Give re-fired callbacks a moment to arrive before we inspect the queue.
    // This ensures tasks that completed while the app was dead get their
    // terminal status persisted to SQLite before _loadQueue decides what to
    // re-enqueue.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await _loadQueue();
    _startQueuePump();
  }

  /// Periodic safety net:
  /// 1. Resets items stuck in 'uploading' for >10 min (native task lost).
  /// 2. Releases stuck Dart lock ([_isUploading] true for >5 min but no
  ///    'uploading' item in DB).
  /// 3. Kicks the queue if pending items should be enqueued but aren't.
  void _startQueuePump() {
    _queuePumpTimer?.cancel();
    _queuePumpTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final all = await UploadQueueRepository.getActive();
      final now = DateTime.now();

      // --- 1a. Proactive native-status check via background_downloader's
      // internal DB. This MUST run BEFORE the stale reset (section 1)
      // to refresh timestamps for slow uploads.  Otherwise a multi-GB
      // video whose Dart callbacks have stopped firing (app in
      // background) would have a frozen lastUpdated —> section 1 resets
      // it to 'pending' and clears workerId while the original native
      // WorkManager task is still running, causing a second native
      // upload to the same S3 key.
      {
        final refreshed = <UploadQueueItem>[];
        for (final item in all) {
          if (item.status != 'uploading' ||
              item.isNativeCompleted ||
              item.workerId == null ||
              item.workerId!.isEmpty) {
            refreshed.add(item);
            continue;
          }
          try {
            final record = await FileDownloader().database.recordForId(
              item.workerId!,
            );
            if (record != null &&
                (record.status == TaskStatus.complete ||
                    record.progress >= 1.0)) {
              AppLogger.i(
                '_queuePump: native upload completed for id=${item.id} '
                '— processing immediately',
              );
              unawaited(_handleNativeComplete(item.id!, item.workerId!));
              continue;
            }
            if (record == null) {
              AppLogger.w(
                '_queuePump: native task vanished for id=${item.id} '
                '— resetting to pending',
              );
              await UploadQueueRepository.updateStatus(
                id: item.id!,
                status: 'pending',
              );
              await UploadQueueRepository.updateWorkerId(
                id: item.id!,
                workerId: '',
              );
              continue;
            }
            if (record.progress > 0 && item.fileSize > 0) {
              final nativeBytes = (record.progress * item.fileSize).round();
              if (nativeBytes > item.bytesUploaded) {
                await UploadQueueRepository.updateProgress(
                  id: item.id!,
                  bytesUploaded: nativeBytes,
                );
              }
              // Fresh timestamp prevents section 1 from resetting this
              // slow upload while the native task is still running.
              refreshed.add(item.copyWith(
                bytesUploaded: nativeBytes > item.bytesUploaded
                    ? nativeBytes
                    : item.bytesUploaded,
                lastUpdated: DateTime.now().toIso8601String(),
              ));
              continue;
            }
          } catch (e) {
            AppLogger.w('_queuePump: recordForId error for id=${item.id}: $e');
          }
          refreshed.add(item);
        }
        all
          ..clear()
          ..addAll(refreshed);
      }

      // --- 1. Truly stale native tasks (>10 min in 'uploading') ---
      {
        bool recoveredAny = false;
        for (final item in all) {
          if (item.isNativeCompleted) continue;
          final lastUpdatedParsed = DateTime.tryParse(item.lastUpdated);
          if (item.status == 'uploading' &&
              lastUpdatedParsed != null &&
              now.difference(lastUpdatedParsed) > const Duration(minutes: 10)) {
            AppLogger.w(
              '_queuePump: resetting stale uploading item id=${item.id} '
              '(lastUpdated=${item.lastUpdated})',
            );
            await UploadQueueRepository.resetStaleUploading();
            recoveredAny = true;
            break;
          }
        }
        if (recoveredAny) {
          final refreshed = await UploadQueueRepository.getActive();
          all
            ..clear()
            ..addAll(refreshed);
        }
      }

      // --- 1b. Retry server callback for items where native upload
      // completed but server callback failed (e.g. app was killed, or
      // auth token wasn't ready on restart).
      for (final item in all) {
        if (item.isNativeCompleted && !item.isCallbackCompleted) {
          AppLogger.i(
            '_queuePump: retrying callback for item id=${item.id} '
            'workerId=${item.workerId}',
          );
          unawaited(_handleNativeComplete(item.id!, item.workerId ?? ''));
        }
      }

      // --- 2. Stuck Dart lock ---
      if (_isUploading &&
          _isUploadingSince != null &&
          now.difference(_isUploadingSince!) > const Duration(minutes: 5)) {
        final hasUploading = all.any((i) => i.status == 'uploading');
        if (!hasUploading) {
          AppLogger.w(
            '_queuePump: lock stuck for >5m with no uploading item, releasing',
          );
          _isUploading = false;
          _isUploadingSince = null;
        } else {
          return; // still uploading, nothing to do
        }
      }

      if (_isUploading) return;

      // --- 3. Kick pending items ---
      final hasPending = all.any(
        (i) =>
            i.status == 'pending' &&
            (i.workerId == null || i.workerId!.isEmpty),
      );
      if (hasPending) {
        AppLogger.i('_queuePump: found stuck pending items, kicking queue');
        _processNextItem();
      }
    });
  }

  Future<void> _loadQueue() async {
    try {
      final allItems = await UploadQueueRepository.getAll();
      for (final item in allItems) {
        // Recovery: native upload completed (S3) but server callback never
        // fired (e.g. app killed during callback, or start() didn't re-fire
        // the completion callback). Retry the callback now.
        if (item.status == 'uploading' && item.isNativeCompleted) {
          AppLogger.i(
            '_loadQueue: retrying callback for completed-native item id=${item.id}',
          );
          unawaited(_handleNativeComplete(item.id!, item.workerId ?? ''));
          continue;
        }

        // Proactive check: query background_downloader's internal DB for the
        // actual native task status. This catches uploads that completed
        // (100% in notification tray) while the app was killed, where the
        // re-fired callback didn't arrive before _loadQueue() runs.
        if (item.status == 'uploading' &&
            item.workerId != null &&
            item.workerId!.isNotEmpty) {
          try {
            final record = await FileDownloader().database.recordForId(
              item.workerId!,
            );
            if (record != null) {
              AppLogger.i(
                '_loadQueue: native record for id=${item.id} '
                'status=${record.status} progress=${(record.progress * 100).toInt()}%',
              );
              if (record.status == TaskStatus.complete ||
                  record.progress >= 1.0) {
                AppLogger.i(
                  '_loadQueue: native upload completed for id=${item.id} '
                  '— processing immediately',
                );
                unawaited(_handleNativeComplete(item.id!, item.workerId!));
                continue;
              }
              if (record.status == TaskStatus.failed || record.status == TaskStatus.waitingToRetry) {
                AppLogger.w(
                  '_loadQueue: native upload ${record.status} for id=${item.id} '
                  '— resetting to pending',
                );
                await UploadQueueRepository.updateStatus(
                  id: item.id!,
                  status: 'pending',
                );
                await UploadQueueRepository.updateWorkerId(
                  id: item.id!,
                  workerId: '',
                );
                continue;
              }
              // Sync progress from native DB
              if (record.progress > 0 &&
                  item.fileSize > 0 &&
                  record.progress > (item.bytesUploaded / item.fileSize)) {
                await UploadQueueRepository.updateProgress(
                  id: item.id!,
                  bytesUploaded: (record.progress * item.fileSize).round(),
                );
              }
              // Native task is alive (record found) — claim the queue lock
              // so _processNextItem doesn't concurrently start pending items
              // (preserves FIFO order across app restarts).
              if (!_isUploading) {
                _isUploading = true;
                _isUploadingSince = DateTime.now();
                _activeItem = item;
                notifyListeners();
                AppLogger.i(
                  '_loadQueue: claimed lock for active native upload id=${item.id} '
                  'progress=${(record.progress * 100).toInt()}%',
                );
              }
              // Skip the stale reset below even if lastUpdated is hours old
              // (e.g. app was killed during a multi-GB upload).
              continue;
            } else {
              // Native task is gone — app was probably killed while the
              // upload was running.  Reset to 'pending' so the queue can
              // re-fetch a URL and re-upload it.
              AppLogger.w(
                '_loadQueue: native task vanished for id=${item.id} '
                '— resetting to pending',
              );
              await UploadQueueRepository.updateStatus(
                id: item.id!,
                status: 'pending',
              );
              await UploadQueueRepository.updateWorkerId(
                id: item.id!,
                workerId: '',
              );
              continue;
            }
          } catch (e) {
            AppLogger.w(
              '_loadQueue: error querying native record for id=${item.id}: $e',
            );
          }
        }

        // Reset stale 'uploading' items so they can be retried after a restart.
        // This covers pre-migration rows that have no workerId, and tasks that
        // were left in 'uploading' after the app was killed without a callback.
        if (item.status == 'uploading') {
          final lastUpdatedParsed = DateTime.tryParse(item.lastUpdated);
          final isStale =
              lastUpdatedParsed != null &&
              DateTime.now().difference(lastUpdatedParsed) >
                  const Duration(minutes: 30);
          final missingWorker = item.workerId == null || item.workerId!.isEmpty;

          if (missingWorker || isStale) {
            AppLogger.i(
              '_loadQueue: resetting stale uploading item id=${item.id} '
              'workerId=${item.workerId} lastUpdated=${item.lastUpdated}',
              tag: 'UPLOAD-QUEUE',
            );
            await UploadQueueRepository.updateStatus(
              id: item.id!,
              status: 'pending',
            );
            await UploadQueueRepository.updateWorkerId(
              id: item.id!,
              workerId: '',
            );
          }
        }
        // Items that were queued but app was killed before the presigned URL
        // was stored. Instead of silently deleting them after 30 minutes,
        // try to fetch fresh URLs. If that fails, mark as 'failed' so the
        // user sees them and can manually retry or dismiss.
        if (item.status == 'pending' &&
            item.bytesUploaded == 0 &&
            (item.uploadUrl == null || item.uploadUrl!.isEmpty)) {
          // Skip items created within the last 30 seconds — addToQueue is
          // likely still fetching the URL. Let _processNextItem handle it.
          final created = DateTime.tryParse(item.createdAt);
          if (created != null &&
              DateTime.now().difference(created).inSeconds < 30) {
            AppLogger.i(
              '_loadQueue: pending item id=${item.id} is <30s old, '
              'skipping URL fetch (addToQueue will handle)',
            );
            continue;
          }
          AppLogger.i(
            '_loadQueue: pending item id=${item.id} has no uploadUrl '
            '— attempting to fetch fresh URL',
          );
          try {
            final freshUrls = await _fetchFreshUrls(item);
            if (freshUrls != null) {
              await UploadQueueRepository.updateUrls(
                id: item.id!,
                uploadUrl: freshUrls['uploadUrl']!,
                fileUrl: freshUrls['fileUrl']!,
              );
              AppLogger.i(
                '_loadQueue: restored URLs for item id=${item.id}',
              );
            } else {
              AppLogger.w(
                '_loadQueue: could not fetch fresh URL for item id=${item.id} '
                '— marking as failed so user can retry',
              );
              await UploadQueueRepository.markFailed(
                item.id!,
                'Failed to get upload URL. Tap to retry.',
              );
            }
          } catch (e) {
            AppLogger.e('_loadQueue: error refreshing URL for item id=${item.id}: $e');
            await UploadQueueRepository.markFailed(
              item.id!,
              'Failed to get upload URL. Tap to retry.',
            );
          }
        }
      }

      _queue = await UploadQueueRepository.getActive();
      if (_queue.isNotEmpty) {
        AppLogger.i(
          '_loadQueue: recovered ${_queue.length} active item(s) from DB',
        );
        for (final item in _queue) {
          final pct = item.fileSize > 0
              ? ((item.bytesUploaded / item.fileSize) * 100).round()
              : 0;
          AppLogger.i(
            '_loadQueue:   id=${item.id} type=${item.uploadType} '
            'status=${item.status} progress=$pct% '
            'title="${item.title}"',
          );
        }
        final uploadingItems = _queue.where(
          (item) => item.status == 'uploading',
        );
        final uploadingItem = uploadingItems.isNotEmpty
            ? uploadingItems.first
            : null;
        _activeItem = uploadingItem ?? _queue.first;
        _activeProgress = _activeItem!.fileSize > 0
            ? ((_activeItem!.bytesUploaded / _activeItem!.fileSize) * 100)
                  .round()
            : 0;
        AppLogger.i(
          '_loadQueue: activeItem id=${_activeItem?.id} '
          'progress=$_activeProgress%',
        );
      }
      notifyListeners();

      // Re-enqueue any pending items that have uploadUrl set
      _processNextItem();
    } catch (e) {
      AppLogger.e('_loadQueue error: $e');
      _queue = [];
    }
  }

  String _inferContentType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
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

  /// Resolves the MIME content type for a queue item.
  /// For resources, reads from the stored metadata to preserve the
  /// type inferred at queue-time by [_inferResourceContentType].
  /// For everything else, falls back to [_inferContentType].
  String _resolveContentType(UploadQueueItem item) {
    if (item.uploadType == 'resource' && item.metadata != null) {
      try {
        final meta = ModuleLessonMetadata.fromJson(jsonDecode(item.metadata!));
        if (meta.contentType != null && meta.contentType!.isNotEmpty) {
          return meta.contentType!;
        }
      } catch (_) {}
    }
    return _inferContentType(item.filePath);
  }

  Future<bool> _hasInFlightFile(String filePath, {String? uploadType}) async {
    return await UploadQueueRepository.hasInFlightFile(
      filePath: filePath,
      uploadType: uploadType,
    );
  }

  /// Find and enqueue the next pending item that isn't already tracked
  /// by a live WorkManager task.
  ///
  /// Sets [_isUploading] synchronously at entry to prevent race conditions
  /// across async gaps (callers may fire this concurrently).
  Future<bool> _processNextItem() async {
    if (_isUploading) return false;
    _isUploading = true;
    _isUploadingSince = DateTime.now();

    // Preserve FIFO: if a native upload is already running (from before
    // app restart), don't start the next pending item yet.
    final existing = await UploadQueueRepository.getActive();
    if (existing.any((i) => i.status == 'uploading' && i.workerId != null && i.workerId!.isNotEmpty)) {
      AppLogger.i('_processNextItem: native upload active, deferring FIFO');
      _isUploading = false;
      _isUploadingSince = null;
      return false;
    }

    UploadQueueItem? candidate;
    try {
      candidate = await UploadQueueRepository.claimNextPendingItem();

      if (candidate == null || candidate.id == null) {
        AppLogger.i('_processNextItem: no item to enqueue');
        _isUploading = false;
        _isUploadingSince = null;
        return false;
      }

      AppLogger.i('_processNextItem: claimed pending item id=${candidate.id}');

      _queue = await UploadQueueRepository.getActive();
      _activeItem = candidate;
      _activeProgress = candidate.bytesUploaded > 0
          ? ((candidate.bytesUploaded / candidate.fileSize) * 100).round()
          : 0;
      notifyListeners();

      // Refresh URLs if the presigned URL may have expired while
      // waiting in the queue (resources: 1 h expiry, videos: 24 h).
      if (_isUrlStale(candidate)) {
        final freshUrls = await _fetchFreshUrls(candidate);
        if (freshUrls == null) {
          AppLogger.e(
            '_processNextItem: URL refresh failed for id=${candidate.id}',
          );
          await UploadQueueRepository.markFailed(
            candidate.id!,
            'Upload URL expired and could not be refreshed',
          );
          await _onItemTerminal(candidate.id!);
          return false;
        }
        await UploadQueueRepository.updateUrls(
          id: candidate.id!,
          uploadUrl: freshUrls['uploadUrl']!,
          fileUrl: freshUrls['fileUrl']!,
        );
        candidate = candidate.copyWith(
          uploadUrl: freshUrls['uploadUrl']!,
          fileUrl: freshUrls['fileUrl']!,
          lastUpdated: DateTime.now().toIso8601String(),
        );
        _activeItem = candidate;
        AppLogger.i('_processNextItem: URL refreshed for id=${candidate.id}');
      }

      _activeItem ??= candidate;
      _activeProgress = 0;
      // background_downloader already runs as a foreground service
      // (Config.runInForeground = Config.always), so no Dart-side
      // background service is needed.
      await UploadQueueRepository.updateStatus(
        id: candidate.id!,
        status: 'uploading',
      );
      notifyListeners();

      // Compute callback details for native execution after S3 upload.
      // Stored in task.metaData so native Kotlin code fires the server
      // callback directly — survives app kill.
      final callbackDetails = _buildCallbackDetails(candidate);
      final token = AuthController.accessToken;
      final callbackBody = callbackDetails != null
          ? jsonEncode(callbackDetails.body)
          : null;

      final idempotencyKey =
          '${candidate.uploadId ?? candidate.id}_callback';
      final taskId = await BackgroundUploaderService.enqueueUpload(
        itemId: candidate.id!,
        filePath: candidate.filePath,
        uploadUrl: candidate.uploadUrl!,
        contentType: _resolveContentType(candidate),
        displayName: candidate.title,
        callbackUrl: callbackDetails?.url,
        authToken: token != null ? 'Bearer $token' : null,
        callbackBody: callbackBody,
        idempotencyKey: idempotencyKey,
      );

      if (taskId == null) {
        AppLogger.e(
          '_processNextItem: enqueueUpload returned null for id=${candidate.id}',
        );
        await UploadQueueRepository.markFailed(
          candidate.id!,
          'Failed to start native upload',
        );
        await _onItemTerminal(candidate.id!);
        return false;
      }
      AppLogger.i('_processNextItem: enqueued successfully, taskId=$taskId');

      await UploadQueueRepository.updateWorkerId(
        id: candidate.id!,
        workerId: taskId,
      );
      return true;
    } catch (e) {
      AppLogger.e('_processNextItem: exception: $e');
      _isUploading = false;
      _isUploadingSince = null;
      if (candidate != null && _activeItem?.id == candidate.id) {
        _activeItem = null;
        _activeProgress = 0;
      }
      if (candidate != null && candidate.id != null) {
        await UploadQueueRepository.markFailed(
          candidate.id!,
          'Enqueue error: $e',
        );
        await _onItemTerminal(candidate.id!);
      }
      return false;
    }
  }

  /// Whether the item's presigned upload URL is likely expired.
  /// Resource URLs expire in ~1 hour, video URLs in ~24 hours.
  bool _isUrlStale(UploadQueueItem item) {
    final age = DateTime.now().difference(DateTime.parse(item.lastUpdated));
    final limit = item.uploadType == 'resource'
        ? const Duration(minutes: 50)
        : const Duration(hours: 23);
    return age > limit;
  }

  /// Fetch a fresh presigned URL for an item that has been waiting in the
  /// queue long enough that its original URL may have expired.
  /// Reusable from [retryFailed] / [_retryItem] and [_processNextItem].
  Future<Map<String, String>?> _fetchFreshUrls(UploadQueueItem item) async {
    String endpoint;
    Map<String, dynamic> Function(String) buildPayload;
    Map<String, dynamic> extraFields = {};

    switch (item.uploadType) {
      case 'course':
        endpoint = Urls.courseAssetsUploadUrl;
        buildPayload = (name) => {
          'thumbnailFilename': name,
          'thumbnailContentType': BackgroundUploadService.inferImageContentType(
            name,
          ),
        };
        break;
      case 'module_lesson':
        endpoint = Urls.courseModuleUploadUrl;
        buildPayload = (name) => {
          'videoFilename': name,
          'videoContentType': BackgroundUploadService.inferVideoContentType(
            name,
          ),
        };
        if (item.metadata != null) {
          final meta = ModuleLessonMetadata.fromJson(
            jsonDecode(item.metadata!),
          );
          extraFields = {'moduleID': meta.moduleId};
        }
        break;
      case 'resource':
        endpoint = Urls.courseModuleResourceUploadUrl;
        buildPayload = (name) {
          final ct = item.metadata != null
              ? (jsonDecode(item.metadata!) as Map)['contentType'] ??
                    'application/octet-stream'
              : 'application/octet-stream';
          return {'filename': name, 'contentType': ct};
        };
        break;
      case 'course_intro':
        endpoint = Urls.courseAssetsUploadUrl;
        buildPayload = (name) => {
          'thumbnailFilename': 'keep.jpg',
          'thumbnailContentType': 'image/jpeg',
          'videoFilename': name,
          'videoContentType': BackgroundUploadService.inferVideoContentType(
            name,
          ),
        };
        break;
      default:
        // video_post
        endpoint = Urls.videoPostAssetsUploadUrl;
        buildPayload = (name) => {
          'videoFilename': name,
          'videoContentType': BackgroundUploadService.inferVideoContentType(
            name,
          ),
        };
    }

    return BackgroundUploadService.fetchPresignedUrl(
      filePath: item.filePath,
      endpoint: endpoint,
      buildPayload: buildPayload,
      extraFields: extraFields,
    );
  }

  // ──────────────────────────────────────────────
  //  Native callback handlers (called from registered
  //  TaskStatusCallback / TaskProgressCallback)
  // ──────────────────────────────────────────────

  Future<void> _onNativeTaskStatus(TaskStatusUpdate update) async {
    final itemId = _extractItemId(update.task);
    AppLogger.i(
      '_onNativeTaskStatus: item=$itemId status=${update.status} taskId=${update.task.taskId}',
    );
    if (itemId == null) return;

    // Skip if item already reached a terminal state (e.g. cancelled then a
    // stale 'failed' arrives from the now-stopped native worker's finally block)
    final allItems = await UploadQueueRepository.getAll();
    final item = allItems.where((i) => i.id == itemId).firstOrNull;
    if (item == null) return;
    if (item.status == 'completed' || item.status == 'cancelled') {
      AppLogger.i(
        '_onNativeTaskStatus: item=$itemId already ${item.status}, skipping',
      );
      return;
    }

    switch (update.status) {
      case TaskStatus.complete:
        await _handleNativeComplete(itemId, update.task.taskId);
        break;
      case TaskStatus.failed:
        await UploadQueueRepository.markFailed(itemId, 'Native upload failed');
        await _onItemTerminal(itemId);
        break;
      case TaskStatus.canceled:
        await UploadQueueRepository.updateStatus(
          id: itemId,
          status: 'cancelled',
        );
        await UploadQueueRepository.updateWorkerId(id: itemId, workerId: '');
        await _onItemTerminal(itemId);
        break;
      default:
        break;
    }
  }

  Future<void> _onNativeTaskProgress(TaskProgressUpdate update) async {
    final itemId = _extractItemId(update.task);
    if (itemId == null) return;

    _progressUpdateCount++;

    // background_downloader uses negative sentinel values for special
    // states: -4.0 = waitingToRetry, -1.0 = failed, -2.0 = canceled, etc.
    // Clamp to 0..100 so the UI never shows "-400%".
    final pct = max(0, (update.progress * 100).round());
    AppLogger.i('_onNativeTaskProgress: item=$itemId progress=$pct%');

    // Update in-memory state for immediate UI feedback.
    if (_activeItem?.id == itemId) {
      _activeProgress = pct;
      notifyListeners();
    }

    // Persist progress to SQLite so it survives app restart.
    // Throttle: only write when crossing a whole-percent boundary to
    // avoid thousands of writes during a multi-GB upload.
    if (update.progress >= 0) {
      final items = await UploadQueueRepository.getAll();
      final item = items.where((i) => i.id == itemId).firstOrNull;
      if (item != null && item.fileSize > 0) {
        final bytes = (update.progress * item.fileSize).round();
        if (bytes > item.bytesUploaded) {
          await UploadQueueRepository.updateProgress(
            id: itemId,
            bytesUploaded: bytes,
          );
          // Native background_downloader notification handles progress display
          // via configureNotificationForGroup — no Dart-side notification needed.
        }
      }
    }

    // Periodic WAL checkpoint every 200 progress ticks (~every 100s)
    // to prevent unbounded WAL growth during long uploads.
    if (_progressUpdateCount % 200 == 0) {
      unawaited(UploadQueueRepository.checkpointWal());
    }
  }

  int? _extractItemId(Task task) {
    if (task.metaData.isEmpty) return null;
    try {
      final map = jsonDecode(task.metaData) as Map<String, dynamic>;
      return map['itemId'] as int?;
    } catch (_) {
      return null;
    }
  }

  /// Called when the native S3 upload completes (TaskStatus.complete).
  /// Sends the server callback, then marks the item complete.
  Future<void> _handleNativeComplete(int itemId, String taskId) async {
    if (!_handlingNativeComplete.add(itemId)) {
      AppLogger.w(
        '_handleNativeComplete: already handling item=$itemId, skipping',
      );
      return;
    }
    AppLogger.i('_handleNativeComplete: item=$itemId taskId=$taskId');
    try {
      await UploadQueueRepository.markNativeCompleted(itemId);

      final all = await UploadQueueRepository.getAll();
      final item = all.where((i) => i.id == itemId).firstOrNull;
      if (item == null) {
        await _onItemTerminal(itemId);
        return;
      }

      final callbackSent = await _sendCallbackForItem(item);
      if (!callbackSent) {
        // S3 upload succeeded but server callback failed (e.g. auth token
        // not ready on restart, network issue). DON'T mark as failed —
        // keep as 'uploading' with nativeMarkedCompleted=1 so the retry
        // loop (in _loadQueue + _queuePump) picks it up on the next cycle.
        AppLogger.w(
          '_handleNativeComplete: callback failed for item $itemId '
          '— will retry on next queue pump cycle',
        );
        await _onItemTerminal(itemId);
        return;
      }

      await UploadQueueRepository.markCallbackCompleted(itemId);
      await UploadQueueRepository.markCompleted(itemId);
      await _cleanupCachedFile(item.filePath);
      await _onItemTerminal(itemId);
    } catch (e) {
      AppLogger.e('_handleNativeComplete error for item $itemId: $e');
      // Don't mark as failed — same retry logic as above
      await _onItemTerminal(itemId);
    } finally {
      _handlingNativeComplete.remove(itemId);
    }
  }

  /// Send server callback after S3 upload completes.
  /// Reconstructs the callback body from the item's metadata and uploadType.
  Future<bool> _sendCallbackForItem(UploadQueueItem item) async {
    final token = AuthController.accessToken;
    if (token == null) {
      AppLogger.w('_sendCallbackForItem: no auth token');
      return false;
    }

    final details = _buildCallbackDetails(item);
    if (details == null) return false;

    return BackgroundUploaderService.sendServerCallback(
      callbackUrl: details.url,
      authToken: token,
      body: details.body,
      idempotencyKey: '${item.uploadId ?? item.id}_callback',
    );
  }

  _CallbackDetails? _buildCallbackDetails(UploadQueueItem item) {
    switch (item.uploadType) {
      case 'course':
        final meta = item.metadata != null
            ? CourseUploadMetadata.fromJson(jsonDecode(item.metadata!))
            : null;
        return _CallbackDetails(
          url: Urls.createCourseUrl,
          body: {
            'title': meta?.courseTitle ?? item.title,
            'description': meta?.description ?? '',
            'shortDescription': meta?.shortDescription ?? '',
            'requirements': meta?.requirements ?? '',
            'thumbnailUrl': item.fileUrl,
            if (meta?.videoPath != null) 'introVideoUrl': meta!.videoPath,
            'language': meta?.language ?? '',
            'level': (meta?.level ?? '').toUpperCase(),
            'type': (meta?.type ?? 'FREE').toUpperCase(),
            'price': meta?.price ?? 0,
          },
        );

      case 'module_lesson':
        final meta = item.metadata != null
            ? ModuleLessonMetadata.fromJson(jsonDecode(item.metadata!))
            : null;
        return _CallbackDetails(
          url: Urls.courseModuleLessonUrl,
          body: {
            'title': meta?.lessonTitle ?? item.title,
            'moduleId': meta?.moduleId,
            'videoUrl': item.fileUrl,
            'duration': item.videoDuration,
            'fileSize': item.fileSize,
          },
        );

      case 'resource':
        final meta = item.metadata != null
            ? ModuleLessonMetadata.fromJson(jsonDecode(item.metadata!))
            : null;
        final ct = meta?.contentType ?? 'application/octet-stream';
        return _CallbackDetails(
          url: Urls.courseModuleResourceUrl,
          body: {
            'title': meta?.lessonTitle ?? item.title,
            'fileUrl': item.fileUrl,
            'moduleId': meta?.moduleId,
            'fileType': ct,
            'fileSize': item.fileSize,
          },
        );

      case 'course_intro':
        return _CallbackDetails(
          url: Urls.courseAssetsUploadUrl,
          body: {'title': item.title, 'videoUrl': item.fileUrl},
        );

      default:
        // video_post
        return _CallbackDetails(
          url: Urls.videoPostUrl,
          body: {
            'title': item.title,
            'videoUrl': item.fileUrl,
            'duration': item.videoDuration,
            'fileSize': item.fileSize,
          },
        );
    }
  }

  /// Called when an item reaches a terminal state (completed/failed/cancelled).
  /// Releases the queue lock (only if [id] matches the currently active item)
  /// and starts the next pending item if any.
  Future<void> _onItemTerminal(int id) async {
    if (_activeItem?.id == id) {
      _isUploading = false;
      _isUploadingSince = null;
      _activeItem = null;
      _activeProgress = 0;
    }
    _queue = await UploadQueueRepository.getActive();
    notifyListeners();
    _processNextItem();
  }

  // ──────────────────────────────────────────────
  //  Public queue methods
  // ──────────────────────────────────────────────

  /// Video post: queue → fetch presigned URL → start upload.
  Future<bool> addToQueue(File file, String title) async {
    try {
      if (await _hasInFlightFile(file.path)) {
        ToastService.showError('This file is already being uploaded');
        return false;
      }

      final duration = await VideoMetadataHelper.getDurationSeconds(file.path);
      final fileSize = await VideoMetadataHelper.getFileSizeBytes(file.path);

      final permission = await _ensureNotificationPermission();
      if (!permission) {
        ToastService.showError('Notification permission required to upload');
        return false;
      }

      final item = UploadQueueItem(
        filePath: file.path,
        title: title,
        videoDuration: duration,
        fileSize: fileSize,
        status: 'pending',
        uploadType: 'video_post',
      );

      final insertResult = await UploadQueueRepository.insert(item);
      final id = insertResult['id'] as int;

      // Fetch URL FIRST, then notify (avoids _loadQueue seeing a
      // URL-less pending item and racing a duplicate URL fetch).
      final urls = await BackgroundUploadService.fetchPresignedUrl(
        filePath: file.path,
        endpoint: Urls.videoPostAssetsUploadUrl,
        buildPayload: (name) => {
          'videoFilename': name,
          'videoContentType': BackgroundUploadService.inferVideoContentType(name),
        },
      );
      if (urls == null) {
        await _cleanupFailedUpload(id, file.path);
        ToastService.showError('Failed to get upload URL');
        return false;
      }
      await UploadQueueRepository.updateUrls(
        id: id,
        uploadUrl: urls['uploadUrl']!,
        fileUrl: urls['fileUrl']!,
      );
      // Now safe to expose item to listeners (URL is set on DB row).
      _queue = await UploadQueueRepository.getActive();
      notifyListeners();

      if (_isUploading) {
        // Another upload is active (native FIFO lock).  The item was
        // inserted with a valid URL and will start when the current
        // upload finishes — no need to call _processNextItem.
        ToastService.showSuccess('Video queued for upload');
        return true;
      }

      final enqueued = await _processNextItem();
      if (!enqueued) {
        ToastService.showError('Failed to start upload. Please try again.');
        return false;
      }
      ToastService.showSuccess('Video queued for upload');
      return true;
    } catch (e) {
      AppLogger.e('addToQueue error - $e');
      ToastService.showError('Failed to queue video. Please try again.');
      return false;
    }
  }

  Future<int> addCourseToQueue({
    required String thumbnailPath,
    String? videoPath,
    required String title,
    required String shortDescription,
    required String description,
    required String requirements,
    required String language,
    required String level,
    required String type,
    required double price,
    String? introVideoUrl,
  }) async {
    final meta = CourseUploadMetadata(
      courseTitle: title,
      shortDescription: shortDescription,
      description: description,
      requirements: requirements,
      language: language,
      level: level,
      type: type,
      price: price,
      videoPath: introVideoUrl != null ? null : videoPath,
    );

    final metadataJson = jsonEncode(meta.toJson());
    final thumbFile = File(thumbnailPath);
    final thumbSize = await thumbFile.length();

    final permission = await _ensureNotificationPermission();
    if (!permission) {
      ToastService.showError('Notification permission required to upload');
      return 0;
    }

    final item = UploadQueueItem(
      filePath: thumbnailPath,
      title: 'Course: $title',
      fileSize: thumbSize,
      status: 'pending',
      uploadType: 'course',
      metadata: metadataJson,
    );

    final insertResult = await UploadQueueRepository.insert(item);
    final id = insertResult['id'] as int;
    _queue = await UploadQueueRepository.getActive();
    notifyListeners();

    final bool externalIntro = introVideoUrl != null;
    final String? effectiveVideoPath = externalIntro ? null : videoPath;

    final urls = await BackgroundUploadService.fetchCoursePresignedUrls(
      thumbnailPath: thumbnailPath,
      videoPath: effectiveVideoPath,
    );

    if (urls == null) {
      await _cleanupFailedUpload(id, thumbnailPath);
      ToastService.showError('Failed to get upload URLs');
      return 0;
    }

    final thumbnailUploadUrl = urls['thumbnailUploadUrl']!;
    final thumbnailFileUrl = urls['thumbnailFileUrl']!;

    if (!externalIntro && videoPath != null) {
      final videoUploadUrl = urls['videoUploadUrl'];
      final videoFileUrl = urls['videoFileUrl'];
      if (videoUploadUrl != null && videoFileUrl != null) {
        final videoItem = UploadQueueItem(
          filePath: videoPath,
          title: 'Course intro video: $title',
          fileSize: await File(videoPath).length(),
          status: 'pending',
          uploadType: 'course_intro',
          metadata: metadataJson,
        );
        final videoInsert = await UploadQueueRepository.insert(videoItem);
        final videoId = videoInsert['id'] as int;
        await UploadQueueRepository.updateUrls(
          id: videoId,
          uploadUrl: videoUploadUrl,
          fileUrl: videoFileUrl,
        );
        _queue = await UploadQueueRepository.getActive();
        notifyListeners();
      }
    }

    await UploadQueueRepository.updateUrls(
      id: id,
      uploadUrl: thumbnailUploadUrl,
      fileUrl: thumbnailFileUrl,
    );

    ToastService.showSuccess('Course upload queued');
    await _processNextItem();
    return id;
  }

  Future<String?> addCourseIntroVideo({
    required String filePath,
    required String title,
  }) async {
    try {
      if (await _hasInFlightFile(filePath)) {
        ToastService.showError('This video is already queued');
        return null;
      }

      final file = File(filePath);
      final fileSize = await file.length();

      final permission = await _ensureNotificationPermission();
      if (!permission) {
        ToastService.showError('Notification permission required to upload');
        return null;
      }

      final item = UploadQueueItem(
        filePath: filePath,
        title: title,
        fileSize: fileSize,
        status: 'pending',
        uploadType: 'course_intro',
      );

      final insertResult = await UploadQueueRepository.insert(item);
      final id = insertResult['id'] as int;
      _queue = await UploadQueueRepository.getActive();
      notifyListeners();

      final urls = await BackgroundUploadService.fetchCoursePresignedUrls(
        thumbnailPath: filePath,
        videoPath: filePath,
      );

      if (urls == null) {
        await _cleanupFailedUpload(id, filePath);
        ToastService.showError('Failed to get upload URL');
        return null;
      }

      final videoUploadUrl = urls['videoUploadUrl'];
      final videoFileUrl = urls['videoFileUrl'];
      if (videoUploadUrl == null || videoFileUrl == null) {
        await _cleanupFailedUpload(id, filePath);
        ToastService.showError('Server did not provide a video upload URL');
        return null;
      }

      await UploadQueueRepository.updateUrls(
        id: id,
        uploadUrl: videoUploadUrl,
        fileUrl: videoFileUrl,
      );

      ToastService.showSuccess('Intro video queued');
      await _processNextItem();
      return videoFileUrl;
    } catch (e) {
      AppLogger.e('addCourseIntroVideo error: $e');
      ToastService.showError('Failed to queue intro video');
      return null;
    }
  }

  Future<Map<String, String?>?> queueCourseEditAssets({
    String? thumbnailPath,
    String? videoPath,
    required int courseId,
    required String courseTitle,
  }) async {
    if (thumbnailPath == null && videoPath == null) return {};

    try {
      final urls = await BackgroundUploadService.fetchCoursePresignedUrls(
        thumbnailPath: thumbnailPath ?? videoPath!,
        videoPath: videoPath,
      );

      if (urls == null) {
        ToastService.showError('Failed to get upload URLs');
        return null;
      }

      if (thumbnailPath != null) {
        final thumbUploadUrl = urls['thumbnailUploadUrl'];
        final thumbFileUrl = urls['thumbnailFileUrl'];
        if (thumbUploadUrl != null && thumbFileUrl != null) {
          final item = UploadQueueItem(
            filePath: thumbnailPath,
            title: 'Course thumbnail: $courseTitle',
            fileSize: await File(thumbnailPath).length(),
            status: 'pending',
            uploadType: 'course_thumb',
          );
          final insert = await UploadQueueRepository.insert(item);
          final id = insert['id'] as int;
          await UploadQueueRepository.updateUrls(
            id: id,
            uploadUrl: thumbUploadUrl,
            fileUrl: thumbFileUrl,
          );
        }
      }

      if (videoPath != null) {
        final videoUploadUrl = urls['videoUploadUrl'];
        final videoFileUrl = urls['videoFileUrl'];
        if (videoUploadUrl != null && videoFileUrl != null) {
          final item = UploadQueueItem(
            filePath: videoPath,
            title: 'Course intro: $courseTitle',
            fileSize: await File(videoPath).length(),
            status: 'pending',
            uploadType: 'course_intro',
          );
          final insert = await UploadQueueRepository.insert(item);
          final id = insert['id'] as int;
          await UploadQueueRepository.updateUrls(
            id: id,
            uploadUrl: videoUploadUrl,
            fileUrl: videoFileUrl,
          );
        }
      }

      _queue = await UploadQueueRepository.getActive();
      await _processNextItem();
      ToastService.showSuccess('Assets queued for upload');

      return {
        'thumbnailFileUrl': urls['thumbnailFileUrl'],
        'videoFileUrl': urls['videoFileUrl'],
      };
    } catch (e) {
      AppLogger.e('queueCourseEditAssets error: $e');
      ToastService.showError('Failed to queue course assets');
      return null;
    }
  }

  /// Video lesson: queue → fetch presigned URL → start upload.
  Future<int> addModuleLessonToQueue({
    required String videoPath,
    required String lessonTitle,
    required int moduleId,
    required int courseId,
    int? lessonId,
  }) async {
    if (!File(videoPath).existsSync()) {
      AppLogger.w('addModuleLessonToQueue: file not found at $videoPath');
      ToastService.showError('Video file not found');
      return 0;
    }

    if (await _hasInFlightFile(videoPath, uploadType: 'module_lesson')) {
      AppLogger.w('addModuleLessonToQueue: file already queued at $videoPath');
      ToastService.showError('This video is already in the upload queue');
      return 0;
    }

    final permission = await _ensureNotificationPermission();
    if (!permission) {
      ToastService.showError('Notification permission required to upload');
      return 0;
    }

    final meta = ModuleLessonMetadata(
      moduleId: moduleId,
      courseId: courseId,
      lessonTitle: lessonTitle,
      lessonId: lessonId,
    );

    final metadataJson = jsonEncode(meta.toJson());
    final videoFile = File(videoPath);
    final fileSize = await videoFile.length();
    final duration = await VideoMetadataHelper.getDurationSeconds(videoPath);

    final item = UploadQueueItem(
      filePath: videoPath,
      title: lessonTitle,
      videoDuration: duration,
      fileSize: fileSize,
      status: 'pending',
      uploadType: 'module_lesson',
      metadata: metadataJson,
    );

    final insertResult = await UploadQueueRepository.insert(item);
    final id = insertResult['id'] as int;
    _queue = await UploadQueueRepository.getActive();
    notifyListeners();

    final urls = await BackgroundUploadService.fetchPresignedUrl(
      filePath: videoPath,
      endpoint: Urls.courseModuleUploadUrl,
      buildPayload: (name) => {
        'videoFilename': name,
        'videoContentType': BackgroundUploadService.inferVideoContentType(name),
      },
      extraFields: {'moduleID': moduleId},
    );

    if (urls == null) {
      await _cleanupFailedUpload(id, videoPath);
      ToastService.showError('Failed to get upload URL');
      return 0;
    }

    await UploadQueueRepository.updateUrls(
      id: id,
      uploadUrl: urls['uploadUrl']!,
      fileUrl: urls['fileUrl']!,
    );

    ToastService.showSuccess('Your video is being uploaded');
    await _processNextItem();
    return id;
  }

  /// Resource: queue → fetch presigned URL → start upload.
  Future<int> addResourceToQueue({
    required String filePath,
    required String lessonTitle,
    required int moduleId,
    required int courseId,
    required String contentType,
    int? lessonId,
  }) async {
    if (!File(filePath).existsSync()) {
      AppLogger.w('addResourceToQueue: file not found at $filePath');
      ToastService.showError('Resource file not found');
      return 0;
    }

    if (await _hasInFlightFile(filePath, uploadType: 'resource')) {
      AppLogger.w('addResourceToQueue: file already queued at $filePath');
      ToastService.showError('This resource is already in the upload');
      return 0;
    }

    final permission = await _ensureNotificationPermission();
    if (!permission) {
      ToastService.showError('Notification permission required to upload');
      return 0;
    }

    final meta = ModuleLessonMetadata(
      moduleId: moduleId,
      courseId: courseId,
      lessonTitle: lessonTitle,
      contentType: contentType,
      lessonId: lessonId,
    );

    final metadataJson = jsonEncode(meta.toJson());
    final resourceFile = File(filePath);
    final fileSize = await resourceFile.length();

    final item = UploadQueueItem(
      filePath: filePath,
      title: lessonTitle,
      fileSize: fileSize,
      status: 'pending',
      uploadType: 'resource',
      metadata: metadataJson,
    );

    final insertResult = await UploadQueueRepository.insert(item);
    final id = insertResult['id'] as int;
    _queue = await UploadQueueRepository.getActive();
    notifyListeners();

    final urls = await BackgroundUploadService.fetchPresignedUrl(
      filePath: filePath,
      endpoint: Urls.courseModuleResourceUploadUrl,
      buildPayload: (name) => {'filename': name, 'contentType': contentType},
    );

    if (urls == null) {
      await _cleanupFailedUpload(id, filePath);
      ToastService.showError('Failed to get upload URL');
      return 0;
    }

    await UploadQueueRepository.updateUrls(
      id: id,
      uploadUrl: urls['uploadUrl']!,
      fileUrl: urls['fileUrl']!,
    );

    ToastService.showSuccess('Your Resource is being uploaded');
    await _processNextItem();
    return id;
  }

  // ──────────────────────────────────────────────
  //  Fetch presigned URL and start upload (video_post)
  // ──────────────────────────────────────────────

  Future<void> _cleanupFailedUpload(int id, String filePath) async {
    await UploadQueueRepository.markFailed(id, 'Upload setup failed');
    await UploadQueueRepository.cleanupFileIfCached(filePath);
    _queue = await UploadQueueRepository.getActive();
    notifyListeners();
  }



  // ──────────────────────────────────────────────
  //  Permission helpers
  // ──────────────────────────────────────────────

  Future<bool> _ensureNotificationPermission() async {
    if (await UploadNotificationService.hasNotificationPermission())
      return true;

    final first =
        await UploadNotificationService.requestNotificationPermission();
    if (first) return true;

    final shouldRetry = await _showPermissionDialog(
      title: 'Notification Permission Required',
      content:
          'Background uploads need notification permission to show progress and keep the upload alive.',
      confirmText: 'Grant',
      cancelText: 'Not Now',
    );
    if (shouldRetry != true) return false;

    final second =
        await UploadNotificationService.requestNotificationPermission();
    if (second) return true;

    final openSettings = await _showPermissionDialog(
      title: 'Permission Permanently Denied',
      content:
          'Please enable notifications in System Settings to use background uploads.',
      confirmText: 'Open Settings',
      cancelText: 'Cancel',
    );
    if (openSettings == true) {
      await _openNotificationSettings();
    }
    return false;
  }

  Future<void> _openNotificationSettings() async {
    final exec = Platform.resolvedExecutable;
    final segments = exec.split('/');
    String? packageName;
    for (final segment in segments.reversed) {
      if (segment.contains('.') && !segment.startsWith('~~')) {
        packageName = segment.split('-').first;
        break;
      }
    }
    if (packageName != null && packageName.isNotEmpty) {
      await Process.run('am', [
        'start',
        '-a',
        'android.settings.APPLICATION_DETAILS_SETTINGS',
        '-d',
        'package:$packageName',
      ]);
    }
  }

  Future<bool?> _showPermissionDialog({
    required String title,
    required String content,
    required String confirmText,
    required String cancelText,
  }) {
    final ctx = App.navigatorKey.currentContext;
    if (ctx == null) return Future.value(false);
    return showDialog<bool>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelText),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  //  Queue management
  // ──────────────────────────────────────────────

  Future<void> pauseQueue() async {
    ToastService.showInfo(
      'Resource management handled by system notifications',
    );
  }

  Future<void> resumeQueue() async {
    _processNextItem();
    ToastService.showInfo('Upload assets resumed');
  }

  Future<void> cancelTask(int queueId) async {
    final items = await UploadQueueRepository.getAll();
    final item = items.where((i) => i.id == queueId).firstOrNull;
    if (item?.workerId != null && item!.workerId!.isNotEmpty) {
      await BackgroundUploaderService.cancelUploadByWorkerId(item.workerId!);
    }
    await UploadQueueRepository.updateStatus(id: queueId, status: 'cancelled');
    _queue.removeWhere((item) => item.id == queueId);
    if (_activeItem?.id == queueId) {
      _activeItem = null;
      _activeProgress = 0;
      _isUploading = false;
      _isUploadingSince = null;
      _processNextItem();
    }
    notifyListeners();
    ToastService.showInfo('Upload cancelled');
  }

  Future<void> removeItem(int queueId) async {
    final items = await UploadQueueRepository.getAll();
    final item = items.where((i) => i.id == queueId).firstOrNull;
    if (item?.workerId != null && item!.workerId!.isNotEmpty) {
      await BackgroundUploaderService.cancelUploadByWorkerId(item.workerId!);
    }
    await UploadQueueRepository.deleteItem(queueId);
    _queue.removeWhere((item) => item.id == queueId);
    if (_activeItem?.id == queueId) {
      _activeItem = null;
      _activeProgress = 0;
      _isUploading = false;
      _isUploadingSince = null;
    }
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    await UploadQueueRepository.clearCompleted();
    _queue.removeWhere((item) => item.status == 'completed');
    notifyListeners();
  }

  Future<void> retryFailed(int queueId) async {
    await UploadQueueRepository.incrementRetryCount(queueId);
    await UploadQueueRepository.updateStatus(
      id: queueId,
      status: 'pending',
      errorMessage: null,
    );
    await UploadQueueRepository.updateWorkerId(id: queueId, workerId: '');

    // Refresh queue from DB so the item is guaranteed to be in _queue
    _queue = await UploadQueueRepository.getActive();
    final item = _queue.firstWhere(
      (i) => i.id == queueId,
      orElse: () =>
          UploadQueueItem(filePath: '', title: '', status: '', uploadType: ''),
    );
    if (item.filePath.isEmpty) {
      AppLogger.w('retryFailed: queueId=$queueId not found in active queue');
      notifyListeners();
      return;
    }
    notifyListeners();

    final result = await _retryItem(item, queueId);
    if (result) {
      ToastService.showInfo('Retrying upload');
    }
  }

  Future<bool> _retryItem(UploadQueueItem item, int queueId) async {
    final urls = await _fetchFreshUrls(item);
    if (urls == null) {
      ToastService.showError('Failed to upload');
      return false;
    }

    await UploadQueueRepository.updateUrls(
      id: queueId,
      uploadUrl: urls['uploadUrl']!,
      fileUrl: urls['fileUrl']!,
    );

    _processNextItem();
    return true;
  }

  /// Legacy handler from simpler upload flow.
  /// Prefers the callback-based path via [_onNativeTaskStatus].
  /// Still releases the queue lock if this was the active item.
  void onNativeUploadCompleted(int id, String fileUrl) {
    UploadQueueRepository.markCompleted(id);
    final idx = _queue.indexWhere((item) => item.id == id);
    if (idx >= 0) {
      _queue[idx] = _queue[idx].copyWith(status: 'completed', fileUrl: fileUrl);
      _cleanupCachedFile(_queue[idx].filePath);
    }
    if (_activeItem?.id == id) {
      _activeItem = null;
      _activeProgress = 0;
      _isUploading = false;
      _isUploadingSince = null;
    }
    notifyListeners();
    ToastService.showSuccess('Upload completed');
  }

  Future<void> _cleanupCachedFile(String filePath) async {
    await UploadQueueRepository.cleanupFileIfCached(filePath);
  }

  /// Legacy handler from simpler upload flow.
  /// Releases the queue lock if this was the active item.
  void onNativeUploadFailed(int id, String error) {
    UploadQueueRepository.markFailed(id, error);
    final idx = _queue.indexWhere((item) => item.id == id);
    if (idx >= 0) {
      _queue[idx] = _queue[idx].copyWith(status: 'failed', errorMessage: error);
    }
    if (_activeItem?.id == id) {
      _isUploading = false;
      _isUploadingSince = null;
    }
    notifyListeners();
  }
}

class _CallbackDetails {
  final String url;
  final Map<String, dynamic> body;
  const _CallbackDetails({required this.url, required this.body});
}

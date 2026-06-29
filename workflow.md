# Upload Queue — Complete Workflow with Full Functions

## Legend

Each function is shown with **file path** and **line number** where it starts, followed by the complete source code.

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 0: Data Model & SQLite Layer
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### UploadQueueItem Model

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:16`

```dart
class UploadQueueItem {
  final int? id;
  final String filePath;
  final String title;
  final int videoDuration;
  final int fileSize;
  final String? uploadUrl;
  final String? fileUrl;
  final String status;
  final int bytesUploaded;
  final String? errorMessage;
  final String createdAt;
  final String lastUpdated;
  final String uploadType;
  final String? metadata;
  final String? uploadId;
  final String? workerId;
  final int? heartbeatMs;
  final int retryCount;
  final String? idempotencyKey;
  final int nativeMarkedCompleted;
  final int serverCallbackCompleted;

  UploadQueueItem({
    this.id,
    required this.filePath,
    required this.title,
    this.videoDuration = 0,
    this.fileSize = 0,
    this.uploadUrl,
    this.fileUrl,
    this.status = 'pending',
    this.bytesUploaded = 0,
    this.errorMessage,
    String? createdAt,
    String? lastUpdated,
    this.uploadType = 'video_post',
    this.metadata,
    this.uploadId,
    this.workerId,
    this.heartbeatMs,
    this.retryCount = 0,
    this.idempotencyKey,
    this.nativeMarkedCompleted = 0,
    this.serverCallbackCompleted = 0,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String(),
       lastUpdated = lastUpdated ?? DateTime.now().toIso8601String();

  UploadTaskType get taskType => UploadTaskType.fromDb(uploadType);

  bool get isNativeCompleted => nativeMarkedCompleted == 1;
  bool get isCallbackCompleted => serverCallbackCompleted == 1;

  T? parseMetadata<T>(T Function(Map<String, dynamic>) fromJson) {
    if (metadata == null || metadata!.isEmpty) return null;
    try {
      final map = jsonDecode(metadata!) as Map<String, dynamic>;
      return fromJson(map);
    } catch (_) {
      return null;
    }
  }

  UploadQueueItem copyWith({...});  // standard copyWith
  Map<String, dynamic> toMap() {...}  // serializes all fields
  factory UploadQueueItem.fromMap(Map<String, dynamic> map) {...}
}
```

### _generateUploadId

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:10`

```dart
String _generateUploadId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(0x7FFFFFFF);
  return 'up_${now}_$rand';
}
```

### UploadQueueRepository.insert

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:313`

```dart
static Future<Map<String, dynamic>> insert(UploadQueueItem item) async {
  final db = await database;
  final uploadId = item.uploadId ?? _generateUploadId();
  final map = item.copyWith(uploadId: uploadId).toMap();
  final id = await db.insert('upload_queue', map);
  AppLogger.i(
    'UploadQueueRepository: inserted item id=$id, uploadId=$uploadId, type=${item.uploadType}, title=${item.title}',
  );
  return {'id': id, 'uploadId': uploadId};
}
```

### UploadQueueRepository.hasInFlightFile

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:359`

```dart
static Future<bool> hasInFlightFile({
  required String filePath,
  String? uploadType,
}) async {
  final db = await database;
  final values = <Object?>[filePath, 'completed', 'failed', 'cancelled'];
  var where = 'filePath = ? AND status NOT IN (?, ?, ?)';
  if (uploadType != null) {
    where = '$where AND uploadType = ?';
    values.add(uploadType);
  }
  final result = await db.rawQuery(
    'SELECT COUNT(*) as cnt FROM upload_queue WHERE $where',
    values,
  );
  return ((result.first['cnt'] as int?) ?? 0) > 0;
}
```

### UploadQueueRepository.claimNextPendingItem

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:454`

```dart
static Future<UploadQueueItem?> claimNextPendingItem() async {
  final db = await database;
  return await db.transaction<UploadQueueItem?>((txn) async {
    final maps = await txn.query(
      'upload_queue',
      where:
          'status = ? AND uploadUrl IS NOT NULL AND uploadUrl != ? AND (workerId IS NULL OR workerId = ?)',
      whereArgs: ['pending', '', ''],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    final map = maps.first;
    final id = map['id'] as int;
    final now = DateTime.now().toIso8601String();
    final updated = await txn.update(
      'upload_queue',
      {'status': 'uploading', 'lastUpdated': now, 'errorMessage': null},
      where: 'id = ? AND status = ?',
      whereArgs: [id, 'pending'],
    );
    if (updated != 1) return null;
    return UploadQueueItem.fromMap({
      ...map,
      'status': 'uploading',
      'lastUpdated': now,
      'errorMessage': null,
    });
  });
}
```

### UploadQueueRepository.updateProgress

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:531`

```dart
static Future<void> updateProgress({
  required int id,
  required int bytesUploaded,
}) async {
  final db = await database;
  // Prevent out-of-order progress updates from moving the bar backward.
  await db.update(
    'upload_queue',
    {
      'bytesUploaded': bytesUploaded,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ? AND bytesUploaded < ?',
    whereArgs: [id, bytesUploaded],
  );
}
```

### UploadQueueRepository.markNativeCompleted

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:390`

```dart
static Future<void> markNativeCompleted(int id) async {
  final db = await database;
  await db.update(
    'upload_queue',
    {
      'nativeMarkedCompleted': 1,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

### UploadQueueRepository.markCallbackCompleted

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:403`

```dart
static Future<void> markCallbackCompleted(int id) async {
  final db = await database;
  await db.update(
    'upload_queue',
    {
      'serverCallbackCompleted': 1,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

### UploadQueueRepository.markCompleted

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:561`

```dart
static Future<void> markCompleted(int id) async {
  final db = await database;
  await _assertValidTransition(db, id, 'completed');
  await db.update(
    'upload_queue',
    {
      'status': 'completed',
      'bytesUploaded': 0,
      'nativeMarkedCompleted': 1,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

### UploadQueueRepository.markFailed

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:577`

```dart
static Future<void> markFailed(int id, String error) async {
  final db = await database;
  await _assertValidTransition(db, id, 'failed');
  await db.update(
    'upload_queue',
    {
      'status': 'failed',
      'errorMessage': error,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

### UploadQueueRepository.resetStaleUploading

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:701`

```dart
static Future<void> resetStaleUploading({
  Duration heartbeatTimeout = const Duration(minutes: 2),
  Duration fallbackTimeout = const Duration(minutes: 5),
}) async {
  final db = await database;
  final now = DateTime.now();
  final heartbeatCutoff = now
      .subtract(heartbeatTimeout)
      .millisecondsSinceEpoch;
  final fallbackCutoff = now.subtract(fallbackTimeout).toIso8601String();
  await db.rawUpdate(
    '''
    UPDATE upload_queue
    SET status = 'pending',
        workerId = NULL,
        errorMessage = NULL,
        lastUpdated = ?
    WHERE status = 'uploading'
    AND (
      (heartbeatMs IS NOT NULL AND heartbeatMs < ?)
      OR
      (heartbeatMs IS NULL AND lastUpdated < ?)
    )
  ''',
    [now.toIso8601String(), heartbeatCutoff, fallbackCutoff],
  );
  AppLogger.i(
    'UploadQueueRepository: reset stale uploading items '
    '(heartbeat < ${heartbeatTimeout.inMinutes}m or lastUpdated < ${fallbackTimeout.inMinutes}m)',
  );
}
```

### UploadQueueRepository.checkpointWal

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:193`

```dart
static Future<void> checkpointWal() async {
  try {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
  } catch (e) {
    AppLogger.w('checkpointWal: $e');
  }
}
```

### UploadQueueRepository.updateUrls

**File:** `lib/features/courses/data/repositories/upload_queue_repository.dart:513`

```dart
static Future<void> updateUrls({
  required int id,
  required String uploadUrl,
  required String fileUrl,
}) async {
  final db = await database;
  await db.update(
    'upload_queue',
    {
      'uploadUrl': uploadUrl,
      'fileUrl': fileUrl,
      'lastUpdated': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 1: Adding Items to Queue
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

All entry points live in `UnifiedUploadQueueProvider`:

**File:** `lib/features/courses/providers/unified_upload_queue_provider.dart`

### addToQueue (video_post)

**File:** `unified_upload_queue_provider.dart:1065`

```dart
Future<bool> addToQueue(File file, String title) async {
  try {
    // Persist before anything else: copy from image_picker's temp
    // cache dir to a permanent location so Android cache cleanup
    // can't delete it while the item waits in the queue.
    final persistentPath = await _persistFileIfNeeded(file.path);

    if (await _hasInFlightFile(persistentPath)) {
      ToastService.showError('This file is already being uploaded');
      return false;
    }

    final duration = await VideoMetadataHelper.getDurationSeconds(persistentPath);
    final fileSize = await VideoMetadataHelper.getFileSizeBytes(persistentPath);

    final permission = await _ensureNotificationPermission();
    if (!permission) {
      ToastService.showError('Notification permission required to upload');
      return false;
    }

    final item = UploadQueueItem(
      filePath: persistentPath,
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
      filePath: persistentPath,
      endpoint: Urls.videoPostAssetsUploadUrl,
      buildPayload: (name) => {
        'videoFilename': name,
        'videoContentType': BackgroundUploadService.inferVideoContentType(name),
      },
    );
    if (urls == null) {
      await _cleanupFailedUpload(id, persistentPath);
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

    // Check both the Dart lock and the native FIFO lock.  If either is
    // active the item will start when the current upload finishes.
    final hasActiveNative = (await UploadQueueRepository.getActive())
        .any((i) => i.status == 'uploading' && i.workerId != null && i.workerId!.isNotEmpty && !i.isNativeCompleted);

    if (_isUploading || hasActiveNative) {
      ToastService.showSuccess('Video queued for upload');
      return true;
    }

    final enqueued = await _processNextItem();
    if (!enqueued) {
      ToastService.showSuccess('Video queued for upload');
      return true;
    }
    ToastService.showSuccess('Video queued for upload');
    return true;
  } catch (e) {
    AppLogger.e('addToQueue error - $e');
    ToastService.showError('Failed to queue video. Please try again.');
    return false;
  }
}
```

### addModuleLessonToQueue

**File:** `unified_upload_queue_provider.dart:1407`

```dart
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

  final persistentPath = await _persistFileIfNeeded(videoPath);

  if (await _hasInFlightFile(persistentPath, uploadType: 'module_lesson')) {
    AppLogger.w('addModuleLessonToQueue: file already queued at $persistentPath');
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
  final videoFile = File(persistentPath);
  final fileSize = await videoFile.length();
  final duration = await VideoMetadataHelper.getDurationSeconds(persistentPath);

  final item = UploadQueueItem(
    filePath: persistentPath,
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
    filePath: persistentPath,
    endpoint: Urls.courseModuleUploadUrl,
    buildPayload: (name) => {
      'videoFilename': name,
      'videoContentType': BackgroundUploadService.inferVideoContentType(name),
    },
    extraFields: {'moduleID': moduleId},
  );

  if (urls == null) {
    await _cleanupFailedUpload(id, persistentPath);
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
```

### addCourseToQueue

**File:** `unified_upload_queue_provider.dart:1148`

```dart
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
  final persThumbnailPath = await _persistFileIfNeeded(thumbnailPath);
  final persVideoPath = videoPath != null
      ? await _persistFileIfNeeded(videoPath)
      : null;

  final meta = CourseUploadMetadata(
    courseTitle: title,
    shortDescription: shortDescription,
    description: description,
    requirements: requirements,
    language: language,
    level: level,
    type: type,
    price: price,
    videoPath: introVideoUrl != null ? null : persVideoPath,
  );

  final metadataJson = jsonEncode(meta.toJson());
  final thumbFile = File(persThumbnailPath);
  final thumbSize = await thumbFile.length();

  final permission = await _ensureNotificationPermission();
  if (!permission) {
    ToastService.showError('Notification permission required to upload');
    return 0;
  }

  final item = UploadQueueItem(
    filePath: persThumbnailPath,
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
  final String? effectiveVideoPath = externalIntro ? null : persVideoPath;

  final urls = await BackgroundUploadService.fetchCoursePresignedUrls(
    thumbnailPath: persThumbnailPath,
    videoPath: effectiveVideoPath,
  );

  if (urls == null) {
    await _cleanupFailedUpload(id, persThumbnailPath);
    ToastService.showError('Failed to get upload URLs');
    return 0;
  }

  final thumbnailUploadUrl = urls['thumbnailUploadUrl']!;
  final thumbnailFileUrl = urls['thumbnailFileUrl']!;

  if (!externalIntro && persVideoPath != null) {
    final videoUploadUrl = urls['videoUploadUrl'];
    final videoFileUrl = urls['videoFileUrl'];
    if (videoUploadUrl != null && videoFileUrl != null) {
      final videoItem = UploadQueueItem(
        filePath: persVideoPath,
        title: 'Course intro video: $title',
        fileSize: await File(persVideoPath).length(),
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
```

### addCourseIntroVideo

**File:** `unified_upload_queue_provider.dart:1254`

```dart
Future<String?> addCourseIntroVideo({
  required String filePath,
  required String title,
}) async {
  try {
    final persistentPath = await _persistFileIfNeeded(filePath);

    if (await _hasInFlightFile(persistentPath)) {
      ToastService.showError('This video is already queued');
      return null;
    }

    final file = File(persistentPath);
    final fileSize = await file.length();

    final permission = await _ensureNotificationPermission();
    if (!permission) {
      ToastService.showError('Notification permission required to upload');
      return null;
    }

    final item = UploadQueueItem(
      filePath: persistentPath,
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
      thumbnailPath: persistentPath,
      videoPath: persistentPath,
    );

    if (urls == null) {
      await _cleanupFailedUpload(id, persistentPath);
      ToastService.showError('Failed to get upload URL');
      return null;
    }

    final videoUploadUrl = urls['videoUploadUrl'];
    final videoFileUrl = urls['videoFileUrl'];
    if (videoUploadUrl == null || videoFileUrl == null) {
      await _cleanupFailedUpload(id, persistentPath);
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
```

### queueCourseEditAssets

**File:** `unified_upload_queue_provider.dart:1323`

```dart
Future<Map<String, String?>?> queueCourseEditAssets({
  String? thumbnailPath,
  String? videoPath,
  required int courseId,
  required String courseTitle,
}) async {
  if (thumbnailPath == null && videoPath == null) return {};

  try {
    final persThumbnailPath = thumbnailPath != null
        ? await _persistFileIfNeeded(thumbnailPath)
        : null;
    final persVideoPath = videoPath != null
        ? await _persistFileIfNeeded(videoPath)
        : null;

    final urls = await BackgroundUploadService.fetchCoursePresignedUrls(
      thumbnailPath: persThumbnailPath ?? persVideoPath!,
      videoPath: persVideoPath,
    );

    if (urls == null) {
      ToastService.showError('Failed to get upload URLs');
      return null;
    }

    if (persThumbnailPath != null) {
      final thumbUploadUrl = urls['thumbnailUploadUrl'];
      final thumbFileUrl = urls['thumbnailFileUrl'];
      if (thumbUploadUrl != null && thumbFileUrl != null) {
        final item = UploadQueueItem(
          filePath: persThumbnailPath,
          title: 'Course thumbnail: $courseTitle',
          fileSize: await File(persThumbnailPath).length(),
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

    if (persVideoPath != null) {
      final videoUploadUrl = urls['videoUploadUrl'];
      final videoFileUrl = urls['videoFileUrl'];
      if (videoUploadUrl != null && videoFileUrl != null) {
        final item = UploadQueueItem(
          filePath: persVideoPath,
          title: 'Course intro: $courseTitle',
          fileSize: await File(persVideoPath).length(),
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
```

### addResourceToQueue

**File:** `unified_upload_queue_provider.dart:1489`

```dart
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

  final persistentPath = await _persistFileIfNeeded(filePath);

  if (await _hasInFlightFile(persistentPath, uploadType: 'resource')) {
    AppLogger.w('addResourceToQueue: file already queued at $persistentPath');
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
  final resourceFile = File(persistentPath);
  final fileSize = await resourceFile.length();

  final item = UploadQueueItem(
    filePath: persistentPath,
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
    filePath: persistentPath,
    endpoint: Urls.courseModuleResourceUploadUrl,
    buildPayload: (name) => {'filename': name, 'contentType': contentType},
  );

  if (urls == null) {
    await _cleanupFailedUpload(id, persistentPath);
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
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 1 Helpers
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### _persistFileIfNeeded

**File:** `unified_upload_queue_provider.dart:1581`

```dart
Future<String> _persistFileIfNeeded(String filePath) async {
  final file = File(filePath);
  if (!file.existsSync()) {
    AppLogger.e('_persistFileIfNeeded: file not found at $filePath');
    return filePath;
  }
  final tempDir = await getTemporaryDirectory();
  // On Android getTemporaryDirectory() returns getCacheDir():
  //   /data/user/0/<pkg>/cache/
  // If the file is already outside cache, keep it in place.
  if (!filePath.startsWith(tempDir.path)) return filePath;
  final docsDir = await getApplicationDocumentsDirectory();
  final uploadsDir = Directory('${docsDir.path}/eduverse_uploads');
  if (!uploadsDir.existsSync()) {
    uploadsDir.createSync(recursive: true);
  }
  final baseName = filePath.split(RegExp(r'[\\/]')).last;
  final newPath = '${uploadsDir.path}/${DateTime.now().millisecondsSinceEpoch}_$baseName';
  await file.copy(newPath);
  AppLogger.i('_persistFileIfNeeded: copied $filePath → $newPath');
  return newPath;
}
```

### _hasInFlightFile

**File:** `unified_upload_queue_provider.dart:542`

```dart
Future<bool> _hasInFlightFile(String filePath, {String? uploadType}) async {
  return await UploadQueueRepository.hasInFlightFile(
    filePath: filePath,
    uploadType: uploadType,
  );
}
```

### _cleanupFailedUpload

**File:** `unified_upload_queue_provider.dart:1570`

```dart
Future<void> _cleanupFailedUpload(int id, String filePath) async {
  await UploadQueueRepository.markFailed(id, 'Upload setup failed');
  await UploadQueueRepository.cleanupFileIfCached(filePath);
  _queue = await UploadQueueRepository.getActive();
  notifyListeners();
}
```

### _ensureNotificationPermission

**File:** `unified_upload_queue_provider.dart:1609`

```dart
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
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 2: Queue Processing — _processNextItem
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**File:** `unified_upload_queue_provider.dart:554`

```dart
Future<bool> _processNextItem() async {
  if (_isUploading) return false;
  _isUploading = true;
  _isUploadingSince = DateTime.now();

  // Preserve FIFO: if a native upload is already running (from before
  // app restart), don't start the next pending item yet.
  final existing = await UploadQueueRepository.getActive();
  // Items where native upload completed but callback is pending
  // (isNativeCompleted=true) should not block FIFO — the queue pump
  // will retry the callback. Skip them so the next item can start.
  if (existing.any((i) => i.status == 'uploading' && i.workerId != null && i.workerId!.isNotEmpty && !i.isNativeCompleted)) {
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

    // Safety net: confirm the source file still exists on disk.
    // The file may have been in Android's cache dir and was cleaned
    // while the item was waiting in the queue.
    if (!File(candidate.filePath).existsSync()) {
      AppLogger.e(
        '_processNextItem: source file missing for id=${candidate.id} '
        '— ${candidate.filePath}',
      );
      await UploadQueueRepository.markFailed(
        candidate.id!,
        'Upload file no longer exists on device',
      );
      await _onItemTerminal(candidate.id!);
      return false;
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
```

### _isUrlStale

**File:** `unified_upload_queue_provider.dart:710`

```dart
bool _isUrlStale(UploadQueueItem item) {
  final age = DateTime.now().difference(DateTime.parse(item.lastUpdated));
  final limit = item.uploadType == 'resource'
      ? const Duration(minutes: 50)
      : const Duration(hours: 23);
  return age > limit;
}
```

### _fetchFreshUrls

**File:** `unified_upload_queue_provider.dart:721`

```dart
Future<Map<String, String>?> _fetchFreshUrls(UploadQueueItem item) async {
  String endpoint;
  Map<String, dynamic> Function(String) buildPayload;
  Map<String, dynamic> extraFields = {};

  switch (item.uploadType) {
    case 'course':
      endpoint = Urls.courseAssetsUploadUrl;
      buildPayload = (name) => {
        'thumbnailFilename': name,
        'thumbnailContentType': BackgroundUploadService.inferImageContentType(name),
      };
      break;
    case 'module_lesson':
      endpoint = Urls.courseModuleUploadUrl;
      buildPayload = (name) => {
        'videoFilename': name,
        'videoContentType': BackgroundUploadService.inferVideoContentType(name),
      };
      if (item.metadata != null) {
        final meta = ModuleLessonMetadata.fromJson(jsonDecode(item.metadata!));
        extraFields = {'moduleID': meta.moduleId};
      }
      break;
    case 'resource':
      endpoint = Urls.courseModuleResourceUploadUrl;
      buildPayload = (name) {
        final ct = item.metadata != null
            ? (jsonDecode(item.metadata!) as Map)['contentType'] ?? 'application/octet-stream'
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
        'videoContentType': BackgroundUploadService.inferVideoContentType(name),
      };
      break;
    case 'course_thumb':
      endpoint = Urls.courseAssetsUploadUrl;
      buildPayload = (name) => {
        'thumbnailFilename': name,
        'thumbnailContentType': BackgroundUploadService.inferImageContentType(name),
      };
      break;
    default:
      // video_post
      endpoint = Urls.videoPostAssetsUploadUrl;
      buildPayload = (name) => {
        'videoFilename': name,
        'videoContentType': BackgroundUploadService.inferVideoContentType(name),
      };
  }

  return BackgroundUploadService.fetchPresignedUrl(
    filePath: item.filePath,
    endpoint: endpoint,
    buildPayload: buildPayload,
    extraFields: extraFields,
  );
}
```

### _resolveContentType

**File:** `unified_upload_queue_provider.dart:530`

```dart
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
```

### _buildCallbackDetails

**File:** `unified_upload_queue_provider.dart:966`

```dart
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

    case 'course_thumb':
      return _CallbackDetails(
        url: Urls.courseAssetsUploadUrl,
        body: {'thumbnailUrl': item.fileUrl},
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
```

### BackgroundUploaderService.enqueueUpload

**File:** `lib/features/courses/services/background_uploader_service.dart:20`

```dart
static Future<String?> enqueueUpload({
  required int itemId,
  required String filePath,
  required String uploadUrl,
  required String contentType,
  String displayName = '',
  String? callbackUrl,
  String? authToken,
  String? callbackBody,
  String? idempotencyKey,
}) async {
  if (displayName.isEmpty) {
    displayName = filePath.split(RegExp(r'[\\/]')).last;
  }
  final metaData = jsonEncode({
    'itemId': itemId,
    if (callbackUrl != null) 'callbackUrl': callbackUrl,
    if (authToken != null) 'authToken': authToken,
    if (callbackBody != null) 'callbackBody': callbackBody,
    if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
  });
  final task = UploadTask.fromFile(
    file: File(filePath),
    url: uploadUrl,
    httpRequestMethod: 'PUT',
    post: 'binary',
    mimeType: contentType,
    displayName: displayName,
    metaData: metaData,
    retries: 10,
    updates: Updates.statusAndProgress,
    group: 'upload_queue',
  );

  AppLogger.i('enqueueUpload: calling enqueue for taskId=${task.taskId}');
  final ok = await FileDownloader().enqueue(task);
  if (!ok) {
    AppLogger.e('enqueueUpload: enqueue returned false for item $itemId');
    return null;
  }
  AppLogger.i('enqueueUpload: success, taskId=${task.taskId}');
  return task.taskId;
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 3: Native Kotlin S3 Upload
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### TaskRunner.run() — Entry Point

**File:** `packages/background_downloader/android/src/main/kotlin/.../TaskRunner.kt:522`

```kotlin
open suspend fun run() {
    prefs = PreferenceManager.getDefaultSharedPreferences(context.appContext)
    runInForegroundFileSize =
        prefs.getInt(BDPlugin.keyConfigForegroundFileSize, -1)
    withContext(Dispatchers.IO) {
        CoroutineScope(Dispatchers.Default).launch {
            delay(taskTimeoutMillis)
            isTimedOut = true
        }
        task = context.task
        // ... optional before-start callback ...
        var status = TaskStatus.failed
        try {
            task = getModifiedTask(context = context.appContext, task = task)
            // ...
            status = doTask()
        } catch (e: Exception) {
            // ...
        } finally {
            withContext(NonCancellable) {
                processStatusUpdate(
                    task, status, prefs, taskException,
                    responseBody, responseHeaders, responseStatusCode,
                    mimeType, charSet, context.appContext
                )
                // update notification, notify holding queue
            }
        }
    }
    hasDeliveredResult = true
}
```

### processStatusUpdate — Status Dispatch to Dart

**File:** `TaskRunner.kt:144`

```kotlin
suspend fun processStatusUpdate(
    task: Task, status: TaskStatus, prefs: SharedPreferences,
    taskException: TaskException? = null,
    responseBody: String? = null,
    responseHeaders: Map<String, String>? = null,
    responseStatusCode: Int? = null,
    mimeType: String? = null, charSet: String? = null,
    context: Context
) {
    // Handle re-enqueue for WiFi requirement changes
    // ... (lines 156-176)

    val modifiedStatus = ...

    // Process final progress update
    when (modifiedStatus) {
        TaskStatus.complete -> processProgressUpdate(task, 1.0, prefs)
        TaskStatus.failed -> if (!retryNeeded) processProgressUpdate(task, -1.0, prefs)
        TaskStatus.canceled -> { ... }
        TaskStatus.notFound -> processProgressUpdate(task, -3.0, prefs)
        TaskStatus.paused -> processProgressUpdate(task, -5.0, prefs)
    }

    // Build TaskStatusUpdate with full or limited data
    val taskStatusUpdate = ...

    // Post status update to Dart via BackgroundChannel
    if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
        val arg = taskStatusUpdate.argList
        postOnBackgroundChannel("statusUpdate", task, arg, onFail = {
            storeLocally(BDPlugin.keyStatusUpdateMap, task.taskId,
                Json.encodeToString<TaskStatusUpdate>(taskStatusUpdate), prefs)
        })
    }

    // ⛔ NATIVE SERVER CALLBACK REMOVED ⛔
    // Previously called processUploadCompleteCallback() here, which
    // fired the same HTTP POST as Dart's _sendCallbackForItem(),
    // causing duplicate server records. Dart handles callback retry
    // via _loadQueue + _queuePump.

    // Cleanup for final states
    if (modifiedStatus.isFinalState()) {
        // Cancel WorkManager job (on failure), remove task from prefs,
        // invoke onTaskFinishedCallback if configured
        // ...
    }
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 4: Completion & Server Callback (Dart)
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### _onNativeTaskStatus — Entry from Native

**File:** `unified_upload_queue_provider.dart:805`

```dart
Future<void> _onNativeTaskStatus(TaskStatusUpdate update) async {
  final itemId = _extractItemId(update.task);
  AppLogger.i(
    '_onNativeTaskStatus: item=$itemId status=${update.status} taskId=${update.task.taskId}',
  );
  if (itemId == null) return;

  // Skip if item already reached a terminal state
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
      await UploadQueueRepository.updateStatus(id: itemId, status: 'cancelled');
      await UploadQueueRepository.updateWorkerId(id: itemId, workerId: '');
      await _onItemTerminal(itemId);
      break;
    default:
      break;
  }
}
```

### _onNativeTaskProgress

**File:** `unified_upload_queue_provider.dart:845`

```dart
Future<void> _onNativeTaskProgress(TaskProgressUpdate update) async {
  final itemId = _extractItemId(update.task);
  if (itemId == null) return;

  _progressUpdateCount++;

  // background_downloader uses negative sentinel values for special
  // states: -4.0 = waitingToRetry, -1.0 = failed, -2.0 = canceled, etc.
  final pct = max(0, (update.progress * 100).round());
  AppLogger.i('_onNativeTaskProgress: item=$itemId progress=$pct%');

  // Update in-memory state for immediate UI feedback.
  if (_activeItem?.id == itemId) {
    _activeProgress = pct;
    notifyListeners();
  }

  // Persist progress to SQLite so it survives app restart.
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
      }
    }
  }

  // Periodic WAL checkpoint every 200 progress ticks (~every 100s)
  if (_progressUpdateCount % 200 == 0) {
    unawaited(UploadQueueRepository.checkpointWal());
  }
}
```

### _extractItemId

**File:** `unified_upload_queue_provider.dart:889`

```dart
int? _extractItemId(Task task) {
  if (task.metaData.isEmpty) return null;
  try {
    final map = jsonDecode(task.metaData) as Map<String, dynamic>;
    return map['itemId'] as int?;
  } catch (_) {
    return null;
  }
}
```

### _handleNativeComplete

**File:** `unified_upload_queue_provider.dart:901`

```dart
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
    await _onItemTerminal(itemId);
  } finally {
    _handlingNativeComplete.remove(itemId);
  }
}
```

### _sendCallbackForItem

**File:** `unified_upload_queue_provider.dart:948`

```dart
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
```

### BackgroundUploaderService.sendServerCallback

**File:** `lib/features/courses/services/background_uploader_service.dart:67`

```dart
static Future<bool> sendServerCallback({
  required String callbackUrl,
  required String authToken,
  required Map<String, dynamic> body,
  String? idempotencyKey,
}) async {
  try {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $authToken',
    };
    if (idempotencyKey != null) {
      headers['Idempotency-Key'] = idempotencyKey;
    }
    final response = await http
        .post(
          Uri.parse(callbackUrl),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    return response.statusCode == 200 ||
        response.statusCode == 201 ||
        response.statusCode == 409;
  } catch (e) {
    AppLogger.e('sendServerCallback error: $e');
    return false;
  }
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 5: Queue Advancement
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### _onItemTerminal

**File:** `unified_upload_queue_provider.dart:1048`

```dart
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
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## PHASE 6: Initialization & Recovery
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### _init — Called on Provider construction

**File:** `unified_upload_queue_provider.dart:62`

```dart
Future<void> _init() async {
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
    running: TaskNotification('Uploading {displayName}', '{progress} completed'),
    complete: TaskNotification('Upload complete', '{displayName} uploaded successfully'),
    error: TaskNotification('Upload failed', '{displayName} — tap to retry'),
    progressBar: true,
  );

  await FileDownloader().start(
    doTrackTasks: true,
    doRescheduleKilledTasks: true,
  );

  // Give re-fired callbacks a moment to arrive before we inspect the queue.
  await Future<void>.delayed(const Duration(milliseconds: 500));

  await _loadQueue();
  _startQueuePump();
}
```

### _loadQueue — Recovery on Restart

**File:** `unified_upload_queue_provider.dart:265`

```dart
Future<void> _loadQueue() async {
  try {
    final allItems = await UploadQueueRepository.getAll();
    for (final item in allItems) {
      // Recovery: native upload completed (S3) but server callback never
      // fired (e.g. app killed during callback). Retry the callback now.
      if (item.status == 'uploading' && item.isNativeCompleted) {
        AppLogger.i(
          '_loadQueue: retrying callback for completed-native item id=${item.id}',
        );
        unawaited(_handleNativeComplete(item.id!, item.workerId ?? ''));
        continue;
      }

      // Proactive check: query background_downloader's internal DB for the
      // actual native task status.
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
            if (record.status == TaskStatus.failed ||
                record.status == TaskStatus.waitingToRetry) {
              AppLogger.w(
                '_loadQueue: native upload ${record.status} for id=${item.id} '
                '— resetting to pending',
              );
              await UploadQueueRepository.updateStatus(
                id: item.id!, status: 'pending',
              );
              await UploadQueueRepository.updateWorkerId(
                id: item.id!, workerId: '',
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
            // Native task is alive — claim the queue lock
            if (!_isUploading) {
              _isUploading = true;
              _isUploadingSince = DateTime.now();
              _activeItem = item;
              notifyListeners();
            }
            continue;
          } else {
            // Native task is gone — reset to pending
            AppLogger.w(
              '_loadQueue: native task vanished for id=${item.id} '
              '— resetting to pending',
            );
            await UploadQueueRepository.updateStatus(
              id: item.id!, status: 'pending',
            );
            await UploadQueueRepository.updateWorkerId(
              id: item.id!, workerId: '',
            );
            continue;
          }
        } catch (e) {
          AppLogger.w(
            '_loadQueue: error querying native record for id=${item.id}: $e',
          );
        }
      }

      // Reset stale 'uploading' items (no workerId or too old)
      if (item.status == 'uploading') {
        final lastUpdatedParsed = DateTime.tryParse(item.lastUpdated);
        final isStale =
            lastUpdatedParsed != null &&
            DateTime.now().difference(lastUpdatedParsed) >
                const Duration(minutes: 30);
        final missingWorker =
            item.workerId == null || item.workerId!.isEmpty;

        if (missingWorker || isStale) {
          AppLogger.i(
            '_loadQueue: resetting stale uploading item id=${item.id} '
            'workerId=${item.workerId} lastUpdated=${item.lastUpdated}',
            tag: 'UPLOAD-QUEUE',
          );
          await UploadQueueRepository.updateStatus(
            id: item.id!, status: 'pending',
          );
          await UploadQueueRepository.updateWorkerId(
            id: item.id!, workerId: '',
          );
        }
      }
      // Fetch fresh URLs for pending items that lost their uploadUrl
      if (item.status == 'pending' &&
          item.bytesUploaded == 0 &&
          (item.uploadUrl == null || item.uploadUrl!.isEmpty)) {
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
          } else {
            AppLogger.w(
              '_loadQueue: could not fetch fresh URL for item id=${item.id} '
              '— marking as failed so user can retry',
            );
            await UploadQueueRepository.markFailed(
              item.id!, 'Failed to get upload URL. Tap to retry.',
            );
          }
        } catch (e) {
          AppLogger.e('_loadQueue: error refreshing URL for item id=${item.id}: $e');
          await UploadQueueRepository.markFailed(
            item.id!, 'Failed to get upload URL. Tap to retry.',
          );
        }
      }
    }

    _queue = await UploadQueueRepository.getActive();
    if (_queue.isNotEmpty) {
      // Set active item
      final uploadingItems = _queue.where(
        (item) => item.status == 'uploading',
      );
      final uploadingItem = uploadingItems.isNotEmpty
          ? uploadingItems.first
          : null;
      _activeItem = uploadingItem ?? _queue.first;
      _activeProgress = _activeItem!.fileSize > 0
          ? ((_activeItem!.bytesUploaded / _activeItem!.fileSize) * 100).round()
          : 0;
    }
    notifyListeners();

    // Re-enqueue any pending items that have uploadUrl set
    _processNextItem();
  } catch (e) {
    AppLogger.e('_loadQueue error: $e');
    _queue = [];
  }
}
```

### _startQueuePump — Periodic 15s Safety Net

**File:** `unified_upload_queue_provider.dart:114`

```dart
void _startQueuePump() {
  _queuePumpTimer?.cancel();
  _queuePumpTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
    final all = await UploadQueueRepository.getActive();
    final now = DateTime.now();

    // --- 1a. Proactive native-status check via background_downloader's
    // internal DB. This MUST run BEFORE the stale reset (section 1)
    // to refresh timestamps for slow uploads.
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
              id: item.id!, status: 'pending',
            );
            await UploadQueueRepository.updateWorkerId(
              id: item.id!, workerId: '',
            );
            continue;
          }
          if (record.progress > 0 && item.fileSize > 0) {
            final nativeBytes = (record.progress * item.fileSize).round();
            if (nativeBytes > item.bytesUploaded) {
              await UploadQueueRepository.updateProgress(
                id: item.id!, bytesUploaded: nativeBytes,
              );
            }
            // Fresh timestamp prevents section 1 from resetting this slow upload
            refreshed.add(item.copyWith(
              bytesUploaded: nativeBytes > item.bytesUploaded
                  ? nativeBytes : item.bytesUploaded,
              lastUpdated: DateTime.now().toIso8601String(),
            ));
            continue;
          }
        } catch (e) {
          AppLogger.w('_queuePump: recordForId error for id=${item.id}: $e');
        }
        refreshed.add(item);
      }
      all..clear()..addAll(refreshed);
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
        all..clear()..addAll(refreshed);
      }
    }

    // --- 1b. Retry server callback for items where native upload
    // completed but server callback failed
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
        return;
      }
    }

    if (_isUploading) return;

    // --- 3. Kick pending items ---
    final hasPending = all.any(
      (i) => i.status == 'pending' && (i.workerId == null || i.workerId!.isEmpty),
    );
    if (hasPending) {
      AppLogger.i('_queuePump: found stuck pending items, kicking queue');
      _processNextItem();
    }
  });
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## User Actions & Legacy Handlers
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### retryFailed — User taps retry

**File:** `unified_upload_queue_provider.dart:1750`

```dart
Future<void> retryFailed(int queueId) async {
  await UploadQueueRepository.incrementRetryCount(queueId);
  await UploadQueueRepository.updateStatus(
    id: queueId, status: 'pending', errorMessage: null,
  );
  await UploadQueueRepository.updateWorkerId(id: queueId, workerId: '');

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
```

### _retryItem

**File:** `unified_upload_queue_provider.dart:1779`

```dart
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
```

### cancelTask

**File:** `unified_upload_queue_provider.dart:1707`

```dart
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
```

### removeItem

**File:** `unified_upload_queue_provider.dart:1726`

```dart
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
  _processNextItem();
}
```

### clearCompleted

**File:** `unified_upload_queue_provider.dart:1744`

```dart
Future<void> clearCompleted() async {
  await UploadQueueRepository.clearCompleted();
  _queue.removeWhere((item) => item.status == 'completed');
  notifyListeners();
}
```

### resumeQueue

**File:** `unified_upload_queue_provider.dart:1702`

```dart
Future<void> resumeQueue() async {
  _processNextItem();
  ToastService.showInfo('Upload assets resumed');
}
```

### Legacy Handlers (from simpler upload flow)

**File:** `unified_upload_queue_provider.dart:1799`

```dart
Future<void> onNativeUploadCompleted(int id, String fileUrl) async {
  await UploadQueueRepository.markCompleted(id);
  final idx = _queue.indexWhere((item) => item.id == id);
  if (idx >= 0) {
    _queue[idx] = _queue[idx].copyWith(status: 'completed', fileUrl: fileUrl);
    await _cleanupCachedFile(_queue[idx].filePath);
  }
  if (_activeItem?.id == id) {
    _activeItem = null;
    _activeProgress = 0;
    _isUploading = false;
    _isUploadingSince = null;
  }
  notifyListeners();
  ToastService.showSuccess('Upload completed');
  await _processNextItem();
}

Future<void> onNativeUploadFailed(int id, String error) async {
  await UploadQueueRepository.markFailed(id, error);
  final idx = _queue.indexWhere((item) => item.id == id);
  if (idx >= 0) {
    _queue[idx] = _queue[idx].copyWith(status: 'failed', errorMessage: error);
  }
  if (_activeItem?.id == id) {
    _isUploading = false;
    _isUploadingSince = null;
  }
  notifyListeners();
  await _processNextItem();
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## Presigned URL Fetching
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### BackgroundUploadService.fetchPresignedUrl

**File:** `lib/features/courses/services/background_upload_service.dart:27`

```dart
static Future<Map<String, String>?> fetchPresignedUrl({
  required String filePath,
  required String endpoint,
  required Map<String, dynamic> Function(String fileName) buildPayload,
  Map<String, dynamic> extraFields = const {},
}) async {
  final token = AuthController.accessToken;
  if (token == null) {
    AppLogger.e('fetchPresignedUrl: no auth token');
    return null;
  }
  _authToken = token;

  for (int retry = 0; retry < maxRetries; retry++) {
    try {
      final fileName = filePath.split(Platform.pathSeparator).last;
      final payload = {
        ...buildPayload(fileName),
        ...extraFields,
      };
      AppLogger.i('fetchPresignedUrl [attempt ${retry + 1}/$maxRetries]: POST $endpoint');
      final response = await http.post(
        Uri.parse(endpoint),
        headers: _authHeaders(),
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final data = decoded['data'] as Map<String, dynamic>?;
        if (data != null) {
          final uploadUrl = data['uploadUrl'] as String?;
          final fileUrl = data['fileUrl'] as String?;
          if (uploadUrl != null && fileUrl != null) {
            return {'uploadUrl': uploadUrl, 'fileUrl': fileUrl};
          }
        }
      }
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    } on SocketException {
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    } on http.ClientException {
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    } on TimeoutException {
      AppLogger.w('fetchPresignedUrl: timeout on attempt ${retry + 1}');
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    }
  }
  AppLogger.e('fetchPresignedUrl: failed after $maxRetries retries');
  return null;
}
```

### BackgroundUploadService.fetchCoursePresignedUrls

**File:** `lib/features/courses/services/background_upload_service.dart:129`

```dart
static Future<Map<String, String?>?> fetchCoursePresignedUrls({
  required String thumbnailPath,
  String? videoPath,
}) async {
  final token = AuthController.accessToken;
  if (token == null) {
    AppLogger.e('fetchCoursePresignedUrls: no auth token');
    return null;
  }
  _authToken = token;

  final thumbName = thumbnailPath.split(Platform.pathSeparator).last;
  final payload = <String, dynamic>{
    'thumbnailFilename': thumbName,
    'thumbnailContentType': inferImageContentType(thumbName),
  };

  if (videoPath != null) {
    final videoName = videoPath.split(Platform.pathSeparator).last;
    payload['videoFilename'] = videoName;
    payload['videoContentType'] = inferVideoContentType(videoName);
  }

  for (int retry = 0; retry < maxRetries; retry++) {
    try {
      final response = await http.post(
        Uri.parse(Urls.courseAssetsUploadUrl),
        headers: _authHeaders(),
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final outerData = decoded['data'] as Map<String, dynamic>?;
        final innerData = outerData?['data'] as Map<String, dynamic>?;

        if (innerData == null) {
          if (retry < maxRetries - 1) {
            await Future.delayed(Duration(seconds: 2 * (retry + 1)));
            continue;
          }
          AppLogger.e('fetchCoursePresignedUrls: nested data is null');
          return null;
        }

        final thumb = innerData['thumbnail'] as Map<String, dynamic>?;
        final video = innerData['video'] as Map<String, dynamic>?;

        final thumbUploadUrl = thumb?['uploadUrl'] as String?;
        final thumbFileUrl = thumb?['fileUrl'] as String?;

        if (thumbUploadUrl == null || thumbFileUrl == null) {
          if (retry < maxRetries - 1) {
            await Future.delayed(Duration(seconds: 2 * (retry + 1)));
            continue;
          }
          AppLogger.e('fetchCoursePresignedUrls: thumbnail URLs missing');
          return null;
        }

        return {
          'thumbnailUploadUrl': thumbUploadUrl,
          'thumbnailFileUrl': thumbFileUrl,
          'videoUploadUrl': video?['uploadUrl'] as String?,
          'videoFileUrl': video?['fileUrl'] as String?,
        };
      }
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    } on SocketException {
      await Future.delayed(Duration(seconds: 2 * (retry + 1)));
    } on http.ClientException {
      await Future.delayed(Duration(seconds: 2 * (retry + 1)));
    } on TimeoutException {
      AppLogger.w('fetchCoursePresignedUrls: timeout on attempt ${retry + 1}');
      if (retry < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2 * (retry + 1)));
      }
    }
  }
  AppLogger.e('fetchCoursePresignedUrls: failed after $maxRetries retries');
  return null;
}
```

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## Complete End-to-End Flow Summary
## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Normal Upload (no errors, no app kill)

```
1. User taps "Upload" in UI
2. addModuleLessonToQueue()            :1407
   ├─ _persistFileIfNeeded()            :1581  → copy cache→docs
   ├─ _hasInFlightFile()               :542  → dedup guard
   ├─ _ensureNotificationPermission()   :1609  → Android permission
   ├─ UploadQueueRepository.insert()    :313  → DB row (status='pending')
   ├─ BackgroundUploadService.fetchPresignedUrl()  :27  → get S3 URL
   └─ UploadQueueRepository.updateUrls()  :513  → store URLs

3. await _processNextItem()             :554
   ├─ claimNextPendingItem()            :454  → atomic claim (status='uploading')
   ├─ _isUrlStale()                     :710  → refresh if expired
   ├─ File.existsSync()                 :624  → file still on disk?
   ├─ _buildCallbackDetails()           :966  → server callback body
   ├─ BackgroundUploaderService.enqueueUpload()  :20  → native bridge
   └─ updateWorkerId()                  :600  → store WorkManager taskId

4. Native Kotlin (TaskRunner.kt):
   ├─ run()                             :522  → foreground WorkManager
   ├─ UploadTaskRunner.process()              → S3 PUT via 64KB chunks
   ├─ progress updates via MethodChannel     → _onNativeTaskProgress()
   └─ processStatusUpdate()             :144
        ├─ postOnBackgroundChannel("statusUpdate")  → Dart
        └─ [Native callback removed]

5. Dart _onNativeTaskStatus()           :805
   └─ TaskStatus.complete → _handleNativeComplete()  :901
        ├─ markNativeCompleted()        :390
        ├─ _sendCallbackForItem()        :948
        │   └─ BackgroundUploaderService.sendServerCallback()  :67
        │        → POST {callbackUrl} with Idempotency-Key
        │        ← 200/201/409
        ├─ markCallbackCompleted()       :403
        ├─ markCompleted()               :561  → status='completed'
        ├─ _cleanupCachedFile()          :1817
        └─ _onItemTerminal()             :1048
             ├─ release _isUploading lock
             ├─ notifyListeners()
             └─ _processNextItem()        → starts next in queue
```

### Surviving App Kill

```
1. App killed during S3 upload
2. WorkManager reschedules on reboot (doRescheduleKilledTasks=true)
3. App reopens → _init() :62
   ├─ FileDownloader().start() re-fires callbacks
   ├─ 500ms delay for callbacks to arrive
   └─ _loadQueue() :265
        ├─ Finds item with status='uploading' + workerId
        ├─ recordForId()→TaskStatus.complete → _handleNativeComplete()
        └─ _processNextItem() starts next pending item
```

### Surviving Failed Callback

```
1. Native upload completes
2. _handleNativeComplete() sends callback → server returns error
3. DB: nativeMarkedCompleted=1, serverCallbackCompleted=0
4. _onItemTerminal() releases lock, advances queue
5. Next queue pump cycle (15s):
   └─ isNativeCompleted && !isCallbackCompleted → _handleNativeComplete() retries
6. On next app restart:
   └─ _loadQueue() also retries the same callback
```

---

## File Path Index

| Purpose | File Path |
|---------|-----------|
| Queue orchestration | `lib/features/courses/providers/unified_upload_queue_provider.dart` |
| SQLite repository | `lib/features/courses/data/repositories/upload_queue_repository.dart` |
| Data models | `lib/features/courses/data/models/upload_task.dart` |
| Presigned URL fetch | `lib/features/courses/services/background_upload_service.dart` |
| Native bridge | `lib/features/courses/services/background_uploader_service.dart` |
| Native Kotlin runner | `packages/background_downloader/android/src/main/kotlin/.../TaskRunner.kt` |
| Native upload impl | `packages/background_downloader/android/src/main/kotlin/.../UploadTaskRunner.kt` |
| Native WorkManager | `packages/background_downloader/android/src/main/kotlin/.../TaskWorker.kt` |

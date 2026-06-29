import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:edtech/features/courses/data/models/upload_task.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

String _generateUploadId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(0x7FFFFFFF);
  return 'up_${now}_$rand';
}

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

  UploadQueueItem copyWith({
    int? id,
    String? filePath,
    String? title,
    int? videoDuration,
    int? fileSize,
    String? uploadUrl,
    String? fileUrl,
    String? status,
    int? bytesUploaded,
    String? errorMessage,
    String? createdAt,
    String? lastUpdated,
    String? uploadType,
    String? metadata,
    String? uploadId,
    String? workerId,
    int? heartbeatMs,
    int? retryCount,
    String? idempotencyKey,
    int? nativeMarkedCompleted,
    int? serverCallbackCompleted,
  }) {
    return UploadQueueItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      title: title ?? this.title,
      videoDuration: videoDuration ?? this.videoDuration,
      fileSize: fileSize ?? this.fileSize,
      uploadUrl: uploadUrl ?? this.uploadUrl,
      fileUrl: fileUrl ?? this.fileUrl,
      status: status ?? this.status,
      bytesUploaded: bytesUploaded ?? this.bytesUploaded,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      uploadType: uploadType ?? this.uploadType,
      metadata: metadata ?? this.metadata,
      uploadId: uploadId ?? this.uploadId,
      workerId: workerId ?? this.workerId,
      heartbeatMs: heartbeatMs ?? this.heartbeatMs,
      retryCount: retryCount ?? this.retryCount,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      nativeMarkedCompleted:
          nativeMarkedCompleted ?? this.nativeMarkedCompleted,
      serverCallbackCompleted:
          serverCallbackCompleted ?? this.serverCallbackCompleted,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'filePath': filePath,
      'title': title,
      'videoDuration': videoDuration,
      'fileSize': fileSize,
      'uploadUrl': uploadUrl,
      'fileUrl': fileUrl,
      'status': status,
      'bytesUploaded': bytesUploaded,
      'errorMessage': errorMessage,
      'createdAt': createdAt,
      'lastUpdated': lastUpdated,
      'uploadType': uploadType,
      'metadata': metadata,
      'uploadId': uploadId,
      'workerId': workerId,
      'heartbeatMs': heartbeatMs,
      'retryCount': retryCount,
      'idempotencyKey': idempotencyKey,
      'nativeMarkedCompleted': nativeMarkedCompleted,
      'serverCallbackCompleted': serverCallbackCompleted,
    };
  }

  factory UploadQueueItem.fromMap(Map<String, dynamic> map) {
    return UploadQueueItem(
      id: map['id'] as int?,
      filePath: map['filePath'] as String,
      title: map['title'] as String,
      videoDuration: map['videoDuration'] as int? ?? 0,
      fileSize: map['fileSize'] as int? ?? 0,
      uploadUrl: map['uploadUrl'] as String?,
      fileUrl: map['fileUrl'] as String?,
      status: map['status'] as String? ?? 'pending',
      bytesUploaded: map['bytesUploaded'] as int? ?? 0,
      errorMessage: map['errorMessage'] as String?,
      createdAt: map['createdAt'] as String?,
      lastUpdated: map['lastUpdated'] as String?,
      uploadType: map['uploadType'] as String? ?? 'video_post',
      metadata: map['metadata'] as String?,
      uploadId: map['uploadId'] as String?,
      workerId: map['workerId'] as String?,
      heartbeatMs: map['heartbeatMs'] as int?,
      retryCount: map['retryCount'] as int? ?? 0,
      idempotencyKey: map['idempotencyKey'] as String?,
      nativeMarkedCompleted: map['nativeMarkedCompleted'] as int? ?? 0,
      serverCallbackCompleted: map['serverCallbackCompleted'] as int? ?? 0,
    );
  }
}

class UploadQueueRepository {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  /// Trim the WAL file to prevent unbounded growth from frequent writes.
  /// Call periodically (e.g. every 5 minutes during upload activity).
  static Future<void> checkpointWal() async {
    try {
      final db = await database;
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      AppLogger.w('checkpointWal: $e');
    }
  }

  static Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}${Platform.pathSeparator}upload_queue.db';
    AppLogger.i('UploadQueueRepository: opening database at $path');
    return openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE upload_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            filePath TEXT NOT NULL,
            title TEXT NOT NULL,
            videoDuration INTEGER NOT NULL DEFAULT 0,
            fileSize INTEGER NOT NULL DEFAULT 0,
            uploadUrl TEXT,
            fileUrl TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            bytesUploaded INTEGER NOT NULL DEFAULT 0,
            errorMessage TEXT,
            createdAt TEXT NOT NULL,
            lastUpdated TEXT NOT NULL,
            uploadType TEXT NOT NULL DEFAULT 'video_post',
            metadata TEXT,
            uploadId TEXT,
            workerId TEXT,
            heartbeatMs INTEGER,
            retryCount INTEGER NOT NULL DEFAULT 0,
            idempotencyKey TEXT,
            nativeMarkedCompleted INTEGER NOT NULL DEFAULT 0,
            serverCallbackCompleted INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_upload_queue_status ON upload_queue(status)',
        );
        await db.execute(
          'CREATE INDEX idx_upload_queue_uploadId ON upload_queue(uploadId)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v2: Added uploadType and metadata columns (preserve data)
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN uploadType TEXT NOT NULL DEFAULT 'video_post'",
          );
          await db.execute("ALTER TABLE upload_queue ADD COLUMN metadata TEXT");
          AppLogger.i(
            'UploadQueueRepository: migrated to v2 — added uploadType and metadata',
          );
        }
        // v3: Added lastUpdated column
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN lastUpdated TEXT NOT NULL DEFAULT ''",
          );
          await db.rawUpdate(
            "UPDATE upload_queue SET lastUpdated = createdAt WHERE lastUpdated = ''",
          );
          AppLogger.i(
            'UploadQueueRepository: migrated to v3 — added lastUpdated column',
          );
        }
        // v4: Ensure index exists
        if (oldVersion < 4) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_upload_queue_status ON upload_queue(status)',
          );
          AppLogger.i('UploadQueueRepository: migrated to v4 — ensured index');
        }
        // v5: Added uploadId, workerId, heartbeatMs, retryCount, idempotencyKey, nativeMarkedCompleted, serverCallbackCompleted
        if (oldVersion < 5) {
          await db.execute("ALTER TABLE upload_queue ADD COLUMN uploadId TEXT");
          await db.execute("ALTER TABLE upload_queue ADD COLUMN workerId TEXT");
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN heartbeatMs INTEGER",
          );
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN retryCount INTEGER NOT NULL DEFAULT 0",
          );
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN idempotencyKey TEXT",
          );
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN nativeMarkedCompleted INTEGER NOT NULL DEFAULT 0",
          );
          await db.execute(
            "ALTER TABLE upload_queue ADD COLUMN serverCallbackCompleted INTEGER NOT NULL DEFAULT 0",
          );
          // Backfill uploadId for existing rows
          await db.execute(
            "UPDATE upload_queue SET uploadId = 'legacy_' || id WHERE uploadId IS NULL",
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_upload_queue_uploadId ON upload_queue(uploadId)',
          );
          AppLogger.i(
            'UploadQueueRepository: migrated to v5 — added uploadId, workerId, heartbeatMs, retryCount, idempotencyKey, nativeMarkedCompleted, serverCallbackCompleted',
          );
        }
      },
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA busy_timeout=5000');
        await db.rawQuery('PRAGMA auto_vacuum=INCREMENTAL');
        await db.rawQuery('PRAGMA soft_heap_limit=8388608'); // 8MB max heap
      },
    );
  }

  /// Returns a map with {id, uploadId}.
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

  static Future<UploadQueueItem?> getByUploadId(String uploadId) async {
    final db = await database;
    final maps = await db.query(
      'upload_queue',
      where: 'uploadId = ?',
      whereArgs: [uploadId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UploadQueueItem.fromMap(maps.first);
  }

  static Future<List<UploadQueueItem>> getByFileType({
    required String filePath,
    String? uploadType,
  }) async {
    final db = await database;
    if (uploadType != null) {
      final maps = await db.query(
        'upload_queue',
        where: 'filePath = ? AND uploadType = ?',
        whereArgs: [filePath, uploadType],
        orderBy: 'id DESC',
      );
      return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
    }
    final maps = await db.query(
      'upload_queue',
      where: 'filePath = ?',
      whereArgs: [filePath],
      orderBy: 'id DESC',
    );
    return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
  }

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

  static Future<void> updateHeartbeat(int id) async {
    final db = await database;
    await db.update(
      'upload_queue',
      {
        'heartbeatMs': DateTime.now().millisecondsSinceEpoch,
        'lastUpdated': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  /// Only allow valid state transitions.
  /// Throws if the transition is invalid.
  static Future<void> _assertValidTransition(
    Database db,
    int id,
    String newStatus,
  ) async {
    final maps = await db.query(
      'upload_queue',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return;
    final current = maps.first['status'] as String;
    if (current == 'completed' && newStatus != 'completed') {
      throw StateError('Cannot transition from completed to $newStatus');
    }
    if (current == 'cancelled' && newStatus != 'cancelled') {
      throw StateError('Cannot transition from cancelled to $newStatus');
    }
    if (current == newStatus) return;
  }

  static Future<UploadQueueItem?> getNextPending() async {
    final db = await database;
    final maps = await db.query(
      'upload_queue',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UploadQueueItem.fromMap(maps.first);
  }

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

  static Future<List<UploadQueueItem>> getAll() async {
    final db = await database;
    final maps = await db.query('upload_queue', orderBy: 'id ASC');
    return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
  }

  static Future<List<UploadQueueItem>> getActive() async {
    final db = await database;
    final maps = await db.query(
      'upload_queue',
      where: 'status NOT IN (?, ?, ?)',
      whereArgs: ['completed', 'failed', 'cancelled'],
      orderBy: 'id ASC',
    );
    return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
  }

  static Future<List<UploadQueueItem>> getByStatus(String status) async {
    final db = await database;
    final maps = await db.query(
      'upload_queue',
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'id ASC',
    );
    return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
  }

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

  static Future<void> updateMetadata({
    required int id,
    required String metadata,
  }) async {
    final db = await database;
    await db.update(
      'upload_queue',
      {'metadata': metadata},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  static Future<void> incrementRetryCount(int id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE upload_queue SET retryCount = retryCount + 1, lastUpdated = ? WHERE id = ?',
      [DateTime.now().toIso8601String(), id],
    );
  }

  static Future<void> updateWorkerId({
    required int id,
    required String workerId,
  }) async {
    final db = await database;
    await db.update(
      'upload_queue',
      {'workerId': workerId, 'lastUpdated': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<UploadQueueItem>> getByWorkerId(String workerId) async {
    final db = await database;
    final maps = await db.query(
      'upload_queue',
      where: 'workerId = ?',
      whereArgs: [workerId],
    );
    return maps.map((m) => UploadQueueItem.fromMap(m)).toList();
  }

  static Future<void> updateStatus({
    required int id,
    required String status,
    int? bytesUploaded,
    String? errorMessage,
  }) async {
    final db = await database;
    await _assertValidTransition(db, id, status);
    final values = <String, dynamic>{
      'status': status,
      'lastUpdated': DateTime.now().toIso8601String(),
    };
    if (bytesUploaded != null) values['bytesUploaded'] = bytesUploaded;
    if (errorMessage != null) values['errorMessage'] = errorMessage;
    await db.update('upload_queue', values, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteItem(int id) async {
    final db = await database;
    await db.delete('upload_queue', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> clearCompleted() async {
    final db = await database;
    await db.delete(
      'upload_queue',
      where: 'status = ?',
      whereArgs: ['completed'],
    );
    await _reclaimSpace();
  }

  /// Delete items with terminal status older than [days] days.
  static Future<void> deleteOldItems({int days = 7}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    await db.delete(
      'upload_queue',
      where:
          "status IN ('completed', 'failed', 'cancelled') AND lastUpdated < ?",
      whereArgs: [cutoff],
    );
    await _reclaimSpace();
  }

  /// Reclaim free pages from the database file after bulk deletes.
  static Future<void> _reclaimSpace() async {
    try {
      final db = await database;
      await db.rawQuery('PRAGMA incremental_vacuum');
    } catch (e) {
      AppLogger.w('_reclaimSpace: $e');
    }
  }

  static Future<int> countPending() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM upload_queue WHERE status = ?',
      ['pending'],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  static Future<int> countActive() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM upload_queue WHERE status NOT IN ('completed', 'failed', 'cancelled')",
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// Resets items stuck in 'uploading' based on heartbeat staleness.
  /// If a heartbeatMs is present but older than [heartbeatTimeout], the item
  /// is considered stale (native process died). Without heartbeat, falls
  /// back to lastUpdated timestamp with [fallbackTimeout].
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
  }

  /// Delete file from cache/temp if it lives inside our app directories.
  /// Safe to call on any file path — only deletes if path is in cache or app docs.
  static Future<void> cleanupFileIfCached(String filePath) async {
    try {
      final dirs = await Future.wait([
        getTemporaryDirectory(),
        getApplicationDocumentsDirectory(),
      ]);
      final file = File(filePath);
      if (!file.existsSync()) return;
      final resolved = file.resolveSymbolicLinksSync();
      if (dirs.any((d) => resolved.startsWith(d.path))) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// Get all file paths currently tracked by the queue (all statuses).
  static Future<Set<String>> getAllTrackedPaths() async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT DISTINCT filePath FROM upload_queue',
    );
    return maps.map((m) => m['filePath'] as String).toSet();
  }

  /// Scan temp/cache directories and delete files not tracked by any SQLite row.
  /// Skips files modified within the last 60s to avoid races with ImagePicker copies.
  /// Safe to call on startup — only removes truly orphaned copies.
  static Future<void> cleanupOrphanedCacheFiles() async {
    try {
      final tracked = await getAllTrackedPaths();
      final dirs = await Future.wait([
        getTemporaryDirectory(),
        getApplicationDocumentsDirectory(),
      ]);
      final now = DateTime.now();
      for (final dir in dirs) {
        if (!dir.existsSync()) continue;
        final files = dir.listSync(recursive: true).whereType<File>();
        for (final file in files) {
          if (now.difference(file.lastModifiedSync()).inSeconds < 60) continue;
          final path = file.resolveSymbolicLinksSync();
          if (!tracked.contains(path)) {
            await file.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// Full startup cleanup: old items + orphaned cache files + WAL trim.
  static Future<void> runStartupCleanup() async {
    await deleteOldItems();
    await cleanupOrphanedCacheFiles();
    await checkpointWal();
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

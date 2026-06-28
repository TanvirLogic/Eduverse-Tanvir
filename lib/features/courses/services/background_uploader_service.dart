import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:http/http.dart' as http;

class BackgroundUploaderService {
  /// Upload file to S3 via presigned PUT using background_downloader.
  /// Uses UploadTask.fromFile with `post: 'binary'` for raw binary upload
  /// and `httpRequestMethod: 'PUT'` for S3 presigned URL compatibility.
  /// Enqueue an upload to run in a native isolate via WorkManager.
  /// Survives app kills — returns the taskId for tracking.
  /// The itemId is stored in task.metaData so global callbacks can look it up.
  /// If [callbackUrl], [authToken] and [callbackBody] are provided, they are
  /// also stored in the metadata so native Kotlin code can fire the server
  /// callback directly after the S3 upload completes — even if the app is killed.
  /// [idempotencyKey] is passed to the native callback as an HTTP header so the
  /// server can deduplicate requests when both native and Dart callbacks fire.
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

    // Background_downloader already runs in foreground mode, and upload
    // progress is surfaced through the shared notification service.
    // Avoid configuring duplicate task-level notifications here.
    AppLogger.i('enqueueUpload: calling enqueue for taskId=${task.taskId}');
    final ok = await FileDownloader().enqueue(task);
    if (!ok) {
      AppLogger.e('enqueueUpload: enqueue returned false for item $itemId');
      return null;
    }
    AppLogger.i('enqueueUpload: success, taskId=${task.taskId}');
    return task.taskId;
  }

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

  static Future<void> cancelUploadByWorkerId(String workerId) async {
    await FileDownloader().cancelTaskWithId(workerId);
  }

  static Future<void> cancelAll() async {
    await FileDownloader().cancelAll();
  }
}

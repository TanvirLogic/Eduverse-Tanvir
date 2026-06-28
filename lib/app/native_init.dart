import 'package:background_downloader/background_downloader.dart';
import 'package:edtech/features/courses/data/repositories/upload_queue_repository.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:edtech/global/core/services/upload_notification_service.dart';
import 'package:media_kit/media_kit.dart';

Future<void> initPlatformServices() async {
  // Initialize file-based logging first so all subsequent logs are captured
  await AppLogger.init();

  MediaKit.ensureInitialized();
  await UploadNotificationService.init();
  await _requestNotificationPermissionEarly();

  // Configure background_downloader to run uploads as foreground service
  // (required to show persistent notification on Android), with a longer
  // request timeout for multi-GB file uploads on slow connections.
  try {
    await FileDownloader().configure(
      globalConfig: [
        (Config.runInForeground, Config.always),
        (Config.requestTimeout, const Duration(seconds: 120)),
      ],
    );
  } catch (e) {
    AppLogger.e('Failed to configure FileDownloader foreground: $e');
  }

  // Storage cleanup: delete old rows, orphaned cache files, trim WAL
  await UploadQueueRepository.runStartupCleanup();
}

Future<void> _requestNotificationPermissionEarly() async {
  try {
    if (!await UploadNotificationService.hasNotificationPermission()) {
      await UploadNotificationService.requestNotificationPermission();
    }
  } catch (_) {}
}

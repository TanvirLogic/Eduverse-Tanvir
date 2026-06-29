# Session Summary — Jun 29, 2026

## Goal
Fix video upload reliability to perform like YouTube — background, foreground, app killed, large/small files, queue processing.

## Completed

### Log analysis — full picture
- Traced end-to-end flow from `addToQueue` → SQLite → `_processNextItem` → native `TaskRunner` → completion callback → server callback → queue advance
- Identified root cause of missing upload: file stored in Android cache dir was deleted before upload started

### Bug fixes applied

| # | Bug | File | Fix |
|---|-----|------|-----|
| 1 | **Source file deleted from Android cache** before upload starts | `unified_upload_queue_provider.dart` | Added `_persistFileIfNeeded()` copies from cache → `getApplicationDocumentsDirectory()/eduverse_uploads/` in all 6 add methods |
| 2 | **`addToQueue` shows false error** when another upload is active | `unified_upload_queue_provider.dart:1104-1112` | Checks DB for native active upload in addition to `_isUploading`; `_processNextItem` false return now shows "queued" not "failed" |
| 3 | **FIFO deadlock when server callback fails** — native upload done but callback pending, `_processNextItem` refuses to advance | `unified_upload_queue_provider.dart:562` | `_processNextItem` FIFO check now skips items with `isNativeCompleted=true` so next pending item can start |
| 4 | **`onNativeUploadFailed` doesn't start next item** — queue stuck until pump cycle | `unified_upload_queue_provider.dart:1798` | Converted to `Future<void>`, awaits DB writes, calls `_processNextItem()` |
| 5 | **`onNativeUploadCompleted` drops DB writes** — fire-and-forget `markCompleted` | `unified_upload_queue_provider.dart:1775` | Converted to `Future<void>`, awaits DB writes, calls `_processNextItem()` |
| 6 | **`removeItem` doesn't advance queue** — next item waits 15s for pump | `unified_upload_queue_provider.dart:1703` | Added `_processNextItem()` call |
| 7 | **`course_thumb` type has no callback** — falls through to `video_post` default, creates wrong server record | `unified_upload_queue_provider.dart:1007, 758` | Added `'course_thumb'` case to both `_buildCallbackDetails` and `_fetchFreshUrls` |
| 8 | **`_generateUploadId` collision** — two items in same millisecond with same `Random()` seed get duplicate `uploadId` | `upload_queue_repository.dart:10-14` | Changed to `microsecondsSinceEpoch` (1000× finer granularity) |
| 9 | **`updateProgress` moves bar backward** — out-of-order callbacks | `upload_queue_repository.dart:529` | Added `WHERE bytesUploaded < ?` monotonicity guard |
| 10 | **`_openNotificationSettings` crashes on iOS** — `Process.run('am', ...)` only exists on Android | `unified_upload_queue_provider.dart:1621` | Added `if (!Platform.isAndroid) return;` |
| 11 | **`TimeoutException` not caught** in URL fetch — bypasses retry loop | `background_upload_service.dart:83,202` | Added `on TimeoutException` catch clause to both `fetchPresignedUrl` and `fetchCoursePresignedUrls` |
| 12 | **`PRAGMA incremental_vacuum(0)` is a no-op** | `upload_queue_repository.dart:671` | Changed to `PRAGMA incremental_vacuum` |
| 13 | **Silent errors swallowed** in `_reclaimSpace` and `checkpointWal` | `upload_queue_repository.dart` | Added `AppLogger.w()` to catch blocks |
| 14 | **VideoPlayerScreen.initState async crash** — un-awaited Futures can throw unhandled | `video_player_screen.dart:45` | Properly await calls, log errors instead of silent `catch(_)` |
| 15 | **VideoPlayerScreen.dispose() crash** — `context.read()` can throw if provider is gone | `video_player_screen.dart:115` | Guard with try-catch |
| 16 | **VideoPlayerProvider.double-stop crash** — `_player.stop()` on already-stopped player | `video_player_provider.dart:214,229` | Add `isActive` guard to `stop()` and `dismiss()` |
| 17 | **VideoPlayerProvider.openVideo empty URL** — unguarded `_player.open(Media(""))` can crash native | `video_player_provider.dart:100` | Early return with `hasError=true` |
| 18 | **VideoPlayerScreen auto-advance crash** — `Navigator.pushReplacement` with stale context | `video_player_screen.dart:82` | Guard with try-catch |
| 19 | **SystemChrome crash** — `_enterFullScreen`/`_exitFullScreen` throws on unsupported platforms | `video_player_screen.dart:100,108` | Guard with try-catch |

## Known Issues
- No max-retry cap on queue pump callback retries, no file size validation.
- Native Kotlin layer: no upload resume (restarts from 0 on failure), 64KB buffer suboptimal for fast networks, UIDT jobs not persisted across reboot.

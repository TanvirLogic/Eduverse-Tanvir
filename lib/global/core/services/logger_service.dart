import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class AppLogger {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 500,
      colors: true,
      printEmojis: true,
      printTime: true,
    ),
  );

  static File? _logFile;
  static int _fileLineCount = 0;
  static const int _maxFileLines = 2000;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/app_log.txt');
      if (await _logFile!.exists()) {
        final lines = await _logFile!.readAsLines();
        _fileLineCount = lines.length;
        // Print recent lines from previous session
        final tail = lines.length > 20 ? lines.sublist(lines.length - 20) : lines;
        _logger.i('--- Previous session (last ${tail.length} lines) ---');
        for (final line in tail) {
          _logger.i(line);
        }
        _logger.i('--- End of previous session ---');
      }
    } catch (_) {}
  }

  static Future<void> _writeToFile(String line) async {
    try {
      if (_logFile == null) return;
      await _logFile!.writeAsString('$line\n', mode: FileMode.append);
      _fileLineCount++;
      if (_fileLineCount > _maxFileLines) {
        await _trimFile();
      }
    } catch (_) {}
  }

  static Future<void> _trimFile() async {
    try {
      if (_logFile == null) return;
      final lines = await _logFile!.readAsLines();
      if (lines.length > _maxFileLines ~/ 2) {
        await _logFile!.writeAsString(
          lines.sublist(lines.length - (_maxFileLines ~/ 2)).join('\n'),
        );
        _fileLineCount = _maxFileLines ~/ 2;
      }
    } catch (_) {}
  }

  static String _format(String message, String? tag) {
    if (tag == null || tag.isEmpty) return message;
    return '[$tag] $message';
  }

  static String _levelPrefix(Level level) {
    switch (level.index) {
      case 0:
        return 'V';
      case 1:
        return 'D';
      case 2:
        return 'I';
      case 3:
        return 'W';
      case 4:
        return 'E';
      case 5:
        return 'WTF';
      default:
        return '?';
    }
  }

  static void _log(
    Level level,
    String message, {
    dynamic error,
    StackTrace? stackTrace,
    String? tag,
  }) {
    final formatted = _format(message, tag);
    final ts = DateTime.now().toIso8601String();
    final fileLine = '$ts ${_levelPrefix(level)} $formatted';

    // Always write to file (survives crashes)
    _writeToFile(fileLine);

    // If it's an error, include stack trace in file
    if (error != null && level == Level.error) {
      _writeToFile('$ts E   $error');
    }
    if (stackTrace != null && level == Level.error) {
      final trace = stackTrace.toString().split('\n').take(10).join('\n');
      _writeToFile('$ts E   $trace');
    }

    // Console output via logger package
    if (error != null || stackTrace != null) {
      _logger.log(level, formatted, error: error, stackTrace: stackTrace);
    } else {
      _logger.log(level, formatted);
    }
  }

  static void d(String message, {String? tag}) =>
      _log(Level.debug, message, tag: tag);

  static void i(String message, {String? tag}) =>
      _log(Level.info, message, tag: tag);

  static void w(String message, {String? tag}) =>
      _log(Level.warning, message, tag: tag);

  static void e(
    String message, {
    dynamic error,
    StackTrace? stackTrace,
    String? tag,
  }) => _log(Level.error, message, error: error, stackTrace: stackTrace, tag: tag);

  /// Call to dump logs when crash is suspected
  static Future<String?> getLogContent() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return null;
      return await _logFile!.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Clear all persisted logs
  static Future<void> clearLogs() async {
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString('');
        _fileLineCount = 0;
      }
    } catch (_) {}
  }
}

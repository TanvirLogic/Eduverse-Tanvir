import 'dart:async';
import 'dart:ui' as ui;

import 'package:edtech/app/app.dart';
import 'package:edtech/app/platform_init.dart';
import 'package:edtech/global/core/services/logger_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  FlutterError.onError = (details) {
    AppLogger.e('FlutterError', error: details.exception, stackTrace: details.stack);
  };

  ui.PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.e('PlatformDispatcher', error: error, stackTrace: stack);
    return true;
  };

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initPlatformServices();
    final prefs = await SharedPreferences.getInstance();
    runApp(App(prefs: prefs));
  }, (error, stack) {
    AppLogger.e('Unhandled', error: error, stackTrace: stack);
  });
}

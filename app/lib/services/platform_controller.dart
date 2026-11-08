import 'package:flutter/services.dart';

class PlatformController {
  static const MethodChannel _channel = MethodChannel('mtunz/native_control');

  static Future<bool> isAccessibilityEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  static Future<void> startMediaProjectionService() async {
    await _channel.invokeMethod<void>('startMediaProjectionService');
  }

  static Future<void> stopMediaProjectionService() async {
    try {
      await _channel.invokeMethod<void>('stopMediaProjectionService');
    } on MissingPluginException {
      // Desktop does not host the Android projection service.
    }
  }

  static Future<bool> dispatchGesture({
    required String action,
    required double x,
    required double y,
    double endX = 0,
    double endY = 0,
    int durationMs = 350,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('dispatchGesture', {
            'action': action,
            'x': x,
            'y': y,
            'endX': endX,
            'endY': endY,
            'durationMs': durationMs,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}

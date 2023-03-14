import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'downloader_platform_interface.dart';

/// An implementation of [DownloaderPlatform] that uses method channels.
class MethodChannelDownloader extends DownloaderPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('downloader');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}

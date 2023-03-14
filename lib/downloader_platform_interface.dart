import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'downloader_method_channel.dart';

abstract class DownloaderPlatform extends PlatformInterface {
  /// Constructs a DownloaderPlatform.
  DownloaderPlatform() : super(token: _token);

  static final Object _token = Object();

  static DownloaderPlatform _instance = MethodChannelDownloader();

  /// The default instance of [DownloaderPlatform] to use.
  ///
  /// Defaults to [MethodChannelDownloader].
  static DownloaderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [DownloaderPlatform] when
  /// they register themselves.
  static set instance(DownloaderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloader/downloader_method_channel.dart';

void main() {
  MethodChannelDownloader platform = MethodChannelDownloader();
  const MethodChannel channel = MethodChannel('downloader');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}

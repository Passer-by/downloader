import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/foundation.dart';

typedef DownLoadListener = Function(
    num taskId, DownloadState state, num totalSize, double progress, num speed);

class Downloader {
  static Map<num, Isolate> downloadPool = {};
  static List<DownLoadListener> listener = [];

  static String _rootPath = "";

  static get rootPath => _rootPath;

  init(String rootPath) {
    if (_rootPath.endsWith('/')) {
      _rootPath = '${rootPath}downloader/';
    } else {
      _rootPath = '$rootPath/downloader/';
    }
  }

  Future download(num taskId, List<String> urls,
      [totalSize = 0, needCalculate = false]) async {
    if (downloadPool.containsKey(taskId)) {
      if (kDebugMode) {
        throw Exception('该任务已经添加');
      }
      return;
    }
    final isolate =
        await _download(taskId, urls, totalSize, needCalculate, _rootPath);
    downloadPool[taskId] = isolate;
  }

  Future pause(num taskId) async {
    if (downloadPool.containsKey(taskId)) {
      downloadPool.remove(taskId)?.kill();
    }
    for (var element in listener) {
      element.call(taskId, DownloadState.pause, 0, 0.0, 0);
    }
  }

  Future remove(num taskId, [bool clean = false]) async {
    if (downloadPool.containsKey(taskId)) {
      downloadPool.remove(taskId)?.kill();
    }
    if (clean) {
      Directory directory = Directory(getTaskPath(taskId));
      if (await directory.exists()) {
        await directory.delete();
      }
    }
    for (var element in listener) {
      element.call(taskId, DownloadState.unknown, 0, 0.0, 0);
    }
  }

  static getTaskPath(num taskId) {
    return '$_rootPath$taskId';
  }

  static onTaskRefresh(
    num taskId,
    DownloadState state,
    num totalSize,
    double progress,
    num speed,
  ) {
    print(
        'taskId:$taskId, state:$state, totalSize:${(totalSize / 1024).toDouble().toStringAsFixed(2)}kb, progress:$progress, speed:${(speed / 1024).toDouble().toStringAsFixed(2)}kb/s');
    if (state == DownloadState.complete) {
      Downloader.downloadPool.remove(taskId)?.kill();
    }
    for (var element in Downloader.listener) {
      element.call(taskId, state, totalSize, progress, speed);
    }
  }
}

// 返回参数 [taskId num,state DownloadState,totalSize num ,progress:double max 100,min 0,speed : num byte]
Future<Isolate> _download(num taskId, List<String> urls, num totalSize,
    bool needCalculate, String rootPath) async {
  var receivePort = ReceivePort();
  receivePort.listen((message) {
    num taskId0 = message[0];
    int state = message[1];
    num totalSize = message[2];
    double progress = message[3];
    num speed = message[4];
    Downloader.onTaskRefresh(
        taskId0, DownloadState.formValue(state), totalSize, progress, speed);
  });
  return await Isolate.spawn((message) async {
    final taskId = message[0] as num;
    final List<String> urls = message[1] as List<String>;
    final rootPath = message[2] as String;
    num totalSize = message[3] as num;
    final needCalculate = (message[4] as bool && totalSize == 1);
    final SendPort port = message[5] as SendPort;

    num totalFileCount = urls.length;
    num completeFileCount = 0;

    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: 5)
    ));
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      logPrint: print, // specify log function (optional)
      retries: 5, // retry count (optional)
      retryDelays: const [
        // set delays between retries (optional)
        Duration(seconds: 1), // wait 1 sec before first retry
        Duration(seconds: 1), // wait 2 sec before second retry
        Duration(seconds: 1), // wait 3 sec before third retry
        Duration(seconds: 1), // wait 3 sec before third retry
        Duration(seconds: 1), // wait 3 sec before third retry
      ],
    ));
    DownloadState downloadState = DownloadState.pre;
    num downloadSize = 0;
    num cacheSize = 0;
    List<String> downloadingUrl = [];
    port.send([taskId, downloadState.state, 0, 0.0, 0]);

    void onFailed() {
      port.send([taskId, DownloadState.failed.state, 0, 0.0, 0]);
    }

    double getProgress() {
      if (needCalculate || totalFileCount == 1) {
        return (downloadSize / totalSize) * 100;
      }
      return (completeFileCount / totalFileCount) * 100;
    }

    Future calculateTotalSize() async {
      /// 已经知道总的文件大小的话 跳过
      if (totalSize != 0) return;
      var calculateSize = 0;
      final futures = urls.map((url) => dio.head(url).then((value) {
            calculateSize++;
            debugPrint('计算的文件数 $calculateSize');
            if (value.headers['content-length']?.isNotEmpty == true) {
              return int.tryParse(value.headers['content-length']![0]) ?? 0;
            } else {
              return 0;
            }
          }));
      final responses = await Future.wait(futures);
      final sizes = responses.map((response) {
        return response;
      });
      totalSize = sizes.fold(0, (a, b) => a + b);
    }

    void downloadNext() {
      if (urls.isEmpty) {
        if (downloadingUrl.isEmpty) {
          downloadState = DownloadState.complete;
          port.send([taskId, downloadState.state, totalSize, 100.0, 0]);
        }
      } else {
        final url = urls.removeAt(0);
        downloadingUrl.add(url);
        num diffReceived = 0;
        dio.downloadFile(url, saveFilePath(rootPath, taskId, url),
            onReceiveProgress: (int received, int total) {
          if (!needCalculate && totalFileCount == 1) {
            totalSize = total;
          }
          downloadSize += received - diffReceived;
          diffReceived = received;
        }).then((value) {
          if (!value) {
            port.send([taskId, DownloadState.failed.state, 0, 0.0, 0]);
            return;
          }
          completeFileCount++;
          downloadingUrl.remove(url);
          downloadNext();
        });
      }
    }

    /// 计算文件大小
    if (needCalculate && totalSize == 0) {
      try {
        await calculateTotalSize();
      } catch (e) {
        print(e);
        onFailed();
      }
    }

    for (int index = 0; index < 20; index++) {
      if (urls.isEmpty) break;
      downloadNext();
    }
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (totalSize != 0 || !needCalculate) {
        downloadState = DownloadState.download;
        port.send([
          taskId,
          downloadState.state,
          totalSize,
          getProgress(),
          downloadSize - cacheSize
        ]);
        cacheSize = downloadSize;
      }
    });
  }, [taskId, urls, rootPath, totalSize, needCalculate, receivePort.sendPort]);
}

// md5 加密
String _generateMD5(String data) {
  var content = const Utf8Encoder().convert(data);
  var digest = md5.convert(content);
  return digest.toString();
}

String _getFileExtension(String url) {
  return url.substring(url.lastIndexOf('.') + 1);
}

String saveFilePath(String rootPath, num taskId, String url) {
  String extension = _getFileExtension(url);
  final Uri uri = Uri.parse(url);
  String filePathMd5 =
      _generateMD5(uri.replace(queryParameters: {}).toString());
  return '$rootPath$taskId/$filePathMd5.$extension';
}

enum DownloadState {
  unknown(-1),
  pre(0),
  pause(1),
  download(2),
  complete(3),
  failed(4);

  final int state;

  const DownloadState(this.state);

  static DownloadState formValue(int state) {
    return DownloadState.values.firstWhere(
      (element) => element.state == state,
      orElse: () => DownloadState.unknown,
    );
  }
}

extension DioExtension on Dio {
  Future<bool> downloadFile(String url, String savePath,
      {Function(int received, int total)? onReceiveProgress}) async {
    try {
      int received = 0;
      int total = 0;
      File file = File(savePath);
      if (file.existsSync()) {
        received = await file.length();
        total = await _getTotalSize(url);
        print('Resuming download from ${received / 1024 / 1024}MB');
        if (total <= received) {
          onReceiveProgress?.call(total, total);
          return true;
        }
      }

      var options = Options(headers: {'range': 'bytes=$received-'});
      await download(url, savePath,
          onReceiveProgress: onReceiveProgress, options: options);

      print('Download completed!');
      return true;
    } catch (e) {
      print('Error: $e');
      return false;
    }
  }

  Future<int> _getTotalSize(String url) async {
    var response = await head(url);
    if (response.headers['content-length']?.isNotEmpty == true) {
      return int.tryParse(response.headers['content-length']![0]) ?? 0;
    } else {
      return 0;
    }
  }
}

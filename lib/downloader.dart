import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class Downloader {
  static Map<num, Isolate> downloadPool = {};

  static String _rootPath = "";

  init(String rootPath) {
    if (_rootPath.endsWith('/')) {
      _rootPath = '${rootPath}downloader/';
    } else {
      _rootPath = '$rootPath/downloader/';
    }
  }

  Future download(num taskId, List<String> urls) async {
    if (downloadPool.containsKey(taskId)) {
      if (kDebugMode) {
        throw Exception('该任务已经添加');
      }
      return;
    }
    final isolate = await _download(taskId, urls, _rootPath);
    downloadPool[taskId] = isolate;
  }

  Future pause(num taskId) async {
    if (downloadPool.containsKey(taskId)) {
      downloadPool.remove(taskId)?.kill();
    }
  }

  Future remove(num taskId, List<String> urls, [bool clean = false]) async {
    if (downloadPool.containsKey(taskId)) {
      downloadPool.remove(taskId)?.kill();
    }
    if (clean) {
      Directory directory = Directory(getTaskPath(taskId));
      if (await directory.exists()) {
        await directory.delete();
      }
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
  }
}

// 返回参数 [taskId num,state DownloadState,totalSize num ,progress:double max 100,min 0,speed : num byte]
Future<Isolate> _download(
    num taskId, List<String> urls, String rootPath) async {
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
    final SendPort port = message[3] as SendPort;
    final dio = Dio(
        BaseOptions(
        )
    );
    DownloadState downloadState = DownloadState.pre;
    num totalSize = 0;
    num downloadSize = 0;
    num cacheSize = 0;
    List<String> downloadingUrl = [];
    port.send([taskId, downloadState.state, 0, 0.0, 0]);

    Future calculateTotalSize() async {
      var calculateSize = 0;
      for (var i = 0; i < urls.length; i++) {
        final futures = urls.map((url) => dio.head(url).then((value) {
              calculateSize++;
              print('计算的文件数 $calculateSize');
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
        dio.download(url, saveFilePath(rootPath, taskId, url),
            onReceiveProgress: (int received, int total) {
          downloadSize += received - diffReceived;
          diffReceived = received;
        }).then((value) {
          downloadingUrl.remove(url);
          downloadNext();
        });
      }
    }

    final start = DateTime.now().millisecond;
    await calculateTotalSize();
    final end = DateTime.now().millisecond;
    print((end - start));

    for (int index = 0; index < 10; index++) {
      if (urls.isEmpty) break;
      final url = urls.removeAt(0);
      downloadingUrl.add(url);
      num diffReceived = 0;
      dio.download(url, saveFilePath(rootPath, taskId, url),
          onReceiveProgress: (int received, int total) {
        downloadSize += received - diffReceived;
        diffReceived = received;
      }).then((value) {
        downloadingUrl.remove(url);
        downloadNext();
      });
    }
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (totalSize != 0) {
        downloadState = DownloadState.download;
        port.send([
          taskId,
          downloadState.state,
          totalSize,
          (downloadSize / totalSize) * 100,
          downloadSize - cacheSize
        ]);
        cacheSize = downloadSize;
      }
    });
  }, [taskId, urls, rootPath, receivePort.sendPort]);
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

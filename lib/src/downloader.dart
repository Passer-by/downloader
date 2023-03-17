import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:downloader/downloader.dart';
import 'package:flutter/foundation.dart';

typedef DownLoadListener = Function(
    num taskId, DownloadState state, num totalSize, double progress, num speed);

class Downloader {
  static Map<num, Isolate> downloadPool = {};
  static List<DownLoadListener> listener = [];

  static String _rootPath = "";
  static bool _debug = false;

  static get rootPath => _rootPath;

  init(String rootPath, {bool debug = false}) {
    Downloader._debug = debug;
    if (_rootPath.endsWith('/')) {
      _rootPath = '${rootPath}downloader/';
    } else {
      _rootPath = '$rootPath/downloader/';
    }
  }

  Future download(Task task) async {
    if (downloadPool.containsKey(task.id)) {
      if (kDebugMode) {
        throw Exception('该任务已经添加');
      }
      return;
    }
    final isolate = await _download(task, _rootPath);
    downloadPool[task.id] = isolate;
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
Future<Isolate> _download(Task task, String rootPath) async {
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
    final task = Task.formList(message[0] as List);
    final rootPath = message[1] as String;
    final SendPort port = message[2] as SendPort;
    List<String> urls = List.from(task.urls);
    num totalSize = task.totalSize;
    num totalFileCount = task.urls.length;
    num completeFileCount = 0;

    final dio = Dio(BaseOptions());
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      logPrint: print, // specify log function (optional)
      retries: 5, // retry count (optional)
      retryDelays: const [
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
    port.send([task.id, downloadState.value, 0, 0.0, 0]);

    void onFailed() {
      port.send([task.id, DownloadState.failed, 0, 0.0, 0]);
    }

    double getProgress() {
      if (task.needCalculate || totalFileCount == 1) {
        if (totalSize == 0) return 0;
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
          port.send([task.id, downloadState.value, totalSize, 100.0, 0]);
        }
      } else {
        final url = urls.removeAt(0);
        downloadingUrl.add(url);
        num diffReceived = 0;
        if (task.urls.length == 1 && task.needSplit) {
          dio.downloadWithChunks(url, saveFilePath(rootPath, task.id, url),
              onReceiveProgress: (int received, int total) {
            if (!task.needCalculate && totalFileCount == 1) {
              totalSize = total;
            }
            downloadSize += received - diffReceived;
            diffReceived = received;
          }).then((value) {
            if (!value) {
              port.send([task.id, DownloadState.failed, 0, 0.0, 0]);
              return;
            }
            completeFileCount++;
            downloadingUrl.remove(url);
            downloadNext();
          });
        } else {
          dio.downloadFile(url, saveFilePath(rootPath, task.id, url),
              onReceiveProgress: (int received, int total) {
            if (!task.needCalculate && totalFileCount == 1) {
              totalSize = total;
            }
            downloadSize += received - diffReceived;
            diffReceived = received;
          }).then((value) {
            if (!value) {
              port.send([task.id, DownloadState.failed, 0, 0.0, 0]);
              return;
            }
            completeFileCount++;
            downloadingUrl.remove(url);
            downloadNext();
          });
        }
      }
    }

    /// 计算文件大小
    if (task.needCalculate && totalSize == 0) {
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
      if (totalSize == 0) return;
      if (totalSize != 0 || !task.needCalculate) {
        downloadState = DownloadState.download;
        port.send([
          task.id,
          downloadState.value,
          totalSize,
          getProgress(),
          downloadSize - cacheSize
        ]);
        cacheSize = downloadSize;
      }
    });
  }, [task.toList(), rootPath, receivePort.sendPort]);
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
        if (total <= received) {
          onReceiveProgress?.call(total, total);
          return true;
        }
      }
      var options = Options(headers: {'range': 'bytes=$received-'});
      await download(url, savePath,
          onReceiveProgress: onReceiveProgress, options: options);
      return true;
    } catch (e) {
      print('Error: $e');
      return false;
    }
  }

  Future downloadWithChunks(
    url,
    savePath, {
    ProgressCallback? onReceiveProgress,
  }) async {
    const firstChunkSize = 102;
    const maxChunk = 3;

    int total = 0;
    var dio = Dio();
    var progress = <int>[];

    createCallback(no) {
      return (int received, _) {
        progress[no] = received;
        if (onReceiveProgress != null && total != 0) {
          onReceiveProgress(progress.reduce((a, b) => a + b), total);
        }
      };
    }

    Future<Response> downloadChunk(url, start, end, no) async {
      progress.add(0);
      --end;
      return dio.download(
        url,
        savePath + "temp$no",
        onReceiveProgress: createCallback(no),
        options: Options(
          headers: {"range": "bytes=$start-$end"},
        ),
      );
    }

    Future mergeTempFiles(chunk) async {
      File f = File(savePath + "temp0");
      IOSink ioSink = f.openWrite(mode: FileMode.writeOnlyAppend);
      for (int i = 1; i < chunk; ++i) {
        File _f = File(savePath + "temp$i");
        await ioSink.addStream(_f.openRead());
        await _f.delete();
      }
      await ioSink.close();
      await f.rename(savePath);
    }

    Response response = await downloadChunk(url, 0, firstChunkSize, 0);
    if (response.statusCode == 206) {
      total = int.parse(response.headers
              .value(HttpHeaders.contentRangeHeader)
              ?.split("/")
              .last ??
          '0');
      int reserved = total -
          int.parse(
              response.headers.value(HttpHeaders.contentLengthHeader) ?? '0');
      int chunk = (reserved / firstChunkSize).ceil() + 1;
      if (chunk > 1) {
        int chunkSize = firstChunkSize;
        if (chunk > maxChunk + 1) {
          chunk = maxChunk + 1;
          chunkSize = (reserved / maxChunk).ceil();
        }
        var futures = <Future>[];
        for (int i = 0; i < maxChunk; ++i) {
          int start = firstChunkSize + i * chunkSize;
          futures.add(downloadChunk(url, start, start + chunkSize, i + 1));
        }
        await Future.wait(futures);
      }
      await mergeTempFiles(chunk);
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

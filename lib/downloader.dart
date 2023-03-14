import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class Downloader {
  Map<num, Isolate> downloadPool = {};

  static String _rootPath = "";

  init(String rootPath) {
    if (_rootPath.endsWith('/')) {
      _rootPath = rootPath;
    } else {
      _rootPath = '$rootPath/';
    }
  }

  Future download(num taskId, List<String> urls)async {
    if (downloadPool.containsKey(taskId)) {
      if (kDebugMode) {
        throw Exception('该任务已经添加');
      }
    }
    await _download(taskId,urls);
  }

  Future pause(num taskId)async{
    if(downloadPool.containsKey(taskId)){
      downloadPool[taskId]?.kill();
    }
  }

  Future remove(num taskId,List<String> urls ,[bool clean =false])async{
    if(downloadPool.containsKey(taskId)){
      downloadPool[taskId]?.kill();
    }
    if(clean){
      Directory directory = Directory(getTaskPath(taskId));
      if(await directory.exists()){
        await directory.delete();
      }
    }
  }

  static saveFilePath(num taskId, String url) {
    String extension = _getFileExtension(url);
    final Uri uri = Uri.parse(url);
    String filePathMd5 =
        _generate_MD5(uri.replace(queryParameters: {}).toString());
    return '$_rootPath$taskId/$filePathMd5.$extension';
  }
  static getTaskPath(num taskId){
    return '$_rootPath$taskId';
  }
}

Future<Isolate> _download(num taskId, List<String> urls)async{
  var receivePort = ReceivePort();
  receivePort.listen((message) {

  });
  return await Isolate.spawn((message) {
    num cacheSize = 0;
    final taskId = message[0];
    List<String> urls = message[1] as List<String>;
    final receivePort = message[2];
    Timer.periodic(const Duration(seconds: 1), (timer) {

    });
    final dio =  Dio();
  }, [taskId, urls,receivePort]);
}
// md5 加密
String _generate_MD5(String data) {
  var content = const Utf8Encoder().convert(data);
  var digest = md5.convert(content);
  return digest.toString();
}

String _getFileExtension(String url) {
  return url.substring(url.lastIndexOf('.') + 1);
}

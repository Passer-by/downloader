class Task {
  // 任务唯一表示
  final num id;

  // 下载链接
  final List<String> urls;

  // 请求头
  final Map<String, dynamic> header;

  // 文件总大小
  final num totalSize;

  // 是否需要计算
  final bool needCalculate;

  // 是否需要切割下载
  final bool needSplit;

  // 切割下载的最大值
  final num sliceSize;

  const Task({
    required this.id,
    required this.urls,
    this.header = const {},
    this.totalSize = 0,
    this.needCalculate = false,
    this.needSplit = false,
    this.sliceSize = 500 << 20,
  });

  List toList() {
    return [id, urls, header, totalSize, needCalculate, needSplit, sliceSize];
  }

  factory Task.formList(List list) {
    return Task(
      id: list[0],
      urls: list[1],
      header: list[2] ?? {},
      totalSize: list[3] ?? 0,
      needCalculate: list[4] ?? false,
      needSplit: list[5] ?? false,
      sliceSize: list[6] ?? 500 << 20,
    );
  }
}

enum DownloadState {
  unknown(-1),
  pre(0),

  pause(2),
  download(3),
  complete(4),
  failed(5);

  final int value;

  const DownloadState(this.value);

  static DownloadState formValue(int value) {
    return DownloadState.values.firstWhere(
          (element) => element.value == value,
      orElse: () => DownloadState.unknown,
    );
  }
}

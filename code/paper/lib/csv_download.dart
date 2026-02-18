import 'csv_download_stub.dart'
    if (dart.library.html) 'csv_download_web.dart' as impl;

void downloadCsv(String filename, String content) {
  impl.downloadCsv(filename, content);
}

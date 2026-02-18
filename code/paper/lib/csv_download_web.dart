import 'dart:convert';
import 'dart:html' as html;

void downloadCsv(String filename, String content) {
  final List<int> bytes = utf8.encode('\uFEFF$content');
  final html.Blob blob = html.Blob(<dynamic>[bytes], 'text/csv;charset=utf-8;');
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement anchor = html.AnchorElement(href: url)
    ..style.display = 'none'
    ..download = filename;
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}

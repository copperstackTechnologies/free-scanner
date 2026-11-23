import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/scan_doc.dart';

/// All data lives in the app's private folder. Nothing leaves the device.
class Storage {
  static late Directory root;
  static List<ScanDoc> docs = [];
  static int _counter = 0;

  static File get _index => File(p.join(root.path, 'index.json'));

  static Future<void> init() async {
    final base = await getApplicationDocumentsDirectory();
    root = Directory(p.join(base.path, 'scans'))..createSync(recursive: true);
    if (_index.existsSync()) {
      try {
        final list = jsonDecode(_index.readAsStringSync()) as List;
        docs = list
            .map((e) => ScanDoc.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        docs = [];
      }
    }
  }

  static Future<void> save() =>
      _index.writeAsString(jsonEncode(docs.map((d) => d.toJson()).toList()));

  static String pagePath(ScanDoc d, String page) =>
      p.join(root.path, d.id, page);

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String defaultName(DateTime t) =>
      'Scan ${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  static Future<List<String>> _copyIn(ScanDoc d, List<String> srcs) async {
    final dir = Directory(p.join(root.path, d.id))..createSync(recursive: true);
    final names = <String>[];
    for (final s in srcs) {
      final name =
          'page_${DateTime.now().microsecondsSinceEpoch}_${_counter++}.jpg';
      await File(s).copy(p.join(dir.path, name));
      names.add(name);
    }
    return names;
  }

  static Future<ScanDoc> createDoc(List<String> srcs) async {
    final now = DateTime.now();
    final d = ScanDoc(
      id: now.microsecondsSinceEpoch.toString(),
      name: defaultName(now),
      created: now,
      pages: [],
    );
    d.pages.addAll(await _copyIn(d, srcs));
    docs.insert(0, d);
    await save();
    return d;
  }

  static Future<void> addPages(ScanDoc d, List<String> srcs) async {
    d.pages.addAll(await _copyIn(d, srcs));
    await save();
  }

  static Future<void> duplicatePage(ScanDoc d, int index) async {
    if (index < 0 || index >= d.pages.length) {
      throw RangeError.index(index, d.pages, 'index');
    }
    final copies = await _copyIn(d, [pagePath(d, d.pages[index])]);
    d.pages.insert(index + 1, copies.single);
    await save();
  }

  static Future<void> removePage(ScanDoc d, int index) async {
    final name = d.pages.removeAt(index);
    final f = File(pagePath(d, name));
    if (f.existsSync()) f.deleteSync();
    await save();
  }

  static Future<void> deleteDoc(ScanDoc d) async {
    final dir = Directory(p.join(root.path, d.id));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    docs.removeWhere((x) => x.id == d.id);
    await save();
  }
}

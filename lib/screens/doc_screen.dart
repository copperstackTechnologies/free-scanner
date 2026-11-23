import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_doc.dart';
import '../services/image_tools.dart';
import '../services/ocr_service.dart';
import '../services/scanner_service.dart';
import '../services/storage.dart';

class DocScreen extends StatefulWidget {
  final ScanDoc doc;
  const DocScreen({super.key, required this.doc});
  @override
  State<DocScreen> createState() => _DocScreenState();
}

class _DocScreenState extends State<DocScreen> {
  ScanDoc get d => widget.doc;
  bool busy = false;

  String _path(String page) => Storage.pagePath(d, page);

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _ocr() async {
    setState(() => busy = true);
    await OcrService.run(d);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _scanNewDocument() async {
    final srcs = await ScannerService.scan(context);
    if (srcs.isEmpty || !mounted) return;
    final newDoc = await Storage.createDoc(srcs);
    await OcrService.run(newDoc);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => DocScreen(doc: newDoc)),
    );
  }

  Future<void> _rotate(int i) async {
    final path = _path(d.pages[i]);
    setState(() => busy = true);
    await rotateFile(path);
    await FileImage(File(path)).evict();
    if (mounted) setState(() => busy = false);
  }

  Future<void> _duplicatePage(int index) async {
    setState(() => busy = true);
    try {
      await Storage.duplicatePage(d, index);
      await OcrService.run(d);
      if (mounted) {
        setState(() => busy = false);
        _toast('Page duplicated');
      }
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        _toast('Could not duplicate this page.');
      }
    }
  }

  Future<void> _filterPage(int index) async {
    final filter = await showModalBottomSheet<ScanFilter>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Edit scan')),
            ListTile(
              leading: const Icon(Icons.auto_fix_high_outlined),
              title: const Text('Auto enhance'),
              onTap: () => Navigator.pop(sheetContext, ScanFilter.enhance),
            ),
            ListTile(
              leading: const Icon(Icons.filter_b_and_w_outlined),
              title: const Text('Black and white'),
              onTap: () =>
                  Navigator.pop(sheetContext, ScanFilter.blackAndWhite),
            ),
            ListTile(
              leading: const Icon(Icons.photo_filter_outlined),
              title: const Text('Grayscale'),
              onTap: () => Navigator.pop(sheetContext, ScanFilter.grayscale),
            ),
            ListTile(
              leading: const Icon(Icons.tonality_outlined),
              title: const Text('Sepia'),
              onTap: () => Navigator.pop(sheetContext, ScanFilter.sepia),
            ),
          ],
        ),
      ),
    );
    if (filter == null) return;
    final path = _path(d.pages[index]);
    setState(() => busy = true);
    try {
      await applyScanFilter(path, filter);
      await FileImage(File(path)).evict();
      await OcrService.run(d);
    } catch (_) {
      if (mounted) _toast('Could not edit this page.');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _deletePage(int i) async {
    if (d.pages.length == 1) {
      await _deleteDoc();
      return;
    }
    await Storage.removePage(d, i);
    if (mounted) setState(() {});
  }

  Future<void> _deleteDoc() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete document?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Storage.deleteDoc(d);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    d.name = name;
    await Storage.save();
    if (mounted) setState(() {});
  }

  String get _safeName => d.name.replaceAll(RegExp(r'[^\w\- ]'), '_');

  Future<Quality?> _choosePdfQuality() => showModalBottomSheet<Quality>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('PDF quality')),
          ListTile(
            title: const Text('Small'),
            subtitle: const Text('Best for sharing over chat'),
            onTap: () => Navigator.pop(c, Quality.small),
          ),
          ListTile(
            title: const Text('Standard'),
            onTap: () => Navigator.pop(c, Quality.standard),
          ),
          ListTile(
            title: const Text('High'),
            subtitle: const Text('Best for printing'),
            onTap: () => Navigator.pop(c, Quality.high),
          ),
        ],
      ),
    ),
  );

  Future<void> _exportPdf({int? pageIndex}) async {
    final q = await _choosePdfQuality();
    if (q == null) return;
    setState(() => busy = true);
    try {
      final tmp = await getTemporaryDirectory();
      final pageSuffix = pageIndex == null ? '' : '_page_${pageIndex + 1}';
      final out = p.join(tmp.path, '$_safeName$pageSuffix.pdf');
      final paths = pageIndex == null
          ? d.pages.map(_path).toList()
          : [_path(d.pages[pageIndex])];
      await buildPdf(paths, out, q);
      await Share.shareXFiles([XFile(out)]);
    } catch (e) {
      if (mounted) _toast('Export failed');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _exportJpgs() async {
    await Share.shareXFiles(d.pages.map((n) => XFile(_path(n))).toList());
  }

  Future<void> _sharePage(int index, {required bool asPdf}) async {
    final imagePath = _path(d.pages[index]);
    if (!asPdf) {
      await Share.shareXFiles([XFile(imagePath)]);
      return;
    }
    await _exportPdf(pageIndex: index);
  }

  Future<void> _shareWholeScan() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Share scanned document')),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('All pages as PDF'),
              subtitle: const Text('Choose PDF quality next'),
              onTap: () => Navigator.pop(c, 'pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('All pages as images'),
              onTap: () => Navigator.pop(c, 'images'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'pdf') await _exportPdf();
    if (choice == 'images') await _exportJpgs();
  }

  void _showText() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, sc) => Column(
          children: [
            ListTile(
              title: const Text('Scanned text'),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: d.ocrText));
                  _toast('Copied');
                },
              ),
            ),
            Expanded(
              child: d.ocrText.isEmpty
                  ? const Center(child: Text('No text found yet.'))
                  : ListView(
                      controller: sc,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: _textBlocks(d.ocrText).map((block) {
                        final heading =
                            block.length < 72 &&
                            block == block.toUpperCase() &&
                            RegExp(r'[A-Z]').hasMatch(block);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: SelectableText(
                            block,
                            style: heading
                                ? Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)
                                : Theme.of(
                                    context,
                                  ).textTheme.bodyLarge?.copyWith(height: 1.55),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _textBlocks(String text) => text
      .split(RegExp(r'\n\s*\n+'))
      .map((block) => block.replaceAll(RegExp(r'[ \t]*\n[ \t]*'), ' ').trim())
      .where((block) => block.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(d.name, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _rename();
                case 'share':
                  _shareWholeScan();
                case 'text':
                  _showText();
                case 'ocr':
                  _ocr();
                case 'jpg':
                  _exportJpgs();
                case 'delete':
                  _deleteDoc();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'share', child: Text('Share')),
              PopupMenuItem(value: 'text', child: Text('View text')),
              PopupMenuItem(
                value: 'ocr',
                child: Text('Re-run text recognition'),
              ),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
        bottom: busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: ReorderableListView.builder(
        itemCount: d.pages.length,
        onReorderItem: (o, n) async {
          final x = d.pages.removeAt(o);
          d.pages.insert(n, x);
          await Storage.save();
          setState(() {});
        },
        itemBuilder: (_, i) {
          final path = _path(d.pages[i]);
          return ListTile(
            key: ValueKey(d.pages[i]),
            leading: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text('Page ${i + 1}')),
                    body: InteractiveViewer(
                      maxScale: 6,
                      child: Center(child: Image.file(File(path))),
                    ),
                  ),
                ),
              ),
              child: SizedBox(
                width: 56,
                height: 72,
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                ),
              ),
            ),
            title: Text('Page ${i + 1}'),
            subtitle: const Text('Long-press to reorder'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Share page',
                  icon: const Icon(Icons.share_outlined),
                  onSelected: (action) => _sharePage(i, asPdf: action == 'pdf'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'image',
                      child: Text('Share as image'),
                    ),
                    PopupMenuItem(value: 'pdf', child: Text('Share as PDF')),
                  ],
                ),
                PopupMenuButton<String>(
                  tooltip: 'More page actions',
                  onSelected: (action) {
                    switch (action) {
                      case 'rotate':
                        _rotate(i);
                      case 'duplicate':
                        _duplicatePage(i);
                      case 'edit':
                        _filterPage(i);
                      case 'delete':
                        _deletePage(i);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Text('Duplicate page below'),
                    ),
                    PopupMenuItem(value: 'edit', child: Text('Edit filters')),
                    PopupMenuItem(value: 'rotate', child: Text('Rotate page')),
                    PopupMenuItem(value: 'delete', child: Text('Delete page')),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanNewDocument,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Scan new document'),
      ),
    );
  }
}

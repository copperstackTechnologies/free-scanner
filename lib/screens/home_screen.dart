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
import '../services/app_update_service.dart';
import 'doc_screen.dart';
import '../main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int tab = 0;
  String query = '';
  String phoneQuery = '';
  final Set<String> _selectedScanIds = {};
  static const _deviceDocuments = MethodChannel(
    'free_scanner/device_documents',
  );
  bool phoneAccess = false;
  bool loadingPhoneDocs = false;
  List<Map<String, dynamic>> phoneDocuments = [];
  final AppUpdateService _appUpdateService = AppUpdateService();
  AppUpdate? _availableUpdate;
  String? _updateMessage;
  bool _checkingUpdates = false;
  bool _downloadingUpdate = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPhoneDocuments();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final version = await _appUpdateService.currentVersion();
      if (mounted) setState(() => _appVersion = version);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && tab == 2) {
      _refreshPhoneDocuments();
    }
  }

  Future<void> _refreshPhoneDocuments() async {
    try {
      final allowed =
          await _deviceDocuments.invokeMethod<bool>('hasFileAccess') ?? false;
      if (!mounted) return;
      setState(() {
        phoneAccess = allowed;
        loadingPhoneDocs = allowed;
      });
      if (!allowed) return;
      final rows =
          await _deviceDocuments.invokeListMethod<dynamic>('listDocuments') ??
          [];
      if (!mounted) return;
      setState(() {
        phoneDocuments = rows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        loadingPhoneDocs = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => loadingPhoneDocs = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not scan phone documents.'),
        ),
      );
    }
  }

  Future<void> _requestPhoneAccess() async {
    await _deviceDocuments.invokeMethod<Object?>('requestFileAccess');
    await _refreshPhoneDocuments();
  }

  Future<void> _checkForAppUpdates({bool silent = false}) async {
    if (_checkingUpdates) return;
    setState(() {
      _checkingUpdates = true;
      _updateMessage = null;
    });
    try {
      final update = await _appUpdateService.check();
      if (!mounted) return;
      setState(() {
        _availableUpdate = update.available ? update : null;
        _updateMessage = update.available
            ? 'Version ${update.latestVersion} is available on GitHub.'
            : 'You’re using the latest version (${update.currentVersion}).';
      });
    } on NoPublishedReleaseException {
      if (!mounted) return;
      setState(() {
        _availableUpdate = null;
        _updateMessage =
            'No published update was found. Updates appear here after a release is published.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _updateMessage =
            'Could not check for updates. Check your connection and try again.',
      );
      if (!silent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Update check failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _downloadAppUpdate() async {
    final update = _availableUpdate;
    if (update == null || _downloadingUpdate) return;
    setState(() => _downloadingUpdate = true);
    try {
      final message = await _appUpdateService.downloadUpdate(update);
      if (!mounted) return;
      setState(() => _updateMessage = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      final message = 'Could not start the APK download: $error';
      setState(() => _updateMessage = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _downloadingUpdate = false);
    }
  }

  Future<void> _openPhoneDocument(Map<String, dynamic> document) async {
    final path = document['path'] as String;
    final name = document['name'] as String? ?? 'Document';
    final extension = document['extension'] as String? ?? '';
    if (extension == 'pdf') {
      await _deviceDocuments.invokeMethod<void>('viewPdf', {
        'path': path,
        'title': name,
      });
      return;
    }
    if (!mounted) return;
    const officeFormats = {
      'docx',
      'xlsx',
      'pptx',
      'odt',
      'ods',
      'odp',
      'epub',
      'html',
      'htm',
      'rtf',
    };
    final text = officeFormats.contains(extension)
        ? _deviceDocuments
              .invokeMethod<String>('extractDocumentText', {'path': path})
              .then((value) => value ?? '')
        : File(path).readAsString();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhoneFilePreview(name: name, content: text),
      ),
    );
  }

  Future<void> _renamePhoneDocument(Map<String, dynamic> document) async {
    final controller = TextEditingController(
      text: document['name'] as String? ?? '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename document'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _runPhoneFileAction('renameDocument', {
      'path': document['path'],
      'name': name,
    });
  }

  Future<void> _deletePhoneDocument(Map<String, dynamic> document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('Delete “${document['name']}” from this phone?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runPhoneFileAction('deleteDocument', {'path': document['path']});
    }
  }

  Future<void> _copyOrMovePhoneDocument(
    Map<String, dynamic> document, {
    required bool move,
  }) async {
    final dirs =
        await _deviceDocuments.invokeListMethod<dynamic>('listDirectories') ??
        [];
    final selected = await _choosePhoneFolder(
      dirs.map((row) => Map<String, String>.from(row as Map)).toList(),
    );
    if (selected == null) return;
    await _runPhoneFileAction(move ? 'moveDocument' : 'copyDocument', {
      'path': document['path'],
      'destination': selected,
    });
  }

  Future<void> _runPhoneFileAction(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      await _deviceDocuments.invokeMethod<void>(method, args);
      await _refreshPhoneDocuments();
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.message ?? 'Could not complete that file action.',
            ),
          ),
        );
      }
    }
  }

  Future<String?> _choosePhoneFolder(List<Map<String, String>> folders) {
    final controller = TextEditingController();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final visible = folders
              .where(
                (folder) =>
                    (folder['name'] ?? '').toLowerCase().contains(
                      controller.text.toLowerCase(),
                    ) ||
                    (folder['path'] ?? '').toLowerCase().contains(
                      controller.text.toLowerCase(),
                    ),
              )
              .take(300)
              .toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .75,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: TextField(
                      controller: controller,
                      onChanged: (_) => update(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Find a folder',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final folder = visible[index];
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(folder['name'] ?? ''),
                          subtitle: Text(
                            folder['path'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () =>
                              Navigator.pop(sheetContext, folder['path']),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _scan(String type) async {
    final limit = type == 'Single document'
        ? 1
        : type == 'ID card'
        ? 2
        : 50;
    var pages = await ScannerService.scan(context, pageLimit: limit);
    if (!mounted || pages.isEmpty) return;
    if (type == 'ID card') {
      final combined =
          '${Storage.root.path}${Platform.pathSeparator}card_${DateTime.now().microsecondsSinceEpoch}.jpg';
      pages = [await combineCardSides(pages.take(2).toList(), combined)];
    }
    final doc = await Storage.createDoc(pages);
    if (type == 'ID card' && pages.single.contains('card_')) {
      File(pages.single).deleteSync();
    }
    if (type == 'Batch scan') {
      final folder = Directory(
        '${Storage.root.path}${Platform.pathSeparator}${doc.id}',
      );
      await buildPdf(
        doc.pages.map((p) => Storage.pagePath(doc, p)).toList(),
        '${folder.path}${Platform.pathSeparator}${doc.name}.pdf',
        Quality.standard,
      );
    }
    if (!mounted) return;
    setState(() {});
    OcrService.run(doc).then((_) {
      if (mounted) setState(() {});
    });
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocScreen(doc: doc)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _chooseScan() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose scan type',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              _scanChoice(
                context,
                'ID card',
                'Capture front and back',
                Icons.credit_card,
              ),
              _scanChoice(
                context,
                'Single document',
                'One page, ready to share',
                Icons.description_outlined,
              ),
              _scanChoice(
                context,
                'Batch scan',
                'Multiple pages saved as one PDF',
                Icons.library_books_outlined,
              ),
            ],
          ),
        ),
      ),
    );
    if (type != null) _scan(type);
  }

  Widget _scanChoice(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(child: Icon(icon)),
    title: Text(title),
    subtitle: Text(subtitle),
    onTap: () => Navigator.pop(context, title),
  );

  Future<void> _openDoc(ScanDoc doc) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocScreen(doc: doc)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _manageScan(ScanDoc doc, String action) async {
    if (action == 'open') return _openDoc(doc);
    if (action == 'rename') {
      final controller = TextEditingController(text: doc.name);
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename scan'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (name == null || name.isEmpty) return;
      doc.name = name;
      await Storage.save();
      if (mounted) setState(() {});
      return;
    }
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete scan?'),
          content: Text('Delete “${doc.name}” and all its pages?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await Storage.deleteDoc(doc);
        if (mounted) setState(() {});
      }
      return;
    }
    if (action == 'pdf') {
      final quality = await _choosePdfQuality();
      if (quality == null) return;
      final directory = await getTemporaryDirectory();
      final output = p.join(
        directory.path,
        '${doc.name.replaceAll(RegExp(r'[^\\w -]'), '_')}.pdf',
      );
      await buildPdf(
        doc.pages.map((page) => Storage.pagePath(doc, page)).toList(),
        output,
        quality,
      );
      await Share.shareXFiles([XFile(output)]);
    } else if (action == 'images') {
      await Share.shareXFiles(
        doc.pages.map((page) => XFile(Storage.pagePath(doc, page))).toList(),
      );
    }
  }

  Future<Quality?> _choosePdfQuality() => showModalBottomSheet<Quality>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('PDF quality')),
          ListTile(
            title: const Text('Small'),
            onTap: () => Navigator.pop(sheetContext, Quality.small),
          ),
          ListTile(
            title: const Text('Standard'),
            onTap: () => Navigator.pop(sheetContext, Quality.standard),
          ),
          ListTile(
            title: const Text('High'),
            onTap: () => Navigator.pop(sheetContext, Quality.high),
          ),
        ],
      ),
    ),
  );

  Future<void> _extractTextWithoutSaving() async {
    final paths = await ScannerService.scan(context, pageLimit: 50);
    if (paths.isEmpty || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Extracting text…')),
          ],
        ),
      ),
    );
    String text;
    try {
      text = await OcrService.extractTextFromImages(paths);
    } catch (_) {
      text = '';
    } finally {
      for (final path in paths) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Extracted text',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy text',
                      onPressed: text.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(text: text),
                              );
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Text copied')),
                                );
                              }
                            },
                      icon: const Icon(Icons.copy_outlined),
                    ),
                    IconButton(
                      tooltip: 'Share as text file',
                      onPressed: text.isEmpty
                          ? null
                          : () async {
                              final dir = await getTemporaryDirectory();
                              final file = File(
                                p.join(dir.path, 'extracted_text.txt'),
                              );
                              await file.writeAsString(text);
                              await Share.shareXFiles([
                                XFile(file.path),
                              ], text: 'Extracted text');
                            },
                      icon: const Icon(Icons.share_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: text.isEmpty
                    ? const Center(child: Text('No text was detected.'))
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: SelectableText(
                          text,
                          style: Theme.of(
                            sheetContext,
                          ).textTheme.bodyLarge?.copyWith(height: 1.55),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _docList(List<ScanDoc> docs) {
    final filtered = docs
        .where(
          (d) =>
              d.name.toLowerCase().contains(query.toLowerCase()) ||
              d.ocrText.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    if (filtered.isEmpty) {
      return const Center(
        child: Text('No documents yet. Start a scan to see it here.'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final d = filtered[i];
        final isSelected = _selectedScanIds.contains(d.id);
        final file = d.pages.isEmpty
            ? null
            : File(Storage.pagePath(d, d.pages.first));
        return Card(
          color: isSelected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          child: ListTile(
            contentPadding: const EdgeInsets.all(10),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 54,
                height: 64,
                child: file != null && file.existsSync()
                    ? Image.file(file, fit: BoxFit.cover)
                    : const Icon(Icons.description_outlined),
              ),
            ),
            title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${d.pages.length} page${d.pages.length == 1 ? '' : 's'}',
            ),
            trailing: _selectedScanIds.isNotEmpty
                ? Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleScanSelection(d),
                  )
                : PopupMenuButton<String>(
                    tooltip: 'Scan actions',
                    onSelected: (action) => _manageScan(d, action),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('Open')),
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                        value: 'pdf',
                        child: Text('Share all pages as PDF'),
                      ),
                      PopupMenuItem(
                        value: 'images',
                        child: Text('Share pages as images'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
            onLongPress: () => _toggleScanSelection(d),
            onTap: () => _selectedScanIds.isNotEmpty
                ? _toggleScanSelection(d)
                : _openDoc(d),
          ),
        );
      },
    );
  }

  void _toggleScanSelection(ScanDoc doc) {
    setState(() {
      if (!_selectedScanIds.add(doc.id)) _selectedScanIds.remove(doc.id);
    });
  }

  void _toggleSelectAllScans(List<ScanDoc> visibleDocs) {
    setState(() {
      final allVisibleSelected =
          visibleDocs.isNotEmpty &&
          visibleDocs.every((doc) => _selectedScanIds.contains(doc.id));
      if (allVisibleSelected) {
        _selectedScanIds.removeAll(visibleDocs.map((doc) => doc.id));
      } else {
        _selectedScanIds.addAll(visibleDocs.map((doc) => doc.id));
      }
    });
  }

  Future<void> _applyBulkScanAction(String action) async {
    final selected = Storage.docs
        .where((doc) => _selectedScanIds.contains(doc.id))
        .toList();
    if (selected.isEmpty) return;
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Delete ${selected.length} scans?'),
          content: const Text(
            'All selected scans and their pages will be deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      for (final doc in selected) {
        await Storage.deleteDoc(doc);
      }
      if (mounted) setState(_selectedScanIds.clear);
      return;
    }

    final paths = selected
        .expand((doc) => doc.pages.map((page) => Storage.pagePath(doc, page)))
        .toList();
    if (paths.isEmpty) return;
    if (action == 'images') {
      await Share.shareXFiles(paths.map((path) => XFile(path)).toList());
      return;
    }
    final quality = await _choosePdfQuality();
    if (quality == null) return;
    final directory = await getTemporaryDirectory();
    final output = p.join(
      directory.path,
      'Selected_scans_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await buildPdf(paths, output, quality);
    await Share.shareXFiles([XFile(output)]);
  }

  Widget _home() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
    children: [
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paperwork, made simple.',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Scan, organize and share your documents privately.'),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _chooseScan,
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Start a scan'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      Text('Quick actions', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _quickAction(
              Icons.credit_card,
              'ID card',
              () => _scan('ID card'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _quickAction(
              Icons.library_books_outlined,
              'Batch PDF',
              () => _scan('Batch scan'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _quickAction(
              Icons.text_snippet_outlined,
              'Extract text',
              _extractTextWithoutSaving,
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Recent scans', style: Theme.of(context).textTheme.titleLarge),
          TextButton(
            onPressed: () => setState(() => tab = 1),
            child: const Text('See all'),
          ),
        ],
      ),
      if (Storage.docs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('Your recent scans will appear here.')),
        )
      else
        ...Storage.docs.take(5).map((d) => _recentTile(d)),
    ],
  );

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _recentTile(ScanDoc d) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
    title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text('${d.pages.length} pages'),
    trailing: PopupMenuButton<String>(
      onSelected: (action) => _manageScan(d, action),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'pdf', child: Text('Share all pages as PDF')),
        PopupMenuItem(value: 'images', child: Text('Share pages as images')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    ),
    onTap: () => _openDoc(d),
  );

  Widget _settings() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Card(
        child: RadioGroup<ThemeMode>(
          groupValue: appThemeMode.value,
          onChanged: (value) {
            if (value != null) appThemeMode.value = value;
          },
          child: const Column(
            children: [
              RadioListTile<ThemeMode>(
                title: Text('System default'),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Light'),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Dark'),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('App updates', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.system_update_alt),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Check for updates',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _updateMessage ??
                    'Checking for the latest Free Scanner release.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _checkingUpdates
                        ? null
                        : () => _checkForAppUpdates(),
                    icon: _checkingUpdates
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_checkingUpdates ? 'Checking…' : 'Check now'),
                  ),
                  if (_availableUpdate != null)
                    FilledButton.icon(
                      onPressed: _downloadingUpdate ? null : _downloadAppUpdate,
                      icon: _downloadingUpdate
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      label: Text(
                        _downloadingUpdate ? 'Starting…' : 'Download update',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('About', style: Theme.of(context).textTheme.titleLarge),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/free_scanner_icon.png',
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Free Scanner',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A free simple way to capture, organize, and share your documents.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Made for everyday paperwork',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Center(
        child: Column(
          children: [
            Text(
              'Version ${_appVersion.isEmpty ? '—' : _appVersion}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 3),
            Text(
              'from Copperstack',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _phoneDocuments() {
    if (!phoneAccess) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Text(
            'Find and manage PDFs, office files, and text documents stored on this device. Images are excluded.',
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.folder_shared_outlined),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Allow access to scan and manage documents on your phone.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _requestPhoneAccess,
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Allow file access'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final filtered = phoneDocuments
        .where(
          (document) => (document['name'] as String).toLowerCase().contains(
            phoneQuery.toLowerCase(),
          ),
        )
        .toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount:
          2 + (loadingPhoneDocs || filtered.isEmpty ? 1 : filtered.length),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              'Find and manage PDFs, office files, and text documents stored on this device. Images are excluded.',
            ),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                TextField(
                  onChanged: (value) => setState(() => phoneQuery = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search phone documents',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${filtered.length} documents found',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _refreshPhoneDocuments,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        if (loadingPhoneDocs) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (filtered.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              phoneDocuments.isEmpty
                  ? 'No supported documents were found in shared storage.'
                  : 'No documents match your search.',
            ),
          );
        }
        final document = filtered[index - 2];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(
                document['extension'] == 'pdf'
                    ? Icons.picture_as_pdf_outlined
                    : Icons.description_outlined,
              ),
            ),
            title: Text(
              document['name'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${_formatSize(document['size'] as int)}  •  ${document['path']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _openPhoneDocument(document),
            trailing: PopupMenuButton<String>(
              tooltip: 'Manage document',
              onSelected: (action) {
                switch (action) {
                  case 'rename':
                    _renamePhoneDocument(document);
                  case 'copy':
                    _copyOrMovePhoneDocument(document, move: false);
                  case 'move':
                    _copyOrMovePhoneDocument(document, move: true);
                  case 'delete':
                    _deletePhoneDocument(document);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'copy', child: Text('Copy to folder')),
                PopupMenuItem(value: 'move', child: Text('Move to folder')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatSize(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final titles = [
      'Free Scanner',
      'Scanned documents',
      'Documents',
      'Settings',
    ];
    final visibleScans = Storage.docs
        .where(
          (doc) =>
              doc.name.toLowerCase().contains(query.toLowerCase()) ||
              doc.ocrText.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final selectingScans = tab == 1 && _selectedScanIds.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: selectingScans
            ? IconButton(
                tooltip: 'Clear selection',
                icon: const Icon(Icons.close),
                onPressed: () => setState(_selectedScanIds.clear),
              )
            : null,
        title: Text(
          selectingScans ? '${_selectedScanIds.length} selected' : titles[tab],
        ),
        centerTitle: true,
        actions: tab == 1
            ? [
                if (selectingScans)
                  IconButton(
                    tooltip:
                        visibleScans.isNotEmpty &&
                            visibleScans.every(
                              (doc) => _selectedScanIds.contains(doc.id),
                            )
                        ? 'Deselect all'
                        : 'Select all',
                    icon: Icon(
                      visibleScans.isNotEmpty &&
                              visibleScans.every(
                                (doc) => _selectedScanIds.contains(doc.id),
                              )
                          ? Icons.deselect
                          : Icons.select_all,
                    ),
                    onPressed: () => _toggleSelectAllScans(visibleScans),
                  ),
                if (selectingScans)
                  PopupMenuButton<String>(
                    tooltip: 'Selected scan actions',
                    onSelected: _applyBulkScanAction,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'pdf',
                        child: Text('Share as one PDF'),
                      ),
                      PopupMenuItem(
                        value: 'images',
                        child: Text('Share as images'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                IconButton(
                  tooltip: 'Search scanned documents',
                  icon: const Icon(Icons.search),
                  onPressed: () => showSearch(
                    context: context,
                    delegate: _DocumentSearch(Storage.docs, _openDoc),
                  ),
                ),
              ]
            : null,
      ),
      body: switch (tab) {
        0 => _home(),
        1 => _docList(Storage.docs),
        2 => _phoneDocuments(),
        _ => _settings(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() {
            tab = i;
            if (i != 1) _selectedScanIds.clear();
          });
          if (i == 2) _refreshPhoneDocuments();
          if (i == 3) _checkForAppUpdates(silent: true);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_copy_outlined),
            selectedIcon: Icon(Icons.folder_copy),
            label: 'Scanned',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_open_outlined),
            selectedIcon: Icon(Icons.folder_open),
            label: 'Documents',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _PhoneFilePreview extends StatelessWidget {
  final String name;
  final Future<String> content;
  const _PhoneFilePreview({required this.name, required this.content});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: FutureBuilder<String>(
      future: content,
      builder: (context, snapshot) => snapshot.hasData
          ? ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SelectableText(
                  snapshot.data!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(height: 1.55),
                ),
              ],
            )
          : snapshot.hasError
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'This document format cannot be previewed in the app.',
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    ),
  );
}

class _DocumentSearch extends SearchDelegate<void> {
  final List<ScanDoc> docs;
  final Future<void> Function(ScanDoc) open;
  _DocumentSearch(this.docs, this.open);
  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);
  Widget _results(BuildContext context) {
    final found = docs
        .where((d) => d.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return ListView(
      children: found
          .map(
            (d) => ListTile(
              title: Text(d.name),
              onTap: () {
                close(context, null);
                open(d);
              },
            ),
          )
          .toList(),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear)),
  ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );
}

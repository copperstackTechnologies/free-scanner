import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

enum Quality { small, standard, high }

enum ScanFilter { enhance, grayscale, blackAndWhite, sepia }

Future<void> applyScanFilter(String path, ScanFilter filter) =>
    Isolate.run<void>(() {
      final raw = img.decodeImage(File(path).readAsBytesSync());
      if (raw == null) return;
      var image = img.bakeOrientation(raw);
      switch (filter) {
        case ScanFilter.enhance:
          image = img.adjustColor(image, brightness: 1.06, contrast: 1.12);
        case ScanFilter.grayscale:
          image = img.grayscale(image);
        case ScanFilter.blackAndWhite:
          image = img.luminanceThreshold(img.grayscale(image), threshold: 0.62);
        case ScanFilter.sepia:
          image = img.sepia(image);
      }
      File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
    });

int _maxSide(Quality q) => switch (q) {
  Quality.small => 1200,
  Quality.standard => 1800,
  Quality.high => 0, // keep original size
};

int _jpgQuality(Quality q) => switch (q) {
  Quality.small => 60,
  Quality.standard => 80,
  Quality.high => 92,
};

Future<void> rotateFile(String path) => Isolate.run<void>(() {
  final raw = img.decodeImage(File(path).readAsBytesSync());
  if (raw == null) return;
  final r = img.copyRotate(img.bakeOrientation(raw), angle: 90);
  File(path).writeAsBytesSync(img.encodeJpg(r, quality: 95));
});

Future<String> combineCardSides(List<String> paths, String outPath) =>
    Isolate.run<String>(() {
      final decoded = paths
          .map((path) => img.decodeImage(File(path).readAsBytesSync()))
          .whereType<img.Image>()
          .map(img.bakeOrientation)
          .take(2)
          .toList();
      if (decoded.isEmpty) return paths.first;

      // A4 portrait at approximately 150 DPI, with ID sides at their standard
      // 85.6 x 54 mm print size and a clear vertical gap between them.
      const pageWidth = 1240;
      const pageHeight = 1754;
      final cardWidth = (pageWidth * 85.6 / 210).round();
      final cardHeight = (pageHeight * 54 / 297).round();
      final sideGap = (pageHeight * 42 / 297).round();
      final stackHeight =
          decoded.length * cardHeight + (decoded.length - 1) * sideGap;
      final stackTop = (pageHeight - stackHeight) ~/ 2;
      final canvas = img.Image(
        width: pageWidth,
        height: pageHeight,
        numChannels: 3,
      );
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

      for (var i = 0; i < decoded.length; i++) {
        final source = decoded[i];
        final scale = (cardWidth / source.width).clamp(
          0.0,
          cardHeight / source.height,
        );
        final side = img.copyResize(
          source,
          width: (source.width * scale).round(),
          height: (source.height * scale).round(),
        );
        final slotTop = stackTop + i * (cardHeight + sideGap);
        final x = (pageWidth - side.width) ~/ 2;
        final y = slotTop + (cardHeight - side.height) ~/ 2;
        img.compositeImage(canvas, side, dstX: x, dstY: y);
      }
      File(outPath).writeAsBytesSync(img.encodeJpg(canvas, quality: 92));
      return outPath;
    });

Future<String> buildPdf(List<String> paths, String outPath, Quality q) =>
    Isolate.run<String>(() async {
      final doc = pw.Document();
      final maxSide = _maxSide(q);
      for (final path in paths) {
        final raw = img.decodeImage(File(path).readAsBytesSync());
        if (raw == null) continue;
        var im = img.bakeOrientation(raw);
        if (maxSide > 0 && (im.width > maxSide || im.height > maxSide)) {
          im = im.width >= im.height
              ? img.copyResize(im, width: maxSide)
              : img.copyResize(im, height: maxSide);
        }
        final bytes = Uint8List.fromList(
          img.encodeJpg(im, quality: _jpgQuality(q)),
        );
        final image = pw.MemoryImage(bytes);
        final landscape = im.width > im.height;
        doc.addPage(
          pw.Page(
            pageFormat: landscape
                ? PdfPageFormat.a4.landscape
                : PdfPageFormat.a4,
            margin: pw.EdgeInsets.zero,
            build: (_) =>
                pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
          ),
        );
      }
      File(outPath).writeAsBytesSync(await doc.save());
      return outPath;
    });

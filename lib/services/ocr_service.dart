import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/scan_doc.dart';
import 'storage.dart';

/// On-device text recognition (Latin script). No network used.
class OcrService {
  static Future<String> extractTextFromImages(List<String> paths) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final pages = <String>[];
    try {
      for (final path in paths) {
        final recognized = await recognizer.processImage(
          InputImage.fromFilePath(path),
        );
        final blocks = recognized.blocks
            .map((block) => block.lines.map((line) => line.text).join('\n'))
            .where((block) => block.trim().isNotEmpty);
        final text = blocks.join('\n\n').trim();
        if (text.isNotEmpty) pages.add(text);
      }
      return pages.join('\n\n');
    } finally {
      recognizer.close();
    }
  }

  static Future<void> run(ScanDoc d) async {
    try {
      d.ocrText = await extractTextFromImages(
        List<String>.from(
          d.pages,
        ).map((page) => Storage.pagePath(d, page)).toList(),
      );
      await Storage.save();
    } catch (_) {
      // OCR is best-effort; the scan itself is unaffected.
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// Wraps the on-device scanner: edge detection, perspective correction,
/// auto-capture, filters, rotate, crop, and multi-page (batch) capture.
class ScannerService {
  static Future<List<String>> scan(BuildContext context,
      {int pageLimit = 50}) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: {DocumentFormat.jpeg},
        mode: ScannerMode.full,
        pageLimit: pageLimit,
        isGalleryImport: true,
      ),
    );
    try {
      final result = await scanner.scanDocument();
      return (result.images ?? const <String>[])
          .map((e) => e.replaceFirst('file://', ''))
          .toList();
    } on PlatformException catch (error) {
      if (error.message?.toLowerCase().contains('cancelled') ?? false) {
        return [];
      }
      if (context.mounted) {
        final details = error.message ?? error.code;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'The scanner could not start. Check that Google Play services is up to date. Details: $details',
          ),
          duration: const Duration(seconds: 8),
        ));
      }
      return [];
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('The scanner could not start: $error'),
          duration: const Duration(seconds: 8),
        ));
      }
      return [];
    } finally {
      scanner.close();
    }
  }
}

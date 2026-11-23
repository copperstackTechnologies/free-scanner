import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';

const _releaseFeedUrl =
    'https://github.com/copperstackTechnologies/free-scanner/releases/latest/download/latest.json';
const _updatesChannel = MethodChannel(
  'com.freescanner.free_scanner/app_updates',
);

class NoPublishedReleaseException implements Exception {
  const NoPublishedReleaseException();
}

class AppUpdate {
  const AppUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.apkUrl,
    required this.sha256,
  });

  final String currentVersion;
  final String latestVersion;
  final String apkUrl;
  final String sha256;

  bool get available => _compareVersions(latestVersion, currentVersion) > 0;
}

class AppUpdateService {
  Future<String> currentVersion() async =>
      await _updatesChannel.invokeMethod<String>('getAppVersion') ?? '0.0.0';

  Future<AppUpdate> check() async {
    final currentVersion = await this.currentVersion();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(_releaseFeedUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'Free-Scanner-Android');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == HttpStatus.notFound) {
        await response.drain<void>();
        throw const NoPublishedReleaseException();
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Release check returned HTTP ${response.statusCode}.',
        );
      }
      final metadata =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      final version = metadata['version'] as String?;
      final apkUrl = metadata['apkUrl'] as String?;
      final digest = (metadata['sha256'] as String? ?? '').toLowerCase();
      final uri = apkUrl == null ? null : Uri.tryParse(apkUrl);
      if (version == null ||
          apkUrl == null ||
          !_isVersion(version) ||
          uri?.scheme != 'https' ||
          uri?.host != 'github.com' ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('The release metadata is invalid.');
      }
      return AppUpdate(
        currentVersion: currentVersion,
        latestVersion: version,
        apkUrl: apkUrl,
        sha256: digest,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<String> downloadUpdate(AppUpdate update) async {
    if (!update.available) {
      throw StateError('There is no newer version to install.');
    }
    await _updatesChannel.invokeMethod<void>('downloadUpdate', {
      'url': update.apkUrl,
    });
    return 'The APK download started. Open the downloaded file to install the update.';
  }
}

bool _isVersion(String value) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value);

int _compareVersions(String a, String b) {
  final left = a.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final right = b.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final comparison = (left[i]).compareTo(right[i]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

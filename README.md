# Free Scanner

Free Scanner scans paper documents into multi-page PDFs and keeps scanned files on the device. It also previews and manages supported documents stored in shared phone storage.

## Run locally

1. Install Flutter and the Android SDK.
2. From the project directory, run `flutter pub get`.
3. Connect an Android device or start an emulator, then run `flutter run`.

## In-app updates

Settings checks the public GitHub Releases feed for a newer version. When one is available, Free Scanner downloads the APK, verifies its SHA-256 checksum, and opens Android's package installer. Android requires the user to approve installation.

Only published GitHub releases are offered to the app. To publish an update:

1. Update `version` in `pubspec.yaml` to a higher `MAJOR.MINOR.PATCH+BUILD` value.
2. Commit the changes and push them to `main`.
3. Run `./publish-release.ps1` in PowerShell. It builds the release APK, computes its SHA-256 checksum, creates the GitHub release tagged `vMAJOR.MINOR.PATCH`, and uploads the APK and `latest.json`.

The script uses the local Android debug signing key because the app currently uses that key for its release build. Keep that same key available on the publishing computer so Android accepts updates over existing installs. The feed metadata has this structure:

   ```json
   {
     "version": "1.0.1",
     "apkUrl": "https://github.com/copperstackTechnologies/free-scanner/releases/download/v1.0.1/Free-Scanner-1.0.1.apk",
     "sha256": "64-character-lowercase-SHA256-digest"
   }
   ```

The feed is `https://github.com/copperstackTechnologies/free-scanner/releases/latest/download/latest.json`. Source-code pushes alone do not publish an installable app update; run the release script after pushing the updated source.

## Signing

Android only installs an update over an existing app when both APKs use the same signing certificate. The current Android release configuration uses the local Android debug signing key for development. Keep that key backed up and private, or configure a dedicated release key and keep it permanently. Never commit signing keys, passwords, or `android/local.properties`.

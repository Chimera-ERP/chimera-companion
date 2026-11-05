# Chimera Companion

Source available under [PolyForm Shield 1.0.0](LICENSE). This applies to the
project's own code; third-party components retain their terms in [NOTICE](NOTICE).

## Android releases

[GitHub Releases](https://github.com/Chimera-ERP/chimera-companion/releases/latest)
is the public update source. Companion checks it before and after enrollment;
no GitHub account, token or ERP update server is required. A new stable
`versionName+versionCode` in `pubspec.yaml` on `main` triggers the pinned Flutter
and Java17 workflow, regression checks, a signed APK build, package/certificate
verification, build attestation and publication. Commits without a new version
run checks without replacing an existing release.

The signing certificate stays compatible with existing installations. Four
`COMPANION_KEYSTORE_*`/`COMPANION_KEY_*` encrypted repository secrets supply the
existing key in CI. Never generate a new key for an update, change the Android
application ID, or publish an APK whose certificate does not match
`7b6ea16440c3928bc2402d9393de778c9a76a47c37e637ce898fcb8036809933`.
The key is removed from the runner after the job and never uploaded as an artifact.

To verify an APK's GitHub provenance:

```sh
gh attestation verify companion-0.1.44.apk --repo Chimera-ERP/chimera-companion
```

Release assets include the APK, `companion-update.json`, `SHA256SUMS` and its
Sigstore verification bundle. The manifest points to a version-specific asset;
Companion bounds redirects to GitHub's release CDN, verifies bytes and preserves
the existing native package/version/signing checks before Android installation.
A downloaded update never installs without confirmation. An interrupted release
stays a draft; investigate the failed run before resuming publication.

Existing pre-GitHub clients discover the transition release through their ERP's
existing `/api/companion-updates/manifest` endpoint. That feed is retained as a
compatibility bridge; new clients use GitHub directly.


Separate Flutter hardware application for Chimera ERP and POS.

Unified local API for Tremol RO, Datecs MX/legacy ROU and Viva Local Terminal.
Includes PIN enrollment, a setup wizard, responsive status dashboard, command
journal, non-fiscal/X/Z actions (Z requires confirmation), and heartbeat to Chimera
for POS visibility. Android keeps the local API running with a foreground service.
After a successful configured start, Android resumes it after boot/unlock and APK
updates (0.1.30+32). The customer display restores its cached publication offline;
the main activity does not need to open and no fiscal/payment command is replayed.

Fiscal/payment APIs use minor-unit amounts and durable, payload-bound command IDs.
Unknown outcomes are never blindly resent. Production checkout orchestration,
Datecs fiscal hardware qualification and iOS lifecycle remain separate acceptance
gates. See [API contract](docs/api.md) and [vendor notes](docs/vendor-provenance.md).

Target: Android now, iOS later. ECRs use Ethernet; Viva Terminal runs on the same
Android device (`127.0.0.1:9564`) or a configured peer on the LAN. The current catalog
diagnostic catalog client uses Tremol Direct API middleware; the separate fiscal
adapter uses the Romanian Ethernet protocol.

Run `flutter analyze` and `flutter test` to verify; use `flutter devices` then
`flutter run -d <android-device-id>` to open the diagnostic app on Android.

See [implementation checklist](docs/implementation-checklist.md) for architecture,
remaining tasks, platform requirements and hardware acceptance gates.

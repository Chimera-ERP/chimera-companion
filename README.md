# Chimera Companion

Source available under [PolyForm Shield 1.0.0](LICENSE). This applies to the
project's own code; third-party components retain their terms in [NOTICE](NOTICE).

Cloud PIN enrollment uses `https://auth.chimeraerp.ro`. Auth returns the tenant's
`erp_url` and its own `auth_url`; Companion keeps business requests on the ERP and
renews device credentials through Auth. Existing pairings without `auth_url`
retain their ERP proxy. Enterprise/self-hosted addresses remain explicit.

## Android package migration

The Android application ID and Kotlin namespace are `ro.chimeraerp.companion`.
The former `ro.tabusociety.chimera_companion` identifies a different Android app:
installing the new APK cannot update it or read its private enrollment, TLS keys,
settings or command journal. Stop the legacy bridge, reconcile pending/unknown
hardware outcomes, then install and enroll the new app through the existing setup.
Keep the old installation until that transition has been checked; never operate
both bridges against the same equipment. No automatic export of private keys or
journal deletion is performed. iOS/macOS/Windows identities are unchanged.

The release validator and updater accept only the new package. Previously
installed clients reject it; this is an explicit package migration, not an OTA
upgrade. The source change does not bump a version or publish a migration release.
ERP publication separates the canonical package under
`/api/companion-updates/ro.chimeraerp.companion/`; the legacy `/manifest` remains
isolated. The human `/latest.apk` link prefers the canonical package after it has
been published. Existing manifests and package/version/signature guards are not
relaxed to make an incompatible update appear installable.

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
existing key in CI. Never generate a new key for an update or publish an APK whose certificate does not match
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

### Configure a fiscal register on Android

On a new iMin, **Configurează casa** on the PIN screen opens the local setup and saves the chosen register for enrollment. On an enrolled device open **Casa de marcat → Configurează casa**, select the register model and choose **USB**, **Bluetooth**, or **LAN**. For USB, plug the register into the Android host, select it from the list and grant Android access. The standard FP21 USB setting is 115200 baud. For an Activa FP21 connected by USB, open **Bluetooth pe Activa FP21**. Companion reads the radio status. If disabled, tap **Activează Bluetooth pe casă**. After the register confirms activation, open **Setări Bluetooth Android**, select the factory serial and confirm pairing on both the Android terminal and the printer, then choose **Bluetooth** in the normal setup and select the paired device. For other models, enable their radio according to the manufacturer and pair them in Android. The register must offer Bluetooth Classic serial (SPP). Use **Verifică ECR** to read the device, then **Salvează conexiunea**. An identified register can report a blocked fiscal state. Resolve the condition shown by the register before attempting a sale.

Tremol M20, Activa FP21 and Datecs DP-25 MX share the normal checkout path over these connections. For older Datecs DP-25 registers with the Romanian SDK protocol, explicitly select the ROU profile. USB and Bluetooth use MX by default for the DP-25 MX. POS still contacts the owning Companion over its configured HTTPS connection. A configured register has a copyable equipment address for the ERP assignment. ERP migration 348 and its matching service are required for local USB/Bluetooth ownership and signed commands. Reopening an uncertain fiscal operation uses its original command ID and connection.

For the separate Android diagnostic with the Activa FP21, open **Casa de marcat → Diagnostic USB FP21**, select the serial device and tap **Citește starea**. Accept the Android USB permission prompt. The probe checks a Tremol status frame and reports the printer state, including a valid reply from a printer that is not ready. After a ready response, **Testează doar QR** sends one native QR request for https://chimeraerp.ro with no document open. For the long test receipt, enter the FP21 operator number and four-character password on the terminal and tap **Tipărește bonul de test** to print one non-fiscal sale simulation. The sample includes item amounts, a total, native EAN-13 and QR commands. The QR target is https://chimeraerp.ro. If the paper stops at “Cod de bare demonstrativ”, read the status again. For a matching interrupted sample, verify the printed line and use **Continuă bonul de test** to finish the same document. For an explicitly unsupported symbol Companion identifies the refused symbol and code, finishes the slip and reports any other symbol accepted by the printer. Scan the paper to check the result. For a selected USB printer, **Închide forțat bonul** checks for an open non-fiscal document, sends 2Fh once, and reads the state again. **Taie hârtia** sends the separate cutter command 29h on an explicit press. Both controls are available immediately after USB selection, including after the terminal assigns a new USB address. The USB trial is independent of checkout configuration. A fresh installation also offers the USB icon on the PIN screen, before enrollment. In device setup, select Activa FP21 to open the same probe.

Viva Terminal runs on the same
Android device (`127.0.0.1:9564`) or a configured peer on the LAN. The current catalog
diagnostic catalog client uses Tremol Direct API middleware; the separate fiscal
adapter uses the Romanian Ethernet protocol.

Run `flutter analyze` and `flutter test` to verify; use `flutter devices` then
`flutter run -d <android-device-id>` to open the diagnostic app on Android.

See [implementation checklist](docs/implementation-checklist.md) for architecture,
remaining tasks, platform requirements and hardware acceptance gates.

The setup form keeps its Flutter state across keyboard-driven layout changes.
PIN and Enterprise URL inputs retain focus and text when Android resizes the
wide wizard; `test/setup_keyboard_test.dart` reproduces opening and closing the
keyboard across the wide/compact height threshold. Physical iMin acceptance is
separate from the widget regression.

## Engineering skills

[Issue tracker](docs/agents/issue-tracker.md) · [Triage labels](docs/agents/triage-labels.md) · [Domain docs](docs/agents/domain.md)

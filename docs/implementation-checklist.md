# Chimera Companion — implementation status

## D200 firmware branding and Companion-only operation — 2026-10-25

Owner: Companion/hardware maintainers. Work deferred at the user's request for a
context switch. This is the single remaining-work checklist for this increment;
do not resume hardware commands, flashing or APK publishing until requested.

### Installed and verified

- [x] Boot shows only Chimera in the wide-key area, raised 7 pixels from the preceding placement.
- [x] Standby shows Chimera and PROD / KEY / PAD instead of factory button artwork.
- [x] User visually confirmed both screens on 2026-10-25: “Apar toate corect.” This confirms appearance, not key behavior or Companion compatibility.
- [x] Disable factory keyboard output independently of the proprietary console protocol. Preserve the factory profile schema; removing its action structure caused an unsuccessful temporary trial and was not flashed.
- [x] Disable automatic screen sleep. Persistent post-reboot check: 45 seconds without HID traffic, application running, brightness 255, offline mode entered and no sleep timer scheduled. Longer idle acceptance remains below.
- [x] Verify installed resource image and boot-logo checksums; unchanged protected partitions and original eight-partition backup verified. Remove only task-owned on-device update staging files.

### Remaining, in order

- [ ] Reconnect to the Mac and verify normal custom-HID discovery and a read-only response after a cold start. Last observation had no device on USB; this is not evidence of a firmware fault.
- [ ] Without Companion, physically press all keys/controls: no typing, application launch or factory shortcut. Test unplug/reconnect and longer idle; branded screen must remain visible.
- [ ] On Android Companion, verify discovery, USB permission, dynamic icons, diagnostic up/down keys and actual KDS actions. Verify disconnect/reconnect returns to the appropriate safe standby; prior pre-patch console trials do not qualify this firmware.
- [ ] Prevent accidental Ulanzi Studio control/firmware updates while preserving an explicit recovery path. First inspect the vendor update/control entry points. USB VID/PID changes alone are not authentication; do not use an arbitrary vendor ID or claim exclusivity. If identity changes are selected, update Companion recognition compatibly before changing the device.
- [ ] Make provisioning/recovery reproducible for the supported firmware: exact source hashes, model/partition guards, patch validation and rollback instructions. Keep original firmware dumps/private device data out of Git and retain the known-good recovery package.

Local handoff artifacts (not distributed with the repository):
`../device-backups/ulanzi-d200-2026-10-24.ONNDiL/` contains original backups;
`chimera-kds-standby/safe/` within it is the installed revision, with
`result.json`, `verification.json`, `patches.json`, `upgrade-log.txt` and
`persistent-idle-test.json`. The res-only recovery package is
`chimera-prod-key-pad/rollback-res-update.img`; the original boot JPEG is
`misc-extracted/boot_logo.JPG`. Use the guarded vendor updater, not a raw JPEG
write to MISC. Stock VID 2207 / PID 0019 remains unchanged. Vendor software
exclusion is **not implemented**; no Android end-to-end acceptance or other
D200 firmware/model support is claimed.

## Customer display and POS download — 2026-10-14

Single cross-repository checklist (ERP API/UI, POS, Companion):
- [x] 0.1.30+32 Android automatic boot/update recovery: one shared headless runtime and UI bridge, unchanged authentication and persistent local bundle. 27 Flutter tests plus native receiver/headless/managed-page trials pass. Installed on physical iMin; actual reboot started the foreground service and managed customer page without opening the Activity. User confirmed the logo before reconnecting ADB; logs, capture and certificate-verified local HTTPS health corroborate it. Same APK is in the development update feed; no financial operation performed.
- [x] Per-media circular countdown, stable across basket updates, repeating single slides and pausing only hidden receipt media. Adaptive ERP-only video-to-GIF conversion preserves selected duration and fits the media budget automatically. 26 editor/converter and 7 renderer tests pass; actual browser conversion reduced the 20-second stress GIF from 44 MiB to 3,398,679 bytes. Desktop and 390px UI inspected; circular countdown observed on physical iMin without an APK update.
- [x] 0.1.30 current renderer validated on physical iMin without Internet after the device reboot: recorded Wi-Fi off, no network routes and unreachable IP ping; populated banner layout/6.50 RON basket remains visible. Force-stopping/restarting Companion offline restores logo, animated GIF, both image slides and their countdowns from the same verified bundle. Wi-Fi/data and original Cloudflare DNS restored. No publication changes or financial commands; cached welcome after app restart is intentional until POS resends its live basket. Cold offline PWA DNS remains unqualified.
- [x] POS-specific naming, organization default, named publications and location groups; explicit location > group > default resolution with scoped authorization and migration of existing publications. Separate audience revision prevents lost updates; synchronization reads target, release and generation in one snapshot.
- [x] User-selectable background/accent, working logo and distinct cart layouts; shared location selector and reusable media picker/upload dialog.
- [x] Revised publishing workflow: 13 HTTP, 13 isolated PostgreSQL (including concurrent edits/sync), 19 editor/converter, 5 player/Chromium and 20 Flutter cache/display/stream tests pass. Typed UUID-array regressions also pass. Desktop/390px editor, media/group dialogs, invalid colors and unavailable-publication recovery inspected. Delegated UI/renderer/SQL review uses GPT 6.1 Sol, reasoning low.
- [x] 0.1.29+31 installed on physical iMin and in development update feed. Native unique-script instrumentation proves downloaded-page execution, colors, basket and rejection of wrong-root completion. Real iMin displays published logo, custom blue background/yellow accent, and switches receipt → split layout while the existing 59 RON basket is untouched. Managed-page readiness is confirmed without fallback. Trial branding is restored afterwards. No financial operation performed.
- [x] Fresh 0.1.29 Wi-Fi-off/app-restart trial: no network routes, IP ping unreachable, identical cached managed bundle ready without fallback. Physical captures show the logo, GIF, image rotation and countdown progression. Populated banner layout was also inspected online with a temporary 6.50 RON water; no sale was finalized. Cold offline POS DNS and physical display detach remain outside this increment.
- [x] ERP customer-display editor: location-scoped draft/publication, logo/layout/image playlist, browser-only optional video → GIF conversion. POS remains basket-only.
- [x] Companion atomic, content-verified offline presentation bundles; download failures keep last good version; no media over basket WebSocket.
- [x] Targeted API/SQL, editor/player and offline-cache regressions; desktop/mobile editor and physical iMin online/offline/restart inspected with no financial operations.
- [x] 0.1.28+30 installed on iMin and available in the development update feed. Real ERP browser converted a synthetic MP4 to GIF; logo, images and GIF reached the secondary display. Signed POS basket (two waters, 13 RON) rendered with published branding. Layout and playlist changed by subsequent ERP publications without rebuilding the APK.
- [x] Physical Wi-Fi-off test recorded Android `wifi_on=0`, force-stopped/restarted Companion, and captured two different playlist slides (including the converted GIF). Wi-Fi restored to `1`; captures recovered through the user-provided new ADB port. User's subsequent 59 RON basket was left untouched. Test-pattern GIF removed from the active playlist, retained in the media library.
- [x] 45 targeted checks: ERP HTTP 9, isolated SQL 4 (migration applied twice), editor/converter 8, POS renderer/settings/sync 4, Flutter cache/display/stream 20. Native Android bundle instrumentation additionally verifies local WebView readiness beyond timeout, resource confinement and rejection of legacy POS presentation overrides.
- [x] Final ERP/POS typechecks, scoped lint, Flutter analysis and Vite/PWA/APK builds passed. ERP UI full typecheck remains blocked by the pre-existing unrelated `winmentor.test.tsx:58` error; its Vite build and selected tests pass. Details and source fingerprints are in ignored quality receipts. Cold offline PWA DNS/TLS, physical display detach, native video and production distribution/legal acceptance remain outside this increment.
- [x] Customer web display: persistent authenticated display-only WebSocket, immediate latest-snapshot updates and expiry/reconnect tests; existing signed HTTP remains compatible.
- [x] Historical 0.1.27: isolated WebView with bundled responsive customer page, HTTPS custom-page option and PWA-controlled presentation settings. In 0.1.28 the ERP-owned published bundle takes precedence; POS settings now link to the ERP editor. No native JS bridge or credentials exposed.
- [x] 0.1.27+29: 71 targeted POS tests and 36 Flutter tests, typecheck/analyzer, APK/PWA builds. Physical iMin received 6.50/13.00 RON basket snapshots; observed acknowledgement round trips 180–210 ms, not a compositor latency guarantee. Unavailable HTTPS page fell back to packaged page while preserving basket; native UI reported fallback. This is not cold offline DNS qualification. No sale/payment/printing.
- [x] 0.1.26: fix Android presentation window/context mismatch; denied/granted permission covered by native instrumentation, sanitized error reasons by widget tests. Independent foreground/background welcome verified on physical iMin Android 13.
- [x] Adaptive shell and reusable bounded dialogs; customer-display detail stays beside navigation on wide windows.
- [x] Compact update flow with permission preflight and resume, advanced settings in dialogs, network settings/recheck and existing automatic ECR readback reused (no ECR operations during this trial).
- [x] Portrait, short landscape, widescreen, keyboard and text-scale checks; 74 targeted Flutter tests, clean analysis, native display instrumentation; release 0.1.26+28 installed on iMin and published to the development update feed.
- [x] ERP association selectors distinguish same-name devices by ID suffix; actual iMin POS authorized for its Companion without changing the other POS association.
- [x] Diagnose LAN DNS filtering: public DNS returned the correct local address while router DNS returned no answer. User-approved Android Private DNS set to Cloudflare; hostname resolves and the physical PWA Companion indicator is connected.
- [x] POS phone-only WebAuthn request policy shared by login, offline login and Companion; rejects local/unknown attachment results without weakening signed verification. Browser metadata is not cryptographic phone/proximity proof.
- [x] Background fiscal-policy checks never initiate passkey UI, including focus/timer retries; reuse valid session proof or remain unverified. 101 targeted POS tests, typecheck and production PWA build pass.
- [x] 0.1.25: optional ECR/Viva setup with independent persistence and guarded fiscal commands.
- [x] Setup access to customer-display permission; compact responsive wizard and stable navigation.
- [x] POS → Android launch link (open only, no credentials or hardware operations).
- [x] 64 targeted Flutter tests and 4 POS tests; clean analysis/typecheck, browser/emulator inspection and 0.1.25+27 development APK. No physical iMin acceptance claimed.
- [x] 0.1.24: shared update action on all pages, including setup; unpaired ERP address and retry.
- [x] 0.1.24: automatic independent welcome on secondary display during setup; background permission remains explicit.
- [x] 0.1.24: 21 targeted Flutter tests, clean analysis, foreground/background Android instrumentation and updated downloadable APK. Shared update dialog inspected in the Android setup screen; physical Swan 2 remains pending.
- [x] POS Settings download from the ERP release feed, with unavailable/retry state.
- [x] Android Presentation, secondary-display detection and explicit local activation.
- [x] Signed paired-POS basket snapshots, coalescing, disconnect/idle clearing.
- [x] Targeted tests, analysis, APK build and browser/emulator inspection.
- [x] Physical iMin Swan 2 signed basket trial: paired PWA sends one Aqua Carpatica at 6.50 RON, then quantity two at 13.00 RON; removing the test line restores the welcome screen. Main display remains the POS. Basket editing does not require a fresh operator passkey; background fiscal-policy polling could open intrusive prompts. No recurring prompt observed across multiple 30-second polling intervals after deploying the fix. Initial interactive ECR authentication still requires valid operator proof.
- [ ] Physical display detach/reconnect and cold offline DNS remain unverified.

0.1.26 evidence is recorded under ignored `.quality-receipts/`: final selected-test
and analysis logs, physical release UI/screenshots, emulator portrait/landscape
and native display probes. ERP and Companion quality checks pass with historical
metadata warnings. ERP UI typecheck is blocked by an unrelated existing untracked
`winmentor.test.tsx:58` unknown mock-instance type; that file was not changed.
No sale, receipt, payment, report or ECR setting was created during this trial.

Validation: POS settings inspected at desktop and 390px, including loading/error/retry/success;
the 0.1.23+25 APK was downloaded through the PWA and its SHA-256 matched the release feed.
Native Android instrumentation on an emulator with a secondary display covers background
Presentation, stale revisions, clear, expiry and disable. This is not physical iMin acceptance.
No fiscal or payment command was executed. The existing development APK signing configuration
is unchanged; production signing/distribution remains a separate release prerequisite.

Contract: [Customer display API](api.md#customer-display-012325).

## Accepted UI/API/offline plan — 2026-10-02

- [x] TLS-only listener; fail closed when certificate provisioning is absent.
- [x] POS HTTPS validation, DNS hostname support and existing HTTP association rejection.
- [x] Transport-only probe tool and automated TLS rejection/authorization tests.
- [ ] Complete Chrome/PWA HTTPS + LAN + offline gate. Publicly trusted HTTPS passed on physical Android Chrome, directly and from POS; cold offline DNS and the new signed flow remain unqualified.
- [ ] Certificate issuance/import/renewal suitable for deployment.
- [x] Persistent asymmetric Chimera JWT keys and seven-day POS–Companion grants (targeted authority tests pass; HTTP route acceptance pending).
- [ ] Android Keystore and non-exportable POS signing keys implemented; physical mutual identification pending.
- [ ] Signed challenge/command/response transport implemented; rejection and clock tests pass, complete replay/restart qualification pending.
- [ ] Signed operator permissions, including offline ECR configuration.
- [ ] Automatic renewal, local revocation and ERP revocation propagation.
- [ ] Capability matrix and public API for configuration, reports, journal and payments.
- [ ] Durable recovery/date-time workflows and client-side confirmations.
- [ ] Forui neutral styling, compact four-row home, responsive detail and separate diagnostics implemented; widget tests pass, physical visual acceptance and complete wizard refactor pending.
- [ ] POS/ERP integration and physical Datecs/Tremol acceptance.

First gate evidence and provisioning limitations: [https-release-gate.md](https-release-gate.md).
The historical notes below do not describe completion of this new plan.

### Latest verification

- Public leaf certificate issued via Cloudflare DNS-01. No development CA installation required; no insecure HTTP fallback.
- Phone APK installed with Android Keystore identity and new home. Physical portrait screenshot verified: Copou, Datecs and Viva connected, local HTTPS server available. Chrome health fetch from POS loopback origin passed without trust overrides.
- Signed physical status probe stopped before dispatch because the currently opened POS origin has no saved enrollment. No authenticated offline acceptance claimed.
- 15 targeted Flutter tests, 7 backend authority/presence tests and 7 POS job tests pass; Flutter analyzer and both TypeScript checks pass.
- POS job tests mock the signed transport boundary; they do not qualify the cryptographic network protocol.
- Production certificate renewal, LAN DNS without Internet, revocation UI, expanded operations, recovery/time workflows and full hardware acceptance remain open.

## Current increment — 2026-10-02

The older foundation notes below are historical. Current contract and limitations
are in [api.md](api.md).

- [x] PIN pairing and scoped online capability verification (historical HTTP transport; now TLS-only).
- [x] Shared fiscal facade for Tremol / Datecs; status, non-fiscal, fiscal, X, Z.
- [x] Explicit Z confirmation in Companion, POS and dispatch validation.
- [x] Heartbeat persisted by Chimera, 15-second interval and 60-second expiry.
- [x] POS status indicator and report actions; Android foreground service.
- [x] Dashboard, responsive status cards, journal detail and bottom debug.
- [x] 61 automated Flutter tests; analyzer clean; Android debug APK installed.
- [x] Both actual ECRs: read-only status and non-fiscal output through shared facade.
- [x] Actual phone: local API command deduplication and background heartbeat.
- [ ] Physical fiscal qualification of new Datecs MX implementation.
- [ ] Complete POS checkout and ERP operator command authorization/screens.
- [ ] iOS lifecycle and platform acceptance.

## Historical foundation notes (before the current increment)

## Confirmed deployment requirements

- Android is the current development/deployment target; iOS is a later target.
- All fiscal devices connect over Ethernet. No USB/serial adapter is required.
- Companion, ECR and the Android device running Viva Terminal share a LAN.
- Viva is a separate LAN peer, not necessarily the device running Companion.
- ERP and POS must both initiate commands through the same authorized API.
- No Windows/macOS machine or external FP server should be a deployment dependency.
  The generated desktop targets are only initial scaffolding, not a requirement.

The current Tremol catalog client talks to Direct API middleware, not directly
to an ECR Ethernet port. Keep it as a diagnostic/reference tool; it is not the
production Ethernet adapter. Before choosing the native Android SDK bridge or
portable Dart socket driver, confirm Romanian model, firmware and protocol SDK.
Keep native SDK calls behind the fiscal adapter so iOS can use a different
implementation without changing ERP/POS commands.

Companion must report offline/unavailable honestly. Reliable background execution
on Android needs lifecycle handling; iOS background suspension requires a separate
availability strategy, not an assumption of an always-running worker.

## Implemented foundation and adapters (hardware validation pending)

- [x] Separate Flutter project; generated Windows, Android and macOS targets.
- [x] Separate fiscal and payment adapter contracts; no vendor dependencies in UI contracts.
- [x] Integer minor-unit money and receipt total validation.
- [x] Tremol Direct API command-catalog discovery (`GET /getcmds`).
- [x] Diagnostic screen displays complete command definitions, not just names.
- [x] Unit and widget tests. No financial/device commands issued during tests.
- [x] Tremol RO TCP framing, ACK/checksum validation, status and receipt sequence.
- [x] Datecs DP-25 Romania Android SDK bridge for status and receipt operations.
- [x] Existing gateway's non-fiscal profile ported with framing parity fixtures.
- [x] Viva Local sale/session/reconciliation adapter; certificate-pinned HTTPS.
- [x] Local LAN configuration UI with secure storage.
- [x] Durable pre-dispatch journal, payload-bound idempotency and serial execution.
- [x] Unknown hardware outcomes remain unknown on duplicate calls/restart.
- [x] 32 tests pass; Flutter analyzer has no issues (2026-09-26).
- [x] Android debug APK builds successfully with isolated JDK 17; global JDK unchanged.

See `vendor-provenance.md` for exact sources and limitations. No real ECR or
terminal has been contacted. The gateway ASCII profile is intentionally not
exposed as a fiscal adapter for Romanian receipts.

Catalog discovery verifies the local service only, not hardware readiness.
The remote reference server must never be used for printing or payments.
Android HTTP access remains blocked by default: add a narrowly scoped network
security configuration after the installation endpoint is decided.

## Architecture to implement next (not available yet)

ERP and POS -> authenticated Chimera command API -> Companion outbound worker
-> fiscal adapter (Tremol / later Datecs) OR payment adapter (Viva Local Terminal).

Both clients use the same API, authorization, idempotency and audit trail.
No generic unauthenticated LAN command server and no browser access to raw ECR.
Device addresses are locally configured, never supplied inside remote commands.

- [x] Confirm platform and topology: Android now, iOS later, Ethernet ECR and LAN Viva.
- [ ] Confirm real Tremol models, Romanian firmware / SDK and Viva Terminal settings.
- [ ] Pair Companion to organization and location with revocable device identity.
- [ ] SQL command queue, permissions, expiring claims and command/result API.
- [x] Durable local journal written before sending; serial execution via runtime.
- [x] Bind idempotency key to immutable request hash. Reject changed payloads.
- [x] Sent/in-flight commands recovered as `unknown` after restart, not resent.
- [ ] Result reconciliation independent of issuing the original command.
- [x] Tremol Romanian adapter: status, lines, VAT groups, payment and receipt identity.
- [ ] Tremol LAN password authentication and SDK/model firmware qualification.
- [x] Viva Local Terminal adapter with terminal-confirmed outcome and reconciliation.
      Never store card data or treat `PROCESSING` as approved.
- [x] TLS trust for the approved local Viva terminal; no blanket bypass.
- [ ] ERP device setup + command history; POS checkout through same command API.
- [ ] Real terminal demo tests and fiscal-device acceptance tests before production.
- [x] Datecs Romania SDK adapter + existing gateway non-fiscal profile.

The existing ERP fiscal `prepare` endpoint only supplies header totals. Do not
connect it to a real printer without complete fiscal lines/VAT/payment mapping.
The current Flutter project has hardware adapters, not a complete checkout engine.

## References

- Tremol supplied Direct API: http://router.tremol.bg:11444/ . The static page
  documents `getcmds` and connection `Settings(...)`; only catalog was read.
- Viva overview: https://developer.viva.com/apis-for-point-of-sale/card-terminals-devices/peer-to-peer-communication/
- Viva local protocol: https://developer.viva.com/apis-for-point-of-sale/card-terminals-devices/peer-to-peer-communication/point-to-point-protocol-rest-api/

## Run

`flutter run -d <android-device-id>` from the project directory for Android development.
`flutter devices` lists connected targets. iOS has not been scaffolded/tested yet.
Android needs a compatible JDK; the development host's global Java 26 is outside
the generated Gradle supported range. Build validation used JDK 17 downloaded to
a temporary directory, supplied via `JAVA_HOME` and `PATH`, without global changes.

# Chimera Companion — implementation status

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

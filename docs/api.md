# Companion local API: v1 dispatch, v2 authorization

## KDS console (Android USB, physical qualification pending)

Home → **Consolă KDS** → **Caută consola** → select Ulanzi and approve Android USB access.
**Probă pictograme** (or physical key1 **Test KDS** while no KDS owns the console) enters
an isolated diagnostic menu. Key5 goes up, key10 goes down through three wrapping pages;
the other keys show randomized pictograms and change their own icon when pressed. The
phone displays the current page and key number. **Încheie proba** returns to idle.
Diagnostic mode cannot claim a KDS session, emit production actions or replace an active
KDS screen. In-flight screen uploads ignore additional navigation; disconnect clears test mode.
All key PNGs use opaque pure black `#000000`, including empty/disabled keys; only glyphs/text
change brightness. Connect a USB OTG adapter or powered hub if the phone cannot power the device.
Screen archives use content-addressed PNG names, not reusable per-slot filenames, so a firmware
image cache cannot substitute a previous blank/idle key for new pixels. Identical images share
one archive entry. Existing remote `companionDiagnostics` includes console mode, last key,
received/button report counts, completed uploads and ignored-input reason. It does not return
credentials, frame contents or grant console control. Upload acknowledgement is not visual proof.
Android 8+ is required for bounded USB request waits. Reconnect explicitly after unplug/restart.

KDS selects an enrolled HTTPS Companion from its own organization/location using the console
button on the bottom status bar. `WSS /v1/kds-console` accepts no query credentials. A 60-second
ERP `kds-console` ticket binds station/device public key, Companion public key and exact Origin.
A fresh signed challenge and station signature prove both endpoints; renewal rechecks ERP scope
and preserves the same key/actor. The connection cannot grant printing, reporting or fiscal rights.
Only one KDS owns the console. Version1 views contain a monotonic revision, title and at most
13 semantic `{id,label,icon,enabled}` keys. USB input emits `{type:press,revision,id,sequence}`.
No keyboard synthesis, browser USB permission, firmware replacement or raw business command occurs.

KDS uses its existing callbacks for selection, personnel, start/pause/resume, substep completion
and requesting ERP reporting. Unknown/disabled/stale actions, held keys and replayed sequences
are ignored. Buttons cannot submit measurement forms. Views expire after 8 seconds without updates;
disconnect clears control. ERP connectivity is required for this first console version.
macOS build and native transport remain deferred after the user chose Android testing without Xcode.

`ConsoleAdapter` separates semantic screens from vendor framing; `ConsoleTransport` separates
USB platform I/O. Ulanzi D200-family VID2207/PID0019 uses the vendor HID interface only,
1024-byte packets, PNG/ZIP screens and GET_BASE barriers. The archive dependency packages these
screens; no external executable or image download is used. Real firmware/phone compatibility
must be verified on hardware; successful unit tests or an APK build do not establish it.
The user reported the Android console working on build39 but only the idle key remaining on
build40. Build41 removes reusable asset paths and adds remote console inspection; the actual
cause/device result still requires confirming whether the phone enters test mode and a new trial.

## Cloud enrollment routing

The default PIN endpoint is `https://auth.chimeraerp.ro/auth/enroll-device`.
The authenticated enrollment response carries the tenant's canonical `erp_url`
and the deployment's optional `auth_url`. Both must be HTTPS origins without
credentials, paths, queries or fragments. Cloud enrollment requires an ERP origin;
it never stores the Auth service as the ERP. Device-token renewal uses `auth_url`.
Older pairings fall back to their existing ERP Auth proxy, and self-hosted servers
may keep both services on one origin. Signed proof, nonce/retry identity, issuer,
organization and location validation are unchanged.

## Scale integration (Acaia BLE, hardware qualification pending)

Setup starts with a persisted usage profile: POS (ECR, Viva, scale), KDS/PDS
(scale, production printer), or Custom (explicit device selection). ERP enrollment
and HTTPS remain mandatory in every profile; profile selection never changes
authorization or erases existing device settings. Hardware steps are optional.
Original step IDs remain compatible with saved progress and direct settings links.
Scale and printer use the shared three-stage peripheral wizard: transport,
device configuration, review. Scale supports Bluetooth only (LAN disabled);
printer supports LAN only (Bluetooth disabled). Scale review requires confirmed
device readiness. Printer review validates the existing PrinterConfig and saves
through existing secure storage; it does not print or claim physical validation.
Both devices are accessible directly from home, in the responsive detail pane.

`lib/hardware/scale.dart` defines the shared driver interface: connection state,
read/stream, and explicitly declared tare/zero support. Readings contain device
identity, decimal-string net quantity, g/kg unit, stability, overload and UTC
observation time; gross/tare are optional and never synthesized.
The Android Companion home → Cântar scans for Acaia devices, identifies
legacy/modern/Umbra GATT services and retains the selected device securely.
Reconnection is explicit after an unexpected disconnection; a paired client also
restores the saved connection after process restart. Other brands are not advertised.
The home row shows device name, connection state and fresh weight. Configuration
uses the same detail pane as the other devices (split pane on wide screens,
back navigation on narrow screens); the overflow menu no longer duplicates it.

POS uses the existing signed `status` operation with `{scope:"scale"}`. This avoids
ECR polling and works without ECR configuration. The response has `scale.version:1`,
connection state, name, message, stabilitySource and a nullable reading. All existing
pair/organization/location/key/challenge/HTTPS checks apply; no anonymous route.
No tare/zero command is exposed through this read-only operation.

Acaia status must confirm grams before accepting any weight. Modern/Lunar/Pyxis
and Umbra profiles automatically write the gram unit once per connection when
status reports ounces, then request status readback. Already-gram units are not
rewritten. Unknown units are not guessed. Confirmation times out after eight
seconds; refused/missing confirmation leaves readings unavailable with an error
and explicit reconnect action. Legacy1820 has no verified unit-write command and
reports this limitation instead of sending a speculative setting. Umbra reads
unit at status offset4 (0/1); modern/legacy offset2 masked with0x7f (2/5).
No tare, sleep, beep, mode or calibration is changed by connection.
The reference protocol does not supply a verified stability
flag: `stabilitySource:"unavailable"`, `stable:false`. POS explicitly tells the
operator to wait for a stable value and confirm; it never automatically adds a
sale. Known hardware instability is rejected. Non-positive, stale (>2s), future,
overloaded and unsupported-unit readings are rejected. Only explicit `g`/`kg`
stock units are converted; lower product precision is not silently rounded.
Manual entry remains available offline or when Bluetooth is unavailable.

## Single POS operator session (0.1.31+33)

New POS clients never authenticate an operator again in Companion. Signed
`/v2/challenge` replies advertise `posOperatorSession: 1`. Commands carry
`posOperatorSession`, whose exact JSON SHA-256 is bound as `posSessionHash` in
the POS-signed command message. Supported evidence:

- `type: passkey`: the already verified POS login assertion and its original
  base64url challenge. The challenge is a v1 `pos_operator_session` JSON object
  binding org/location/POS/operator/origin/POS public key, iat/exp and a 32-byte
  nonce. Auth generates it online; POS generates it for an offline login.
- `type: authority`: an ERP-signed `pos_operator_login` certificate, bound to the
  same actor/key/pair and original authentication time. Used by older POS sessions
  and initial registration; never minted merely from a device token.

Both proofs are bounded to seven days and the earliest current grant/credential
expiry. They do not grant permissions: current pair/operator grants, assignment,
revocation, command nonce/signature/hash, origin and clock checks remain mandatory.
Reusable login evidence deliberately does not advance a WebAuthn counter on each
command; original POS login verification does. Commands still reject nonce replay.
No Companion operator-session token is created for this flow, and restart needs
no reauthentication. The old operatorAssertion/operatorSession protocol remains
for older clients during upgrade, never as a new-client fallback. Old sessions
without provable login evidence must explicitly sign in to POS once after upgrade.

## Transport and authorization

`GET https://<provisioned-companion-hostname>:8765/health` exposes service identity only.
The listener requires an installation-specific certificate/key. Missing provisioning
blocks server startup; there is no HTTP fallback. The POS browser must trust the
certificate normally. See [https-release-gate.md](https-release-gate.md) for the
pending physical browser test and certificate deployment requirements.
Production dispatch uses the signing authorization flow, not legacy tickets.
`POST /v2/challenge` accepts JSON `{ "lease": "<ERP-signed pairing grant>" }`
and the browser `Origin`. It returns `message` (exact signed JSON) and `signature`.
The challenge is valid for 60 seconds; authorization verifies organization,
location, Companion, POS pairing and expiration. At most 64 live challenges are
retained. A restarted process requires a new challenge, not a new command ID.

`POST /v1/commands` accepts `lease`, `message`, `signature`, `payloadJson`, and,
for writes, `operatorGrant` plus the required verified operator proof/session.
The signed `message` binds `challenge`, `companion`, `method: "POST"`, `origin`,
`commandId`, `operation` and `payloadHash` (SHA-256 of the exact UTF-8
`payloadJson`). Preserve these exact JSON strings; reserialization changes proof.
`status`/`history` are read-only pairing operations; writes also require operator
rights and trusted passkey policy. An operator ID supplied in payload is not proof.

ERP-signed checkout policy and actor/POS fields override browser payload fields.
Signed results include `resultJson` and `signature`, bound to original command,
operation, actor/POS and payload hash. Preserve their original bytes for ERP
reconciliation. Do not persist transient operator tokens with business evidence.

All requests use HTTPS. Production hostname validation rejects unexpected hosts
with 421; query parameters are rejected. Dispatch requires `Origin` and JSON,
has a 32768-byte request limit and a five-second request-body read timeout.
`OPTIONS` supports the declared POST paths, including printing below. CORS headers do not themselves authorize
execution. Invalid/expired authorization is 401/403, conflicting command identity
is 409, unavailable/unconfirmed execution is 503. None is bank/fiscal success.

The legacy `{ticket,payloadJson}` branch remains only when offline signing
security is not configured. Once it is configured, legacy tickets are rejected.
Offline operation depends on valid bounded grants, trust, certificate, DNS and
local reachability; seven days is a maximum, not indefinite offline support.

## Operations

### Setup and launch (0.1.25+27)

ERP association and local HTTPS remain required for the authenticated POS API.
ECR and Viva are independently optional. **Mai târziu** never persists an
unfinished ECR draft or deletes a saved ECR; Viva settings are saved independently.
An absent ECR reports `unconfigured`, with no fiscal capabilities; fiscal commands
are rejected. Display-only and Viva-only installations can complete setup.
The customer-display permission screen is accessible from every wizard step's
header, before configuring any ECR. The final step also links to it.

`chimera-companion://open` launches/resumes the installed Android app. POS uses
the package-targeted Chrome intent form on an explicit user click. This is not
authentication: no token, PIN, destination, hardware command or arbitrary Flutter
route is accepted through the URI. It opens the existing screen/wizard, preserving
progress. Missing-app users can use the separate APK download action in Settings.
Launch and APK installation target this Android, not another Companion on the LAN.

### Customer display (0.1.23+25)

Signed `status` advertises `customerDisplayVersion: 1` and `customerDisplay` with
`state`, `enabled` and detected Android presentation displays. `customerDisplay`
uses the same HTTPS/challenge/signature/pairing authorization as other commands.
Like status, this display-only operation requires the paired POS device, not an
operator assertion, so logout can clear it. It grants no fiscal/payment access.
The verified POS ID is injected by the transport; a browser cannot override it.

Payload: `{revision, currency, totalMinor, lines:[{name, quantity, totalMinor}]}`.
Amounts are integer minor units from the existing POS quote; the display performs
no VAT, promotion or settlement calculations. Maximum 100 lines, names 160 characters,
positive finite quantities. No customer names, tokens or payment details are sent.
Revision increases per POS; stale revisions are ignored during the running process.
These replaceable snapshots are not financial journal entries and are never queued
offline. POS coalesces updates and sends a fresh snapshot every 10 seconds. The
display clears after 30 seconds without an update, on disable or screen disconnect.

Since 0.1.24+26, a detected secondary display opens its own welcome screen from
Activity startup, including the enrollment wizard. It is enabled by default unless
explicitly disabled in **Ecran client**. It does not mirror setup, diagnostics,
operator information or update dialogs from the main display. Foreground welcome
does not require enrollment or overlay permission. Grant Android “display over
other apps” to retain it when Companion is backgrounded by POS.
The presentation lives independently of the main Activity, so POS Chrome/PWA can
remain foreground on the main display. Only Android secondary presentation screens
are selected, never the main display. Other platforms report unsupported. This uses
Android Presentation per the iMin customer-display guidance, without a vendor SDK.
iMin Swan 2 (I24D02, Android 13) has been checked with an independent welcome
screen while its POS PWA is foreground. On 2026-10-14, the ERP-authorized physical
PWA also delivered signed basket snapshots (one item, quantity increased from one
to two, matching totals 6.50/13.00 RON; removal restored the welcome screen). No sale, fiscal receipt or payment was
created. This does not qualify offline cold-start DNS or physical display replug.

#### Web customer display and live channel (0.1.27+29)

`status` additionally advertises `customerDisplayStreamVersion: 1`. Compatible
POS clients connect to `wss://<companion>:8765/v2/customer-display` with their HTTPS
Origin. First frame: `{type:"hello",lease}`; response: `{type:"ready",challenge}`.
The next frame has `type:"snapshot"` and the **same signed command envelope** as
HTTP, restricted to `operation:"customerDisplay"`. Each acknowledgement contains
`{type:"ack",result,challenge}`: a verified, request-bound result and a new signed
one-use challenge for the next frame. Pairing, revocation, clock, expiry, key,
origin and payload checks still run for every frame. There is no bearer-only
stream session and no operator/fiscal/payment access on this channel. Limits:
two streams, 32 KiB messages, 20 frames/second, five seconds for initial proof,
30 seconds idle. Existing signed HTTPS remains supported for older APKs.

POS sends changes immediately (no 150 ms debounce), keeps only the latest pending
snapshot and uses the ten-second heartbeat only for idle liveness/recovery.
Closing/reconnecting a stream never persists/replays old carts. The PWA Companion
page shows acknowledgement round-trip time, **not** a display-compositor SLA.

Optional snapshot `presentation` fields: `url` (HTTPS, no userinfo/fragment),
`title` (60 chars), `message` (160 chars), `accent` (`#rrggbb`), `theme` (`dark/light`).
Only the paired POS can supply them. These are legacy compatibility fields:
current POS sends basket-only updates; an installed ERP bundle takes precedence.

Android renders an isolated WebView, not a mirror of the POS. It exposes no native
JavaScript interface, device credentials, customer identity or filesystem access;
mixed HTTP content, external app intents and cross-origin top-level navigation are
blocked. TLS errors are never ignored. A custom page that errors or takes over
eight seconds falls back to the packaged page without losing the current basket.
`customerDisplay.pageState` reports `loading`, `ready` or `fallback`. App switching
does not rebuild an application-owned display. Physical permission rules remain.

The canonical page is `chimera/public/customer-display/index.html`. Update the
packaged and legacy POS copies with
`node tool/sync_customer_page.mjs` and verify using `--check`; standalone Companion
builds consume the committed asset. `GET /customer-display` serves this static
template only, never current basket data. Custom pages read the latest public
snapshot from `window.chimeraCustomerDisplay` and subscribe as follows:

```js
window.addEventListener('chimera:customer-display', ({detail}) => render(detail));
if (window.chimeraCustomerDisplay) render(window.chimeraCustomerDisplay);
```

The event contains only `lines`, `totalMinor`, `currency`, `revision` and display
presentation. Render text as text, not HTML. Quoted amounts remain authoritative;
do not recalculate VAT/promotions. An empty `lines` list clears the previous cart.
Use a page you control: a custom page can see public basket contents, although it
cannot issue hardware commands. Remote page availability still depends on network;
the packaged page works without external hosting.

#### ERP editor and offline media bundles (0.1.28+30)

Configure `/settings/devices/customer-displays` in ERP: location-scoped draft,
logo, three cart layouts and ordered image/GIF playlist. Save does not publish.
Publishing creates an immutable revision; conflicts keep the user's draft.
Video conversion is an optional ERP browser worker, never part of POS or Companion.
GIFs are silent; native video is reserved for a future manifest capability.

Companion polls the scoped `/api/devices/companion/customer-display/sync` after
successful ERP heartbeats, independently of basket updates. Manifest schema 1:
`orgId, locationId, revision, key, config, player:{sha256,size}, assets:[{sha256,mime,size}]`.
`config` has `version:1, title, message, theme, accent, layout, logoAsset, playlist`;
each slide has `id,kind:"image",asset,durationSeconds,fit,caption`.
All renderer/media downloads use authenticated HTTPS and derive device scope on
the server. Validate hashes, lengths, organization/location and limits before
renaming the cache and its active pointer. Interrupted downloads retain the last
complete bundle. Keep current + previous cache directories; no PWA-provided paths.

The native isolated WebView serves the private bundle at its synthetic HTTPS
origin and refuses other resources. No network is needed to render it, rotate its
playlist or restore after restart. When a basket arrives, display it using the
selected layout. Visible split/banner media keeps rotating across basket updates;
receipt-only carts pause hidden media, then resume its remaining time. Each slide
shows a circular remaining-time indicator; a single slide repeats its period.
The signed basket protocol is unchanged.
Receipt `{bundleKey,revision,errorCode}` distinguishes installed revision from
publication. Each later logo/layout/media change needs **no APK rebuild**.

Limits: ten slides, 5 MiB per raster, 30 MiB per publication; bounded per-location
server library. No arbitrary uploaded HTML/JS/SVG or native video is accepted.
The public static player endpoint contains no current basket or tenant assets.

#### Adaptive settings and display recovery (0.1.26+28)

On Android 12+, `Presentation` supplies its own window context. We retain its
matching window type; changing `window.setType` after construction can cause
`InvalidDisplayException`, including after granting overlay permission. The
permission still gates background operation; no bypass or vendor API is used.
The additive `errorCode` status field contains a sanitized reason when `state` is
`error`: `display_rejected`, `window_rejected`, `permission_denied` or
`display_unavailable`. No exception payload or credentials are exposed.

Customer-display detail remains in the home split pane at 840 logical pixels
and above. Narrow windows use an in-place detail with Back, preserving selection
across resize. Settings refresh after Android resumes. Display settings and
overlay permission each have an explicit Android-settings action; unavailable
OEM settings screens fall back to Android Settings. Recheck retries detection.

Wizard forms have bounded width, an informational step rail on sufficiently wide
and tall windows, and a fixed action footer. ECR/operator, Viva and manual HTTPS
settings use scrollable dialogs. Network setup exposes Wi-Fi settings and a real
address recheck. Existing adapter identification/readback remains the source of
ECR values; opening a form does not print, initiate payment or change the ECR.

Update dialogs check automatically on opening. APK-install permission is checked
before downloading, refreshed on resume and rechecked at install. Missing
permission provides Settings and Recheck actions. Shared dialogs bound the content
width, scroll the form and wrap actions on narrow windows; enrollment and TLS
configuration survive navigation. A missing release manifest is an error, not an
up-to-date result. Existing package/hash/signature checks remain mandatory.

Design references: [Android Presentation](https://developer.android.com/reference/android/app/Presentation),
[Flutter adaptive layout](https://docs.flutter.dev/ui/adaptive-responsive/general),
[Forui dialogs](https://forui.dev/docs/widgets/overlay/dialog), and
[Android Settings](https://developer.android.com/reference/android/provider/Settings).

The current development distribution builds the Android release APK locally and
publishes it through ERP `scripts/publish-companion-update.mjs`. The publisher
requires an increasing build number and atomically replaces the manifest after
writing the hash-addressed APK. New Companion releases are built and published by the GitHub workflow described
in [README](../README.md#android-releases). The public update authority is
`Chimera-ERP/chimera-companion`; the latest stable release includes a bounded
`companion-update.json` manifest with package, build/version, size, SHA256,
installed certificate fingerprint, source commit and immutable GitHub APK URL.
Only GitHub release URLs for that repository and HTTPS redirects to
`release-assets.githubusercontent.com` are accepted. APK size/hash and native
package, increasing version and installed signing identity remain enforced.

The initial update can be checked without enrollment. The update dialog no longer
asks for an ERP URL. Shared app bars expose the update action on every page;
updates cannot begin during a hardware operation and preserve the existing
configuration lock. Installation still requires explicit Android confirmation.

Old clients and POS download links retain the ERP manifest as a compatibility
bridge. Publishing the exact GitHub-built APK there must preserve its digest and
increasing build number; it must not rebuild or re-sign it locally.

| Operation | Payload | Result |
| --- | --- | --- |
| `status` | `{}` | versioned snapshot, component states, configured capabilities and enrollment identity |
| `history` | `{}` | latest 30 sanitized journal results |
| `nonFiscal` | `{ "lines": ["TEST NEFISCAL"] }` | printable ASCII, max 100 lines × 40 characters |
| `xReport` | `{}` | non-zeroing report |
| `zReport` | `{ "confirmCloseDay": true }` | fiscal day closure; requires explicit UI confirmation |
| `payment` | `{ "amountMinor": 500, "currency": "RON" }` | Viva-confirmed result/reference; no auto-fiscalization |
| `paymentTest` | `{ "amountMinor": 500, "currency": "RON" }` | existing fixed-value diagnostic; this initiates a real terminal session |
| `fiscalReceipt` | see below | receipt result/reference, not an ERP sale posting |
| `operatorLogin` | verified actor; optional `expectedOperatorId` | adapter-managed operator activation |
| `operatorLogout` | optional `expectedOperatorId` matching verified actor | adapter-managed operator closure/report, separate from daily Z |
| `drawerCountStart` / `drawerCountEnd` | `shiftId` | durable shared-drawer reservation/release |
| `cashDeposit` / `cashWithdraw` | `amountMinor`, `currency: "RON"`, `reason` | signed cash result; ERP confirmation is separate |
| `fiscalPolicy` | business policy intent | trusted checkout policy is supplied from signed authorization, not arbitrary browser configuration |

```json
{
  "currency": "RON",
  "totalMinor": 2000,
  "paymentMethod": "cash",
  "lines": [{
    "name": "Cafea",
    "quantity": "1",
    "unitPriceMinor": 2000,
    "grossTotalMinor": 2000,
    "vatGroup": "A"
  }]
}
```

This older group-based example is not a template for composing vendor commands.
POS checkout sends recorded `vatRate`; the adapter maps it to configured ECR
groups and rejects unsupported mapping. Explicit VAT groups refer to the actual
configured ECR groups, not assumed percentages.
For `card`, supply `paymentCommandId` from a successful `payment` journal entry
for the exact total and currency. A caller-supplied payment reference is not proof.
The same payment cannot be attached to a second fiscal command ID.

Write replies contain `commandId`, `outcome` (`succeeded`, `rejected`, `unknown`),
`reference` when available, and a sanitized message. Reuse the original command ID
and exact payload to retrieve a result after a timeout. Never create a new ID to
retry an unknown fiscal/financial command. The journal persists intent before
dispatch; restart leaves incomplete writes unknown. No automatic cancellation,
refund, reprinting or Z reissue is attempted.

### Read-only command recovery (0.1.16+18)

Authenticated `status` advertises `commandRecoveryVersion: 1`. A client must
check this before sending the recovery flag: older builds may ignore it.
For X/Z, non-fiscal print, cash, receipt, payment and payment-test recovery, keep
the original command ID and business payload and add `recoveryOnly: true`.
Authorization and original operation permissions remain mandatory. The flag
does not change the journal's business fingerprint; changed equipment, amounts
or business payload still conflict.

The response has `journalFound: true` only for an exact durable journal match.
An absent report/cash/print/payment result is `unknown` and never dispatches,
creates an in-flight journal entry or calls the bank terminal. Receipt absence
also stays unknown: a missing journal cannot prove that no receipt was printed.
A preflight refusal without
`journalFound` is not proof that the original operation failed; clients must keep
the original uncertainty. Payment recovery retains bank reference/evidence or
the original terminal-rejection attestation where applicable.

The latest-30 `history` list is for display, not complete recovery evidence.
POS X/Z, payment-test and non-fiscal actions serialize through browser Web Locks;
an uncertain action uses this read-only recovery flow rather than redispatch.
Build 0.1.17+19 additionally keeps missing fiscal-receipt results unknown, rather
than interpreting journal absence as a rejection. No fiscal command is dispatched.

### Peripheral reconciliation

Status advertises `offlineShiftCloseVersion: 1`. An authorized `operatorLogout`
may include `shiftClose` (shift ID, original revision, closing time, answers and
denominations). It is part of the immutable logout journal fingerprint and the
signed response payload hash, so changing a count cannot reuse an earlier report.
POS stores that response in its existing outbox; synchronization to ERP has no
hardware effects. Unknown logout retains the original ID and never repeats a reset.

Unknown payment results can be reconciled under the durable executor's same lock
and exact request fingerprint. Viva queries the original session UUID using GET;
it does not POST another sale. Session/type, amount and merchant reference must
match. A missing/unavailable session remains unknown. Confirmed/rejected terminal
results retain the existing signed evidence and persist across restarts.

Tremol RO2601151250 records the serial/Z/receipt counter before opening a new
receipt, prints three `CHM` text lines encoding the command-ID SHA256, and persists
the successful close acknowledgement before reading back the receipt identity.
Recovery reads the individual EJ receipt via 7Ch only when that close checkpoint
exists. Serial, Z, next receipt number and all three markers must match. Counter
increments or equal totals alone are never evidence. Lost close ACK, a changed Z,
another intervening receipt, missing checkpoints/markers or malformed streams stay
unknown. No receipt, cancellation, payment or report is emitted by recovery.
The stream is bounded and checksum-validated. Firmware compatibility is **not yet
physically qualified**; synthetic framing tests are not hardware acceptance.

Datecs MX (including DP-25mx Romania) checkpoints the original serial/slip before close and writes
four fiscal-text fragments of the command SHA256. Recovery reads device123/1,
status76, then exact EJ document125/0 and text125/1. All fragments, serial, global
document identity and fiscal type must match. No print option, payment or close is
issued during recovery. This can resolve a lost close ACK even after later sales;
cancelled documents, missing markers and malformed reads remain unknown.
Romanian MX is **not** the pre-MX `legacyRou` binary SDK. It uses the same ASCII
frame but the Romanian response schema from DUDE's FP_Protocol_RO (29.11.2017):
48/56 return global SlipNumber plus nZrep/nFNum in fiscal mode; 125/0 returns
seven fields, including RecReport before RecNumber. Recovery selects the original
global document with DocType0, then selects `Z*10000+receipt` with DocType1 and
cross-checks global number, report, fiscal number, date, fiscal type and all markers.
Manufacturer and fiscal serial are bound to new checkpoints. Normal success and
recovery return the fiscal number **within Z**, with the global number separate.
Stored `asciiMx` checkpoints from 0.1.40 remain recoverable using the strict
seven-field Romanian schema; checkpoints identified as `rouMx` cannot downgrade
to the six-field schema. Missing/invalid identity stays unknown. No fallback
printing or payment is possible in reconciliation. Test/training-mode two-field
responses are not invented into a Romanian fiscal identity.
This protocol is fixture-tested, not physically qualified on Romanian hardware.
The pre-MX 2014 binary SDK (`legacyRou`, not DP-25mx Romania) still recovers durable
Companion results only; lost results without confirmation require investigation.
External/manual card terminals likewise cannot be automatically reconciled as Viva.

## Presence and UI

### Drawer safety and cash operations

`cashDeposit` and `cashWithdraw` accept `amountMinor` (positive integer bani),
`currency: "RON"` and `reason` through the authorized command envelope.
The actor and equipment pairing are verified separately; passing an operator ID
is not authentication. The model adapter must support the operation and verify
the active ECR operator. Unsupported hardware is rejected, not simulated.

A new cash operation is refused while the drawer is reserved for counting or
the same ECR has a pending/unknown cash or fiscal journal result. This guard
includes other POS devices and survives journal reload/restart. Original command
lookup happens first, so the same ID and payload can still recover its existing
result without dispatching another hardware command. A timeout is not rejection
and does not justify issuing a replacement ID.

`drawerCountStart` and `drawerCountEnd` carry `shiftId` and the verified
`operatorId`; another actor cannot release a counting reservation. Counting does
not start while the ECR journal contains unresolved cash/fiscal effects.

This is not a complete cross-Companion sale-admission barrier: an admitted sale
whose terminal payment has not reached the ECR journal still needs the separate
admission lifecycle/counting race protection tracked in the POS checklist.

Every 15 seconds Companion sends `POST /api/devices/companion/heartbeat` with
`version:1`, overall `state`, `ecr`, `payment`, `localUrls`, and optional
`activeCommand:{id,operation}`. Each component has a state, display message,
name/model and supported capabilities. Only whitelisted fields persist in
`sync.companion_presence`. Passwords, JWTs and card data are not part of status.

POS reads `/api/devices/companion/peers`; its enrolled location limits results.
Liveness expires after 60 seconds based on server receipt time. ECR/Viva failures
are distinct from Companion reachability. Viva ready currently means pinned TLS
connectivity, not an approved transaction. The local status operation is a cached
snapshot, not a financial reconciliation.

Android uses a retained Flutter engine and a `connectedDevice` foreground service.
The API survives switching to the POS browser. From 0.1.30+32, a successful service
start persists boot recovery; explicit lifecycle stop disables it. The receiver
accepts only BOOT_COMPLETED and MY_PACKAGE_REPLACED, starts the foreground service
and initializes the same engine/bridge used by the UI, without opening an activity.
Enrollment, TLS, authorization and journal checks remain unchanged. Identity and
hardware channels are application-owned and available without an activity; APK
installation remains an activity-only action. Cached customer media is restored
even when network/API startup is unavailable. No fiscal/payment command is replayed.

This runs after Android unlock, not in Direct Boot. Android force-stop and some
vendor battery restrictions require reopening Companion; missing overlay permission
still prevents the background customer display. Offline operation remains bounded
by the existing TLS and authorization expiry rules. iOS background operation is not
implemented. Platform reference: [Android foreground-service startup exemptions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

## Verification and remaining release gates

`flutter analyze` and `flutter test` run without hardware. `test/hardware_smoke_test.dart`
is opt-in using `COMPANION_HARDWARE_TEST=1`, `TREMOL_HOST`, `TREMOL_TCP_PASSWORD`
and `DATECS_HOST`. It reads real devices; `COMPANION_SMOKE_PRINT=1` additionally
prints non-fiscal documents only. It never emits fiscal sales, payments or Z.

2026-10-02: real M20 and DP-25 status/non-fiscal smoke passed; phone local API,
durable duplicate replies, heartbeat in background and Z confirmation verified.
Fiscal Datecs MX framing is fixture-tested, not yet fiscally qualified on the
physical Romanian unit. Full checkout, refund/reconciliation workflows, iOS and
ERP user-initiated command screens remain outside this increment.

## Versioned checkout lifecycle (0.1.14+16)

These are vendor-neutral local `/v1/commands` operations. The ERP-signed pairing
and operator grants, POS proof, challenge, organization/location and equipment
ownership checks remain mandatory. Browser-supplied operator IDs or checkout
policies do not override verified claims. Model-specific writes stay in adapters.

| Operation | Business payload | Signed result |
| --- | --- | --- |
| `saleAuthorize` | `saleId`, `receiptJson`, optional `lifecycleVersion: 1` | `saleAdmission` |
| `salePaymentStart` | `saleId`, `amountMinor`, `currency`, `paymentCompanion` | `paymentAdmission` binding the command ID and terminal |
| `saleExternalPaymentConfirm` | `saleId`, `amountMinor`, `currency`, `confirmed: true` | persisted `external_confirmed` admission |
| `saleAbandon` | `saleId` | persisted `abandoned` admission, only before payment |
| `salePaymentReject` | `saleId`, `paymentRejectionProof` | persisted abandonment after verified terminal refusal |

`status.saleAdmissionLifecycleVersion` advertises negotiation support. Existing
admissions are never upgraded or reinterpreted. Version 1 stores intent before
returning proof. An integrated terminal requires both `saleAuthorization` and
`paymentAuthorization`; the original ECR signature binds sale, actor/POS,
amount/currency, fiscal facts, terminal and original payment command. Payment
session IDs must be UUIDs for Viva; persist them before dispatch and never replace
an existing ID during recovery.

External confirmation is an operator assertion under signed `card_mode: external`,
not electronic bank evidence. It blocks abandoning the sale as unpaid. Integrated
timeouts/unknown outcomes cannot fall back to manual confirmation. Refusal release
accepts only the exact terminal's signed `paymentRejection` with
`source: terminal_journal`; a disabled terminal, invalid authorization, busy queue
or unknown result does not establish bank refusal. Completed fiscal commands
prevent refusal release. Original results recover before new live ECR preflight;
unknown stays unknown and does not dispatch again.

Automated tests exercise real TLS, ES256 grants/results, two Companion identities,
persistent journals and restart with synthetic hardware adapters. They do not
qualify physical Tremol/Datecs/Viva operation or Safari/iPad compatibility.

## Optional non-fiscal production printing

Printer setup is optional, under **Imprimantă producție**. The saved
`production_printer_v1` configuration contains `name`, `protocol` (`escpos` or
`zpl`), private LAN IPv4 `host`, integer `port`, `widthDots` (320–832) and
`heightDots` (480–2400). It preserves enrollment, TLS keys, ECR/Viva and OTA
identities. There is no printer discovery, background printer worker or network
probe. Explicitly configured printers register through the existing authenticated
ERP equipment registration/heartbeat path. SQL 224 must be installed to accept
`kind: printer`; registration does not grant production rights or bypass an
administrator's department assignment. Companion requires its current trusted
equipment ownership before dispatch. A request cannot supply a host or raw bytes.

All print writes use the existing HTTPS listener, exact HTTPS browser `Origin`,
32 KiB body bound, per-equipment executor and durable command journal. They grant
no POS, fiscal, payment or stock-posting authority. Work tickets require ESC/POS;
labels require ZPL; the diagnostic template supports the configured protocol.
Printable text supports ASCII and a fixed Romanian transliteration (`ă/â → a`,
`î → i`, `ș/ş → s`, `ț/ţ → t`, with matching capitals) at byte rendering. Signed
facts retain their original Romanian characters. Controls, ZPL `^`, `~` and
backslash, unsupported glyphs and excessive lengths cause an explicit error;
they are never replaced by executable printer commands or silently discarded.
Names are bounded to 80 characters, units to 12 and other printable fields to 100.
Labels that cannot contain all fields at the configured size are rejected.
Printer font/UTF-8 capabilities remain a future hardware-specific configuration.

### Exact server-authorized prints

NIIMBOT BLE uses the same endpoint, signed tickets, ownership checks, durable
journal and explicit reprint rules as LAN printers. Wizard discovery identifies
the model before saving; it sends no print commands. Android permissions reuse
the scale setup helper. Supported initial profiles: B1, B21 C2B, B21S, D101,
D110 (2304/2305); protocol V4/V5 and unknown model IDs are rejected explicitly.
These profiles are protocol-tested, not yet physically qualified.

Config `protocol: niimbot` contains `host: ble:AA:BB:CC:DD:EE:FF`, `port: 0`,
`modelId`, `widthDots`, `heightDots` and name. This is an explicit BLE identity,
not a socket endpoint. ERP migration282 preserves unique equipment ownership;
optional production283 enables the NIIMBOT label assignment and existing grants.
Printer ID remains `printer:<host>:<port>`; LAN identities are unchanged.
Only gap labels and single-copy monochrome fixed templates are supported.
Width must match the installed roll, be a multiple of8 and not exceed the model's
head; height64–2400 dots. Oversized content is rejected, never truncated.
Raw bytes, firmware commands and calibration are not exposed publicly.
BLE writes use bounded ATT20 chunks and matching/checksummed replies. A missing
reply, disconnect or error never repeats a print automatically. Physical output
is conservatively reported as sent/unconfirmed even after the device status ACK.

`POST /v1/production-print` accepts exactly `{ticket,payload}`. ERP issues the
ES256 JWT using the existing Companion signing key: `iss: chimera-companion`,
`kind: production-print`, `version: 1`, organization/location, `aud` and `companion`
equal the target Companion, `sub` equal the operator, `pos` equal the KDS device
(or `erp` for authorized backoffice), exact `origin`, single `operations` intent,
`commandId`, `printerId`, `provisional`, and `payloadHash`.

Payload v1 contains all fields below, including explicit nulls:

```json
{"version":1,"commandId":"UUID","operation":"productionLabel","printerId":"printer:192.168.1.30:9100","operationId":"operation-id","product":"Croissant cu ciocolată","lot":"native-lot-id","quantity":"4.5","unit":"kg","producedAt":"2026-10-17T08:00:00.000Z","expiresAt":null,"provisional":false,"reprintOf":null,"reprintReason":null}
```

Operations are `productionWorkTicket`, `productionLabel` and
`productionPrintDiagnostic`. Quantities are positive decimal strings with up to
12 integer and six fractional digits; timestamps are UTC ISO8601. Online tickets
last at most 300 seconds. Exact provisional work tickets can last until their
verified work lease expires, at most seven days. Those carry payload `version: 2`
and `factKind: assigned_work`: product/quantity/unit describe planned output,
`lot` identifies a real reserved input and `producedAt` is the actual work start.
The fixed template explicitly prints **PLANNED OUTPUT**, **Reserved input lot**,
**Planned qty**, and **Started**, rather than claiming finished stock. No future
native output lot or expiry is invented. Renewing HTTP authorization never
changes the payload or extends an already issued ticket's expiry.

### Offline measured output labels

ERP `POST /api/production/printing/label-leases` requires current KDS device and
operator authentication, exact origin, a signed work lease, active production and
an assigned ZPL printer. It returns `{lease,scope,companion_url,
companion_public_jwk,expires_at}`. It does not accept or approve measured output.
The immutable SQL-owned scope contains `version:1`, `lease_id`, `operation_id`,
`product_id`, `product`, `unit`, `printer_id`, `device_id`, `companion_id`, `origin`,
`max_quantity_decimal`, `max_commands:100`, `not_before` and `expires_at`.
Its expiry is capped by the original work lease and seven-day authentication
window. The existing ERP ES256 key signs `kind: production-label-lease`,
`labelScope: scope`, `payloadHash: canonical SHA256(scope)`, `session_id: lease_id`,
`commandId: operation_id`, the exact printer/device/operator/origin, only
`operations: [productionLabel]`, `cnf.jwk` for KDS and `peer.jwk` for Companion.

After recording an immutable local measurement, KDS sends
`POST /v1/production-label` with exactly `{lease,payload,message,signature}`.
Payload v3 uses every v1 field plus `factKind: offline_output`, `productId` and
`reportId` (UUID). Product, unit, product ID, printer and operation must exactly
match the lease. `provisional` must be true; `expiresAt` must be null. `lot` must
be exactly `LOCAL:<reportId>`, visibly a local identifier, never a native stock lot.
Quantity must be positive and no greater than the signed per-label quantity bound;
decimal comparisons do not use floating point. The measured `producedAt` must be
between the work start and the Companion's current time (five seconds skew).

`message` is the retained exact JSON string
`{version:1,leaseId,commandId,payloadHash,origin}`. KDS signs its UTF-8 bytes with
the bound enrolled P-256 key using ECDSA SHA-256, IEEE-P1363 signature encoding.
Companion checks both the ERP lease and the device signature, exact payload hash,
all scope/time/quantity bounds, local revocation evidence and current printer
ownership before journaling or sending. Hashing uses recursively sorted object
keys, original array order and UTF-8 canonical JSON; quantities remain strings.
These labels conspicuously display **PROVISIONAL OFFLINE**, **NOT ERP ACCEPTED**
and **LOCAL OUTPUT**. Printing never accepts a report or posts/reserves stock.
ERP reconciliation of the measured output remains a separate operation.

### Outcomes, recovery and reprints

Both local routes return the existing signed `{resultJson,signature}` envelope.
Parsed results include `outcome: unknown`, `delivery: sent_unconfirmed | unknown`,
`commandId`, `operation`, `printerId`, `companion`, original `payloadHash`,
operator/device, organization/location, `journalFound` and a message. Output-label
results additionally bind `leaseId` and `reportId`. Verify the signature over the
exact `resultJson` bytes with ERP's `companion_public_jwk` and check every binding.
Socket flush means **sent/unconfirmed**, never proof of physical printing.

Identical IDs recover the durable result after a lost reply or process restart;
changed payloads conflict. Unknown/in-flight results never automatically resend.
Explicit reprints require a new command ID, `reprintOf` and a bounded reason.
Offline output reprints must preserve the original report and every measurement
fact. A second first-print command for the same report is rejected. The durable
journal counts every admitted output-label command, including uncertain sends and
reprints, against the signed lease limit; restart does not reset it. Lease/proof
tokens and private keys are not written into the business journal or ERP audit.
Authorization failures are 403 and command/report/limit conflicts are 409.

Focused tests cover synthetic ES256 identities, real loopback HTTPS, mocked
printer sends, restart, tampering, Romanian rendering, limits and reprints.
Physical ESC/POS/ZPL models, LAN behavior, fonts, media sizing and statutory
acceptance have not been qualified. No APK publication follows from these tests.

## Developer diagnostic boundary

`rawEcr` is a separately gated development diagnostic, not a business operation
or production checkout API. Hardware is real even in development. Raw commands
are not a shortcut around operator authorization, signed envelopes, serialization
or unknown-result handling. POS business screens use vendor-neutral operations.

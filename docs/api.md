# Companion local API: v1 dispatch, v2 authorization

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
`OPTIONS` supports the two POST paths. CORS headers do not themselves authorize
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

The POS Settings download uses the existing public ERP release manifest and its
immutable APK path. It does not include enrollment or operator credentials.
The shared Companion app bar exposes **Verifică actualizările** on every page,
including initial setup, nested details and diagnostics. Before enrollment, the
update dialog accepts an ERP HTTPS address; after enrollment it uses the saved
ERP. The existing manifest bounds, digest and Android package/signature checks
remain enforced. Update dialogs suspend bridge commands, retain any preexisting
configuration lock, and cannot open during an active device operation.

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

## Developer diagnostic boundary

`rawEcr` is a separately gated development diagnostic, not a business operation
or production checkout API. Hardware is real even in development. Raw commands
are not a shortcut around operator authorization, signed envelopes, serialization
or unknown-result handling. POS business screens use vendor-neutral operations.

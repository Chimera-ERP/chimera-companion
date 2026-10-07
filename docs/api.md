# Companion local API: v1 dispatch, v2 authorization

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
The API survives switching to the POS browser. Force-stop, reboot, network loss
and vendor battery restrictions can still make the device unavailable; reopen
Companion. iOS background operation is not implemented.

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

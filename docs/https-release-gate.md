# Local HTTPS release gate

## Current state — 2026-10-02

The server now requires a TLS context. There is no plaintext listener or fallback.
The POS refuses HTTP before requesting a command ticket. Existing HTTP addresses
must be replaced with the provisioned HTTPS origin.

This is a transport foundation, **not** the offline authentication implementation.
Current commands still use the existing online capability verification. JWT leases,
device signing keys, operator grants and mutual proof of possession are pending.

Host tests verify trusted HTTPS, refusal of untrusted certificates and plaintext,
payload authorization checks and missing/invalid TLS provisioning. These do not
prove Chrome/PWA trust or permission behavior on an Android phone.

ADB currently exposes only `emulator-5554` (Android 11), with no Chrome package.
No new APK has been installed on the physical phone. The physical release gate
is pending; continue the remaining security work only after this gate is verified.

## Provisioning contract

The application support directory must contain a private `local-tls` directory:

- `endpoint.json`: `{"origin":"https://companion.example.com:8765"}`
- `certificate.pem`: PEM leaf certificate and intermediate chain.
- `private-key.pem`: matching PEM server key, unique to this installation.

The name must resolve to the Companion's LAN address locally, including during
Internet loss. The certificate must cover the exact hostname and be accepted by
the target browser. Loading the PEM does not establish browser trust.

Production certificate issuance, renewal and import into private application
storage are **not yet implemented**. This file-based provisioning is for the
initial transport probe. Never put a shared TLS key or a CA private key in an APK,
the source repository or a POS browser. The future Android Keystore signing key
is distinct from this TLS certificate/key.

A development CA can be trusted explicitly on the test device, without disabling
certificate checks. That validates a managed-CA deployment only; it does not prove
publicly trusted certificate issuance or renewal.

## Reproducible host probe

Use a private temporary directory with a certificate/key generated for the actual
test hostname. Do not reuse another installation's private key. Write endpoint.json
with that origin, then run:

```sh
dart run tool/https_preflight.dart /absolute/private/tls-directory
```

Open the printed `/health` URL in the target browser. The tool uses the same TLS
listener as Companion but deliberately cannot authorize or execute hardware
commands. An HTTP request to the same port must fail.

## Physical acceptance checklist

- [ ] Phone appears in ADB; record Android and Chrome versions.
- [ ] Provision the certificate and local DNS; open HTTPS without an interstitial.
- [ ] From the POS origin, fetch `/health` with normal TLS checks and LAN permission.
- [ ] Reject LAN permission; show a connection error without sending a command.
- [ ] Block Internet while retaining LAN; reload installed POS and repeat the fetch.
- [ ] Repeat after Chrome/Companion restart to rule out dependence on cached DNS.
- [ ] Confirm the API remains reachable with Companion backgrounded.
- [ ] Confirm wrong-hostname, expired and untrusted certificates fail.
- [ ] Record the chosen deployment provisioning and renewal mechanism.

The offline probe at this stage is transport-only. A hardware command with Chimera
unavailable remains blocked until the subsequent JWT implementation is complete.

References: [Dart secure HTTP listener](https://api.dart.dev/dart-io/HttpServer/bindSecure.html)
and [Chrome local network access](https://developer.chrome.com/blog/local-network-access).

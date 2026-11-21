# Vendor protocol provenance

## Ulanzi D200-family USB console

Protocol references: [racerxdl device implementation](https://github.com/racerxdl/ulanzi-d200-linux/blob/main/ulanzi_manager/device.py)
and [open-ulanzi-d200 protocol documentation](https://github.com/mindlss/open-ulanzi-d200/blob/main/docs/en.md).
These are third-party reverse-engineered protocol descriptions, not vendor certification.
Chimera implements framing and semantic rendering independently in Dart/Kotlin, without
bundling upstream software, device firmware, or desktop configuration profiles. Only the
observed2207:0019 custom HID interface is selected; the boot keyboard is not claimed.
Model/firmware and USB power requirements remain a physical acceptance gate.
The [screen builder reference](https://github.com/mindlss/open-ulanzi-d200/blob/main/src/screen-builder.js)
also names image assets by content. Chimera uses SHA256 PNG paths to prevent stale per-slot
image reuse; this mitigates a cache risk, not proof that caching caused a particular device report.

## NIIMBOT BLE

Reference: https://github.com/MultiMote/niimbluelib/tree/a9bc3f5c20c95e3a31ea3f5f2302ce7b27c34abe
and https://github.com/MultiMote/niimblue. Framing, model IDs, B1/D110 task
sequences and bitmap count encoding are implemented in Dart; no web runtime
or vendor firmware is bundled. MIT, Copyright (c) 2024 MultiMote; the MIT
permission and warranty notice reproduced below applies to this port too.
The upstream README additionally describes educational use and recommends vendor
consent for commercial use; this implementation is not a legal/redistribution
review. Hardware/model qualification remains pending.

## Acaia BLE

Protocol reference: https://github.com/gaggimate/esp-arduino-ble-scales/blob/v1.0.7/src/scales/acaia.cpp
Used for UUIDs, framing, handshake, heartbeat and weight decoding; no Arduino
runtime is bundled. Flutter BLE transport uses flutter_reactive_ble (BSD-3-Clause)
and permission_handler (MIT). BLE packages are pinned together at 5.4.0 and
permission_handler at major12: newer releases require SDK37, while this project
builds against SDK36. The repository Gradle configuration aligns the pinned BLE
library's compileSdk33 with SDK36, required by Flutter's resolved AndroidX
dependencies; target/min SDK are unchanged and the global pub cache is unmodified.
Android implementation; iOS is not configured here.
No physical-model or legal-for-trade qualification is claimed.

Unit-setting protocol reference: Apollo2 `src/core/scale_driver_acaia.cpp`, commit
`f4d2b29ae858e7196d2466a48ddbf4da057cd520`:
https://github.com/mlsorensen/Apollo2/blob/f4d2b29ae858e7196d2466a48ddbf4da057cd520/src/core/scale_driver_acaia.cpp
Used for cmd10 setting IDs/values and generation-specific status offsets; no
Apollo runtime bundled. Automatic readback and bounded attempts are implemented
in our existing adapter. Physical qualification remains pending.

MIT License — Copyright (c) 2023 kstam; Copyright (c) 2026 Marcus (Apollo2)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## iMin customer display

Reference: https://oss-sg.imin.sg/docs/en/CustomerDisplay.html
Android API: https://developer.android.com/reference/android/app/Presentation
Reviewed 2026-10-14. Uses Android DisplayManager/Presentation and application overlay
permission for independent secondary-screen lifetime. No iMin SDK or vendor source
is imported. Swan 2 physical firmware qualification remains pending.

## Tremol

Source: https://tremol.bg/en/support/zfplab/RO/2601151250
Romanian protocol version: 2601151250. Downloaded 2026-09-26.
Bundle SHA-256: `4d89f7068e055c6ecda6b9cc7275bd99cd441ffc0919defc5419ff599d871ffa`.

The FP21 USB test uses the non-fiscal document commands 2Eh/37h/2Fh (sections 2.6.1, 2.6.16 and 2.6.2), and 51h/P for EAN-13 (§2.2.12). Fisco 2.0.0.53, Tremol32 DLL 1.0.0.45, uses subtype 2, declared EAN length 12 and a 100-byte data field. Its driver computes the wire length independently of the human-readable check digit. Earlier on-device attempts with length 13 returned syntax errors. ReadStatus (section 2.2.1) distinguishes a non-fiscal open document by ST2.0 and a fiscal document by ST2.1. In the same response ST0.1 reports a previous power interruption. If the 09h poll indicates ready, all other readiness checks pass and both document bits are clear, the local non-fiscal USB probe reports ready and displays the interruption as information. The USB trial can finish the recorded non-fiscal sample after the operator identifies its last printed line. A capture from vendor ZFPLabServer 1.9.6 confirms standalone CloseNonFiscalReceipt sends frame 02 23 21 2F 32 3D 0A at sequence 21h. A2 denotes a missing customer display and an illegal command. The direct maintenance actions use 2Fh for an open non-fiscal document and the separate no-argument CutPaper command 29h. Both read the live status before acting. The bundle re-downloaded from the supplied RO 2601151250 page matches the recorded SHA-256. Its 230 unique command definitions include PrintBarcode and two QR-related server configuration operations, ReadQRserverAddress and SetQRserverAddress (§§2.11.17 and 2.11.38). It has no command definition to print an arbitrary QR payload. The [Bulgarian Tremol protocol 2608251115](https://tremol.bg/en/support/zfplab/bg/2608251115) §2.2.13 documents 51h/C for a native QR with a resolution digit and variable-length data. The QR-only USB trial sends the captured ZFPLab wire format, resolution 4 and https://chimeraerp.ro in a 200-byte space-padded field. The BG PDF describes variable-length data, and the earlier unpadded trial on the Romanian printer produced no QR. An optical scan must confirm the encoded content if the printer accepts the command. QR support depends on the attached firmware. The [Fisco manual](https://fisco.ro/manual-fisco/) lists text fallback for QR on Tremol. Companion records each symbol response independently.

Portable implementation follows framing, ACK/checksum and commands 20h, 30h,
31h (specified VAT), 33h (subtotal), 35h, 38h and 71h. No vendor source is copied.
Only ordinary positive-quantity sales are supported; adjustments/returns and
discount commands are not available. Unsupported encoding is rejected before
dispatch. VAT groups and cash/card codes are supplied by configuration.

**Not implemented:** Tremol LAN password handshake. A device waiting for a LAN
password is rejected before receipt opening. Do not disable the device's password
to work around this; finish authentication using the vendor-supported procedure.
M20/FP21 firmware compatibility remains a hardware qualification item.

Protocol PDF was read with text extraction. It is not bundled into the app.

2026-10-27 reconciliation reference: RO2601151250 60h (serial), 71h (last receipt)
and 7Ch (`J0;N;start;end`, six-digit receipt bounds). The vendor JS demo reads the
EJ stream through `RawRead(0,"@")`. Our bounded framed-stream parser is independent;
no Tremol runtime is imported. This readback and the additional receipt text markers
require physical M20/FP21 qualification before treating them as production-supported.

## Android fiscal USB and Bluetooth

An unfiscalized Romanian Activa FP21 running `2.00TRP21_AC` returned a valid 60h data frame containing exactly two ASCII letters and eight decimal digits for its factory serial. The length on this unit was ten bytes, while RO 2601151250 §2.5.1 specifies eleven. The frame checksum, sequence and echoed command were verified on USB on 2026-11-20.

The same FP21 reported BT support in `4Eh R;D;S`, echoed `R;D;S` for `R;D;D`, and returned a distinct radio state for `R;B;S`. RO §2.11.13 and §2.11.36 document the status query and explicit enable operation. Companion checks the echoed fields, requires a separate valid radio response, and uses Android for bonding.

The FP21 manufacturer lists USB and Bluetooth. The Romanian DP-25 MX catalog lists both interfaces and provides the Windows USB package containing FTDI CDM 2.12.36.4. Android uses CDC ACM (including the FP21 STM32 virtual COM interface) or a single-channel FTDI FT232B/R or FT-X UART. The FTDI reader strips two modem status bytes per USB packet and checks line errors. Bluetooth uses the standard Classic serial port service on a paired register. An individual firmware and module combination still needs a hardware trial. [Tremol FP21](https://tremol.bg/en/product/tremol-fp21) · [Datecs DP-25 MX and USB driver](https://www.datecs.ro/casa-de-marcat-datecs-dp-25-mx.html) · [Android USB host](https://developer.android.com/develop/connectivity/usb/host) · [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)

## Datecs Romania SDK

Official DP-25 downloads: https://www.datecs.bg/en/products/162
SDK: https://www.datecs.bg/en/downloads/zip?id=fiscalprinter-java-sdk_2014-04-25_v1.0.8-ROU.zip
Bundle SHA-256: `6de1b55e90d58cd79e1bfcff7e521aa4652668fc2f7cd27bc71a92fa306a173f`.
Bundled, unmodified JAR: `android/app/libs/datecs-rou-1.0.8.jar`.
JAR SHA-256: `e68af325c6ea5c511cf3c167629a3abc85a52565da6573514c7e16202d538d6c`.

The Kotlin bridge uses the same `DP25ROU` status, VAT, receipt (48/49/51/53/56) and X/Z routines on LAN and on explicitly selected Android USB or Bluetooth transports. Constructor detection reads 90/1 and exposes the manufacturer serial through `getSerialNumber()`. A USB checkout verifies that identity on its selected open handle before issuing the sale. In SDK 1.0.8, `FPBase.writePacket` can send the same packet up to three times after a NAK. Companion’s serial transport stops the exchange at the first NAK, timeout or mismatched reply and provides the SDK only the response for the original command. Vendor status and checksum checks still run. Existing LAN sessions use the SDK’s socket behavior. Physical qualification is required for each firmware and port.
Confirm vendor redistribution/license conditions before distributing the APK.

## Existing Chimera gateway

Source: https://github.com/Chimera-ERP/chimera-pos-gateway
Read commit: `cc0f01f` (master at time of inspection).
Ported files: `src/models/protocols/datecs-ascii/command-framer.ts` and the
non-fiscal command schemas (38/42/39) in `command-registry.ts`.

First-command framing has byte-for-byte parity fixtures obtained by executing
the original TypeScript functions. Commands after the first use incrementing
sequence bytes instead of repeating the original constant `Z` (0x5A).
Reply matching/checksum checks and preservation of empty response fields were
added. This profile is separate from the Romanian SDK profile and is exposed
only for non-fiscal operations. No automatic protocol detection/fallback.

The current parser tests use synthetic replies. Print validation against the
previously working hardware remains required; these tests do not establish
that every DP-25 firmware speaks the gateway's protocol.

## Datecs ASCII-MX reconciliation

Romanian MX primary reference: official DUDE1.1.0.0 distribution from
https://www.datecs.ro/dude.html — download
https://www.datecs.ro/_res/media/support/dude-setup-2020-07-30v1-1-0-0.zip
(SHA256 `d30da29ac93fec4cb8c27d9227d5e613d1044f741edb659a9f29ffb4548f5c7a`).
Read `DOCUMENTATION/FP_Protocol_RO.pdf`, 29.11.2017, SHA256
`b35635d0ada8ba3134012d520fbb0758762220893556053e78ee827c8ea78539`.
Commands48/56 return SlipNumber/nZrep/nFNum; 123/1 identifies the manufacturer and
fiscal serial; 125/0 has seven fields and fiscal addressing Z*10000+receipt.
Reviewed the Romanian PDF schema and corresponding English reference in that
same bundle. No DUDE executable was run or bundled; no new vendor library added.
The current Romanian DP-25mx uses MX framing, not the 2014 DP25ROU binary SDK.
Recovery is tested with synthetic framed replies and durable journal restarts;
physical firmware qualification remains pending.

Receipt preflight reads Romanian MX command 50 with no parameters. The response
contains the first Z number, seven rates (A–G) and a timestamp. Values 100.00
(exempt), 100.01 (other taxes) and 100.02 (inactive) have no percentage mapping.
On legacy DP25ROU the official SDK documents the argument-free
`command83Variant1Version0()` as the current-configuration read. It returns
`outputEnabledTaxesArray`, a four-bit A–D enable mask, and the configured rates.
Only enabled groups with a documented mapping and two-decimal configuration
participate. The parameterized programming variant is never used by checkout.
The two layouts are tested with synthetic device data. Fiscal qualification of
these reads and of the ensuing receipts is still required on each firmware.

Datecs ASCII-MX EJ recovery uses the primary protocol reference
https://www.datecs.bg/en/downloads/pdf?id=PM_FMP350X_FMP55X_FP700X-BUL_+FPprotocol_v2.00_eng.pdf
(commands48/54/56/123/125). This is a Bulgarian X-series reference for the explicit
ASCII profile, not proof of support on every Romanian DP-25. We did not import a
new vendor library or send these commands through the legacy Romanian SDK.
Unsupported firmware stays unknown, never automatically reissued.

## Viva


https://developer.viva.com/apis-for-point-of-sale/card-terminals-devices/peer-to-peer-communication/point-to-point-protocol-rest-api/

Local HTTPS sale/session API, integer minor units, explicitly configured numeric
currency mapping (RON 946). No cloud OAuth and no Viva fiscalisation service.
Only sanitized confirmation results enter the journal; card metadata is discarded.
TLS uses an explicit terminal certificate pin, not a trust-all callback.
Demo vs live is determined by the terminal application, not a URL switch.

## Rive

Flutter runtime `rive 0.14.11` / `rive_native 0.1.11`, MIT:
https://github.com/rive-app/rive-flutter and https://pub.dev/packages/rive_native.
Original Companion illustrations, timelines and state machines are authored in
`design/companion-motion/scene.rml`, with official Rive CLI1.9.0. No third-party
community artwork, scripts, fonts or remote media are included in these scenes.
The user-supplied Chimera logo is the unchanged local Desktop screenshot
`Screenshot 2026-03-09 at 20.51.25.png`, preserved as
`design/companion-motion/chimera.png`. Rive difference compositing adapts its
monochrome ink for the OLED canvas; the mark is not traced or replaced.
The exported `.riv` and fourteen fallback stills are bundled for offline use.
The user authorized upload/export on 2026-11-05. The project is bound in
`rive.yaml` (project261552/file2707026, revision49548382). The latest export
explicitly reports the Free-plan Rive splash branding (even though the JSON
compiler warning array is empty). Earlier absence-of-warning evidence does not
establish an unbranded export. Vendor branding is retained and remains controlled
by the account entitlement.
Flutter includes runtime dependency notices in its license registry. Rive CLI is
a development tool, not an APK dependency.

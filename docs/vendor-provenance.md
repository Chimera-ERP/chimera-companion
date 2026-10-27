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

## Datecs Romania SDK

Official DP-25 downloads: https://www.datecs.bg/en/products/162
SDK: https://www.datecs.bg/en/downloads/zip?id=fiscalprinter-java-sdk_2014-04-25_v1.0.8-ROU.zip
Bundle SHA-256: `6de1b55e90d58cd79e1bfcff7e521aa4652668fc2f7cd27bc71a92fa306a173f`.
Bundled, unmodified JAR: `android/app/libs/datecs-rou-1.0.8.jar`.
JAR SHA-256: `e68af325c6ea5c511cf3c167629a3abc85a52565da6573514c7e16202d538d6c`.

Native Kotlin bridge wraps `DP25ROU` with socket streams, status queries,
48/49/51/53/56 receipt operations. The SDK owns low-level protocol behavior,
including any internal retry policy; Companion never retries an entire receipt.
This older vendor SDK must be qualified against the actual production firmware.
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

## Viva

https://developer.viva.com/apis-for-point-of-sale/card-terminals-devices/peer-to-peer-communication/point-to-point-protocol-rest-api/

Local HTTPS sale/session API, integer minor units, explicitly configured numeric
currency mapping (RON 946). No cloud OAuth and no Viva fiscalisation service.
Only sanitized confirmation results enter the journal; card metadata is discarded.
TLS uses an explicit terminal certificate pin, not a trust-all callback.
Demo vs live is determined by the terminal application, not a URL switch.

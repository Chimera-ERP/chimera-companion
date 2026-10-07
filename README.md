# Chimera Companion

Separate Flutter hardware application for Chimera ERP and POS.

Unified local API for Tremol RO, Datecs MX/legacy ROU and Viva Local Terminal.
Includes PIN enrollment, a setup wizard, responsive status dashboard, command
journal, non-fiscal/X/Z actions (Z requires confirmation), and heartbeat to Chimera
for POS visibility. Android keeps the local API running with a foreground service.

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

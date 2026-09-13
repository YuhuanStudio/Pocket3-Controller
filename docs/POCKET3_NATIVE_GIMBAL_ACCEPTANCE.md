# Pocket 3 native gimbal acceptance

`Pocket3NativeGimbalAcceptanceExecutor` is a developer acceptance route over
the already command-ready station Datalink owner. Its default request is a
dry-run. An execute request must carry the exact station BLE binding, LAN
07/07 identity digest, retained owner evidence, and the matching Datalink
binding.

The bounded sequence is six short 04/01 continuous checks: near, middle and
far pan, followed by near, middle and far tilt. Each check pumps at most 20 Hz
for its requested hold window, releases with 04/01 center neutral, and records
only frame counts, ACK status, scalar 04/05 telemetry, timeout and connection
fences. FE08 recenter and FE09 flip are then issued once each through the same
owner; their ACK and scalar telemetry are reported separately from physical
completion, which remains unverified by this route. A final neutral fail-stop
is attempted on completion, cancellation or connection change.

The owner does not create a second transport, associate with Wi-Fi, persist
credentials, or save images. Hardware execution remains an explicit caller
choice and is not performed by tests.

The developer IPC operation
`validation-wireless-native-gimbal-acceptance` and the matching CLI command
consume the `WirelessGimbalModel` station link. They require the BLE session,
peer, station generation, native binding ID and native generation supplied by
the caller to match the current station result. Omitting `--execute` returns
the bounded plan without an owner; `--execute` gets the existing station owner
only after those fences and the 07/07 identity evidence pass. No second socket,
Wi-Fi association, credential field or image data is involved. Cancellation or
a connection change returns typed partial evidence after one fail-stop.

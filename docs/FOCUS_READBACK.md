# Read-only BLE focus-point candidates

This isolated post-beta patch adds a decoder, bounded passive recorder, and an
explicit development CLI/RPC that submits the existing read subscription once.
It does not automatically connect/pair Bluetooth, add an AF setter, change camera
settings, wire new App controls, or establish that a BLE peer is the USB camera.

`LensPointCandidate.decode` reads `cam_lens_state` Float32 little-endian fields
at offsets 1 and 5. It accepts semantic lengths of at least 9 bytes up to the
DUML payload bound, including the actual 47-byte Pocket 3 values and the
upstream 67-byte capture. Both numbers must be finite and in [0,1]. The raw
mode byte (including B2) and original length remain explicit; only the nine
relevant bytes are retained. `calibration` is always
`unverified_dji_normalized_candidate`. Decoding saved JSON revalidates the
raw prefix and numeric fields. None of these values imply optical focus success.

The field offsets come from the pinned
[OpenPocketCine parser](https://github.com/erik-sutton95/OpenPocketCine/blob/9c4e7334ca4d935c5d467abecaf8f968f7927d84/Sources/OpenPocketViewCore/CameraControl.swift#L601-L622).
This implementation is independent; it does not copy the upstream implementation.
The observed Pocket 3 noncentral prefix `b2f140713ef134f13e` decodes to
`(0.23559929430484772, 0.47110703587532043)`. The earlier center prefix
`b200ffff3e00ffff3e` decodes to `(0.49999237060546875, 0.49999237060546875)`.
These are offline byte fixtures from the main workspace's
`artifacts/hardware-roll-2026-09-09/properties/cam_lens_state.json` and
`artifacts/hardware-roll-2026-09-09/lens-query.json`. No time-correlated body-tap
comparison exists; varying bytes alone cannot calibrate the point or its axes.

`BluetoothFocusPointObservation` is immutable and includes exact BLE session
and peripheral UUIDs, DUML sequence, property transaction ID, wall-clock
`hostReceivedAt`, and monotonic `receivedUptime`. Its freshness method requires
the matching paired peer/session and a host age of at most five seconds.
Wall-clock receipt time is diagnostic; monotonic time governs freshness.

`BluetoothFocusPointRecorder` only constructs the existing source02→28,
flags40, 00/99 `cam_lens_state` subscription. The discovery owner calls
`submitted(at:)` once inside its final connection/operation permit immediately
before the local write; this type itself has no I/O. Feed it CRC-validated
packets from FFF4/FFF5 together with the actual peer/session. Only source28→02
flags00 00/99 lens pushes become observations. An ACK uses its own matching
query sequence and stays separate from the property transaction/sequence.
The existing AF-mode/settings decoder and store remain unchanged.

The recorder admits at most 64 distinct lens pushes over 12 seconds, with
bounded replay fingerprints, increasing modulo-UInt16 sequence admission, and
monotonic receive times. Invalid candidates consume the budget and clear the
current candidate rather than silently retaining the previous valid point.
Historical samples keep their original timestamps. Expiry, sample limit,
early finish, cancellation, connection retirement, and clock failure have
different result reasons. The owner must finish on cancellation/disconnection;
foreign packets cannot mutate this recording. No live timer, retry, or automatic
subscription renewal exists.

Next integration should record two user-marked, asymmetric taps on the camera's
own screen, retaining every admitted lens push and current preview geometry.
It must bind the operation to the same explicit BLE peer and record USB capture
identity separately. Only correlated point changes can validate a particular
device/firmware/orientation mapping. Do not expose the candidates as calibrated
AVFoundation coordinates or enable the known but BLE-unvalidated AF setters.

Tests cover 47/67-byte values, slices, malformed/finite bounds, immutable
snapshots, peer/session/five-second freshness, ACK separation, duplicate and
backward sequence rejection, wraparound, cancellation, clock rollback, unknown
values, and finite memory/time limits. Tests are pure and use no hardware.

## Live development entry and lifecycle

`Pocket3BluetoothDiscovery` owns the correct peripheral,
FFF5 characteristic, paired generation, operation permits and validated packet
decoder. The recording remains inside this owner:

1. One explicit development recording operation holds those exact object
   identities and a `BluetoothFocusPointRecorder`. It mirrors the admission and final
   permit checks of `queryCameraProperty`, including its reserved sequence,
   registered paired state, empty outgoing queue and full-frame MTU check.
   The existing 46-byte subscription is submitted once, without scan/pair or a setter.
2. The recorder receives packets from `notified(_:characteristic:error:session:)`'s
   decoded-packet loop (reached by the CoreBluetooth value callback),
   after checking the callback's captured session/peripheral. One Date
   and system uptime are captured per received packet and passed unchanged, without replacing
   the public single `onFrame` callback or exporting general raw traffic.
3. Observation lasts until the recorder ends or 12 seconds expires. Unlike the existing
   generic query, it does not finish upon the first ACK plus first push. It reserves the
   operation against other explicit queries/probes, but allow normal established
   keepalive traffic after the single subscription write. Existing lens/property
   operations suppress `drainWrites` and the one-second keepalive; simply stretching
   either existing operation to 12 seconds would change the connection conditions.
4. Explicit cancellation is connected to the existing scan/connect/pair/close and
   `stopNativeProbe`/`cancelNativeProbe` paths. Retired callbacks cannot append
   samples; connection changes, cancellation and timeout remain distinct, and
   only the matching operation is cleared. There is no guessed unsubscribe/restore
   command. Observation expiry must not itself send anything.
5. The immutable recording is returned through a development RPC only. The existing
   WirelessValidation gate and ordinary 20-second IPC timeout can accommodate the
   bounded 12-second window. Record USB preview identity separately and require
   human-marked body taps before claiming a BLE-to-preview coordinate mapping.

These connection points are now implemented by `recordLensPoints`, its matching
discovery operation, and the `validation-wireless-lens-series` development route.
The existing App layout and controls are unchanged. The command requires both
UUIDs from the currently paired discovery status; the BLE session UUID is not a
USB capture session ID and does not include the `ble:` prefix:

```sh
pocket3 validation-wireless-lens-series --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID
```

The App must already be running with `--hardware-validation` and paired to that
peer. Unknown options, duplicate options, arbitrary properties, duration changes,
missing UUIDs and stale identities are rejected. Results are JSON on stdout and
include the immutable history plus the end reason. A query error before local
submission has no submission timestamp; no automatic retry or restore is sent.
Keepalive uses the existing queue during observation. Stop cancels the recording
without inferring a gimbal neutral or optical-focus outcome.

The first admitted packet is host-fresh receipt, not proof that this subscription
or a body tap generated it: a new recording does not inherit the previous stream's
sequence baseline. Likewise, 64 admitted properties can end the recording before
12 seconds. Interpret `end` and the original sample timestamps before correlating
operator taps; neither the ACK nor a time window alone establishes causality.

Validation: Xcode-beta dependency resolution and the existing compatibility patch
completed in the isolated worktree. The Release filter
`Bluetooth(FocusPoint|LensSeriesRequest|LensStateQuery|CameraPropertyQuery|CameraSettingsStore|DiscoveryState)Tests`
passed all 42 tests across six suites. No App launch, camera operation,
manual code signing, commit, merge, or push was performed.

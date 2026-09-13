# USB pan／tilt continuous stress contract

The current v5 `HardwareValidator` exercises fixed `+3600` and `+18000`
raw offsets, one positive path per axis, and interruption trials. The v1
`USBManualAcceptance` metrics add four positive near/far holds. Those checks
cover fresh readback, stable hold, restore, and reconnect fencing, but they do
not describe both raw directions and both declared endpoints. A configured
`speed=1` field also cannot prove that a farther stick input produced a higher
raw rate.

`USBPanTiltStressAcceptance` is the pure Core plan and evaluator for the next
developer collector. Its reviewed matrix has 16 scalar cases:

- pan and tilt;
- negative and positive raw directions; and
- near, middle, far, and limit distance bands.

The limit band must reach the corresponding declared UVC min/max. The other
bands retain normalized input distance from the stick center. Each case keeps
fresh frame metadata from the old session, monotonic progress in the requested
raw direction, a stable Stop window, and a restore to that case's origin. A
reconnect record must show the old binding stopped and suppressed before the
new session is ready. Near/middle/far rates are calculated from raw travel and
hold duration; the evaluator requires ordered input distances, nondecreasing
travel, and a bounded minimum far/near rate ratio.

The plan bounds each hold to 1.2 seconds and the whole run to 60 seconds. Its
decoder rebuilds the reviewed cases and stages and rejects changed limits or
execution flags. The model stores scalar metadata only and always keeps
`hardwareExecutionEnabled` and `cameraImagesStored` false.

## Developer collector

The bounded collector is exposed only through the development bridge route:

```text
pocket3 validation-usb-pan-tilt-stress \
  --device DEVICE-ID --session CAPTURE-SESSION-ID \
  --minimum-pan RAW --minimum-tilt RAW \
  --center-pan RAW --center-tilt RAW \
  --maximum-pan RAW --maximum-tilt RAW \
  --execute --hardware-validation
```

The default is a dry run. A dry run performs no status call and can omit the
range; supplying the six raw bounds prints the reviewed 16-case plan. An
executing request must include the exact device ID, capture session ID and all
six raw range values. The App verifies those values against a fresh UVC status
before the first write and rechecks them for every sample.

Execution uses the existing `CameraService` UVC owner and its raw absolute
target path. It runs pan and tilt in both directions at near, middle, far and
limit distances, collects fresh scalar frame metadata, sends an independent
Stop and waits for a stable readback, restores the center after every case,
reconnects and suppresses an old-session target, then restores center again.
Any failed or cancelled case receives fail-stop cleanup before the partial
scalar report is returned. The report stores no image bytes or paths and does
not claim calibrated physical angles or mechanical-stop performance.

The route is intentionally separate from Station/native gimbal control and
from the direct-UVC video work. A metrics pass is evidence for this bounded
raw test only; physical direction, endpoint behavior, Stop tail motion and
firmware coverage still require operator review before changing product
support status.

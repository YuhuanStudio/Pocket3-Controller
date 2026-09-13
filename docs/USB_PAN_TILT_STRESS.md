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

This commit adds no collector, UVC write, Wi-Fi path, image storage, or
physical-angle claim. A later developer-only collector must separately confirm
both directions, endpoint behavior, mechanical Stop tail motion, center
restore, disconnect handling, and old/new session exclusion before changing
product support status.

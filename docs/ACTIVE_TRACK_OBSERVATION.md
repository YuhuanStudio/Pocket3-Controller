# ActiveTrack passive observation

The developer route `validation-wireless-tracking-window-lifecycle` records
telemetry from the already selected and paired BLE peer. It never sends an
ActiveTrack command, reads credentials, joins Wi-Fi, saves images, or changes
BLE subscriptions. The existing one-shot
`validation-wireless-tracking-window` route remains available for a run whose
three timestamps are known in advance.

Use the lifecycle route when the operator will act during the window:

1. Start the window with the exact UUIDs shown by the current wireless status:

   ```text
   pocket3 validation-wireless-tracking-window-lifecycle \
     --action start --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID \
     --window 20 --hardware-validation
   ```

   Keep the returned `startedUptime`, `phase`, and `projection`. The route
   captures a fresh baseline before arming the existing bounded recorder.

2. When the operator observes the physical state, send one marker call for
   each action, in order: `off`, then `on`, then `off`.

   ```text
   pocket3 validation-wireless-tracking-window-lifecycle \
     --action marker --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID \
     --state off --hardware-validation
   ```

   Omitting `--at` stamps the marker at IPC receipt, so the operator does not
   need to predeclare a schedule. If an external monotonic timestamp is
   available, pass it with `--at UPTIME`; it is interpreted against the
   `startedUptime` returned by `start`.

3. Use `--action status` between markers to inspect `projection`. It reports
   the next legal marker, whether the recorder is active, bounded A5/A6/A89
   and `02/80` counts, and the exact session/peer fence.

4. After the final `off` marker, finish explicitly:

   ```text
   pocket3 validation-wireless-tracking-window-lifecycle \
     --action finish --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID \
     --hardware-validation
   ```

   A `completed` result means only that the passive window ended and its
   evidence was correlated. `eventsObserved` and typed readbacks remain
   separate from the operator markers; they do not prove that a tracking
   command was sent or that tracking was enabled.

Use `--action cancel` to close the recorder while retaining partial raw
telemetry and marker evidence. A changed BLE session, peer, or notification
route is reported as unavailable/connection-changed evidence rather than as a
successful no-event observation. The output is bounded by the existing
20-second/512-event recorder and the observation projection's 128 correlated
event cap.

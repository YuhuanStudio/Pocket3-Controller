# Osmo cross-device transport review

Updated 2026-09-11. This note separates portable protocol facts from commands
that must be captured on this Pocket 3 firmware before they can become product
features.

## Reusable evidence

| Finding | Source scope | Project action |
|---|---|---|
| Pocket 3 DUML commands use FFF5 write-without-response; telemetry is observed on FFF4. | Pocket 3 implementation/capture notes. | Keep the existing CoreBluetooth route; every setter still needs a Pocket 3 ACK and matching readback. |
| BLE message IDs are big-endian, unlike UDP datalink sequencing. | Multiple Osmo implementations. | Keep the current BLE DUML codec split; do not reuse UDP framing state for BLE confirmation. |
| Pocket 3 BLE advertisements may have no manufacturer data. | Two independent Pocket 3 BLE implementations, one tested from macOS. | Keep scanning by FFF0 service/local name; never add a manufacturer-data admission requirement. |
| Correctly formed BLE gimbal writes can still be silently ignored without an active Wi-Fi streaming state. | Pocket 3 BLE implementation report; not a Pocket 3 host-control guarantee. | Preserve BLE telemetry/read-only features, but do not present native gimbal buttons or retry ignored writes. |
| `camcap_video_codec`, `camcap_video_format`, and `cam_video_param_v2` are property names used by other Osmo sessions. | Osmosis media-protocol documentation. | Query only through the bounded 00/99 read path. Store opaque capability payloads until Pocket 3 captures establish a layout. |
| Wi-Fi streaming flows require a BLE pairing/wake path and joining the camera AP. | Pocket 3 BLE reference implementations. | Do not adopt: the product requirement preserves the Mac's existing network. |
| A Linux Pocket 3 HDMI pipeline reports 4K50 H.264 after direct UVC extraction with `libuvch264src`. | One third-party Linux project; transport-specific evidence, not a macOS result. | It supports direct UVC VS ownership as the high-frame-rate research route; it does not make macOS AVFoundation UYVY callbacks work. |
| Pocket 4 work found in public material treats native tracking as a camera-side feature until a firmware-specific host control path is proven. | Pocket 4 project planning, not a command specification. | Maintain the same boundary for Pocket 3: local analysis is not DJI ActiveTrack control. |

## Explicit non-transfers

- A command identifier, payload, BLE handle, pairing PIN, Wi-Fi credential, or
  response layout from another Osmo model is not Pocket 3 setter evidence.
- `camcap_video_codec` not replying during one BLE window is not evidence that
  the Pocket 3 lacks HEVC; the active `cam_video_param_v2` readback already
  reported HEVC.
- Direct UVC H.264 remains the primary route for H.264/4K webcam support.
  Camera-side codec selection cannot create a USB HEVC stream when the USB
  descriptor does not declare one.

## Next implementation gates

1. Complete direct UVC VideoStreaming-interface ownership and bounded bulk-pipe
   lifecycle before adding new codec controls.
2. Capture a Pocket 3-specific Mimo setting transition with consent before
   proposing any replacement for the rejected `02/AB` candidate.
3. Record user-marked native tracking off/on windows before introducing any
   ActiveTrack control surface.

## Sources

- yigitkonur, [lib-osmo-ble protocol reference](https://github.com/yigitkonur/lib-osmo-ble/blob/main/PROTOCOL.md), accessed 2026-09-11.
- triwav, [DJI Osmo Pocket 3 BLE protocol notes](https://github.com/triwav/dji-osmo-ble-protocol), accessed 2026-09-12.
- stephanebhiri, [Pocket 3 direct-UVC H.264 HDMI pipeline](https://github.com/stephanebhiri/DJI_OSMOPOCKET3_TO_HDMI_4K_60P_50P), accessed 2026-09-12.
- KonradIT, [Osmosis media protocol](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md), accessed 2026-09-11.
- FRAME-26, [Pocket 4 control research gate](https://github.com/FRAME-26/Homer_nero/blob/main/HOMER_MASTER_BUILD_PLAN.md), accessed 2026-09-11.

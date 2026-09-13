# Pocket 3 Controller documentation

English · [繁體中文](zh-Hant/README.md) · [简体中文](zh-Hans/README.md)

[Back to the product overview](../README.md)

The published download is **0.0.1 beta 2, build 24**. Later `main` changes may be newer. Start with the [release page](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.2)
for the capabilities and limitations of the version you installed.

## Using the app

Start with the [English usage guide](guide.md) for installation, permissions,
preview, controls, Bluetooth, local AI, MCP and troubleshooting.

| Document | What it covers |
|---|---|
| [Product overview and installation](../README.md) | Downloads, first launch, USB Webcam setup, local AI and MCP configuration |
| [Continuous gimbal control](CONTINUOUS_GIMBAL.md) | USB gesture behaviour, release / Stop handling and physical validation boundaries |
| [USB pan/tilt full-range stress](USB_PAN_TILT_STRESS.md) | Developer-only 16-case raw pan/tilt collector, scalar evidence and safety fences |
| [Bluetooth telemetry](BLUETOOTH_TELEMETRY.md) | Battery, charging, pose, freshness and device-association limits |
| [Camera settings protocol](CAMERA_SETTINGS_PROTOCOL.md) | Read-only lens, white-balance and exposure reports; protocol evidence does not imply working setters |
| [Camera body recording service](CAMERA_BODY_RECORDING.md) | Ordinary-Video start/stop and one legal format pair through the existing native owner |
| [Focus readback](FOCUS_READBACK.md) | What focus information is available and why app-side tap-to-focus remains unfinished |
| [Experimental USB Roll](USB_ROLL.md) | Raw device units, capability checks and the limited hardware acceptance |

## Development and verification

| Document | What it covers |
|---|---|
| [Current Pocket 3 support matrix](POCKET3_SUPPORT_MATRIX.md) | Single current-state source for body capability, App UI/API, read/write evidence, transport, release boundaries and next probes |
| [ActiveTrack coordinate gate](ACTIVE_TRACK_CALIBRATION.md) | Fixed source audit and local rotation/mirror calibration workflow before A6 writes |
| [Direct UVC H.264 backend plan](DIRECT_UVC_H264_PLAN.md) | Public-API ownership, UVC 1.0 negotiation, bulk payload assembly, VideoToolbox decoding and staged validation |
| [Osmo cross-device transport review](../research/2026-09-11/osmo-cross-device-transport.md) | Pocket 3/Pocket 4/other Osmo protocol comparisons, reusable boundaries and rejected shortcuts |
| [Contributing](../CONTRIBUTING.md) | Scope, reproducible changes, design consistency and hardware-test reporting |
| [Hardware acceptance record](HARDWARE_ACCEPTANCE.md) | Dated physical trials and the conditions under which they passed or failed |
| [AI validation](AI_VALIDATION.md) | Model evaluation, failure cases and the separation between simulated and physical camera actions |
| [Local visual AI research](AI_RESEARCH.md) | Model selection, grounding, tracking, VLA boundaries and measurable product priorities (Traditional Chinese) |
| [Reproducible grounding evaluation](../Evaluation/Grounding/README.md) | Public image metadata, explicit dataset preparation and independent schema/factual scoring |
| [Acceptance audit](ACCEPTANCE_AUDIT.md) | Earlier software gates and explicitly untested areas |
| [YunAudio parity](YUNAUDIO_PARITY.md) | Shared appearance and common app behaviour |
| [Device capability roadmap](DEVICE_CAPABILITY_ROADMAP.md) | Planned camera functions and the evidence needed before enabling them |
| [Current work list](../TODO.md) | Implementation and validation still in progress |

## Release, signing and data

| Document | What it covers |
|---|---|
| [Release workflow](RELEASE.md) | Source provenance, package verification, GitHub assets and signed-feed publication |
| [Beta 2 public verification](releases/0.0.1-beta.2-verification.json) | Exact source, public asset hashes, signed feed, update installation and remaining limits |
| [Local development signing](LOCAL_SIGNING.md) | Stable local signing identity; it is not Developer ID or notarization |
| [Test artifact policy](TEST_ARTIFACTS.md) | Temporary captures, preservation of reports and hash receipts for removed historical media |
| [Rights and third-party notices](../NOTICE.md) | The project's source rights and each dependency's licence |

The usage guide above is in English. The technical working documents linked in
the tables are currently mainly in Traditional Chinese and retain their original dates. Earlier design notes or matrices may use a previous
product name or describe an older state; they do not override the published
release scope. This index and the product README are available in all three
languages; it does not imply that every historical technical document is translated.

Private `artifacts/` and `research/` evidence directories are not shipped with the
public source. Historical links into those directories may therefore be unavailable.
Removed images are not recreated as if they were original evidence, and a cleanup
receipt does not constitute a new hardware test. The README gallery contains only
localized app interface captures, with no private camera photographs.

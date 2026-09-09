# Using Pocket 3 Controller

English · [繁體中文](zh-Hant/guide.md) · [简体中文](zh-Hans/guide.md)

[Documentation index](README.md) · [Product overview](../README.md)

This guide covers published **0.0.1 beta 1, build 9**; `main` is beta 2 development, build 21. The build 16 model routing below is a development addition, not a published beta 1 feature.
A disabled or experimental control is not a promise that its camera function is supported.

## Install and first launch

Download the DMG or ZIP from the [beta 1 release](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1)
and move **Pocket 3 Controller.app** into **Applications**. macOS 27 and Apple
Silicon are required. The release page also provides SHA-256 checksums.

The beta uses a local development certificate and is not Apple-notarized. If
macOS blocks the first launch, check the download's source, then use **System
Settings → Privacy & Security → Open Anyway** for that app. The project does not
provide a Homebrew cask. First-launch behaviour on every other Mac has not been verified.

Connect Pocket 3 by USB, choose **Webcam** on the camera, then select it and connect in the app. No Mac Wi-Fi change is needed.

## Access and privacy

The access selector controls what AI and external clients may do:

| Setting | Behaviour |
|---|---|
| **Manual only** | Default. Use the app's preview and manual controls; AI observation and actions are not granted. |
| **Observe only** | Allow image observation and questions, without granting camera movement. |
| **Observe and move** | Allow observation and eligible camera actions; each action still checks its capabilities and verification requirements. |

macOS camera access is requested when connecting. Microphone permission is needed
for audio use, and Bluetooth permission is requested when explicitly starting a
Bluetooth operation. If a permission was denied, change it in System Settings
before trying the corresponding operation again.

**Stop** cancels pending camera work and attempts the applicable hold operations.
**Privacy pause** stops the current work and releases capture inputs. Closing the
main window keeps the menu bar service running; **Quit** ends the service.
The menu bar icon opens the panel with a left click and its menu with a right click.

## Remote desktop and background use

The camera service has no physical-display-on requirement. The app must remain
running in the logged-in user's macOS session; the local CLI/MCP helper uses that
same user's service and does not start a system daemon before login. Remote
desktop input still depends on an accessible desktop and the app window receiving
the gesture. Display sleep, a locked desktop and system sleep are different states.

Development build 18 keeps an activity open while capture is running to prevent
idle system sleep and App Nap, without keeping the display on. Pause, disconnect
and capture teardown release it. An explicit system sleep still suspends the
camera; reconnect after waking. This is a development addition, not a beta 1 claim.
Actual Mac Studio remote-desktop, display-off and remote-disconnect input tests
remain pending; the build 17 external MCP zoom test ran with the display awake.

## USB preview and formats

Start with **1920 × 1080, NV12, 30 fps**, the beta smoke-test configuration.
Select another resolution, frame rate or input format and reconnect to apply it.
720p30 and 1080p24 also produced fresh frames; 4K30 NV12 has earlier bounded-trial
evidence. The format picker reflects device declarations, which do not prove that
every advertised combination will produce frames.

Portrait results depend on the camera's physical orientation and selected mode.
Earlier portrait trials passed after changing the body orientation; do not assume
that selecting a portrait resolution alone rotates the camera or enables all
native portrait modes. UYVY / H.264 paths and 4K60 do not have a passing capture
result. If no frames arrive, return to the tested 1080p30 NV12 combination.

The snapshot action captures a single image; CLI snapshots write to your explicit `--output` path.
A preview does not imply that the app records or controls all internal recording modes.

## Manual gimbal control

Hold a direction button or drag the joystick to move pan or tilt. Drag farther
from its centre to request faster movement. Release the input to stop the gesture;
losing focus and the Stop action also end it. Manual interaction takes priority
over AI work. These controls use USB position targets and retain the Mac's network.

Start with a small gesture and check the visible result. Physical speed, full
range and worst-case stopping latency are not calibrated. Stable readback after
Stop is software evidence, not mechanical emergency-stop certification. If the
app reports that stopping could not be confirmed, inspect the camera rather than
repeating the previous movement automatically.

Native rapid recenter and front/back flip remain in development; slow USB motion is not an equivalent.

## Zoom and experimental Roll

Use the Zoom slider or minus / plus buttons. Its percentage describes travel
within the reported control range, not optical magnification. The tested device
reported raw 100–400 with step 1; a 100 → 200 → 100 round trip was observed.
Other devices or sessions must use their own reported capabilities.

Roll is labelled **Experimental**. Its values are device control units, not a
calibrated physical angle. Only a 0 → 1 → 0 raw round trip has been verified;
physical direction and stopping during a larger adjustment remain under evaluation.
A successful zoom or pan test does not validate Roll.

## Bluetooth read-only status

Open the Bluetooth connection panel, scan explicitly, choose your camera and pair.
Confirm the pairing request on the camera when prompted. This workflow does not
join the Mac to a camera Wi-Fi network.

After pairing, the panel can show camera-reported battery, charging, pose, AF mode,
white balance and exposure. Use its read action to refresh the three camera-setting
values. Missing or stale readings are not treated as confirmed current values.
Low battery and a sustained downward trend are reported separately from charging.

These values are read-only. A Bluetooth peer is not automatically identified as
the selected USB camera, and BLE pose is not calibrated to USB coordinates.
The camera body can support tap-to-focus while app-side tap-to-focus is still
unavailable; an AF mode readback is not a focus-point setter.

## Local AI

Choose an engine on **AI engines and integration**. Apple Foundation Models need
the corresponding system model available. MLX Qwen 3.5 is optional: select its
download action and allow space for roughly 3.1 GB of model files. The download
requires a network connection; inference uses the locally available model.

### Build 16 development model routing

| Selection and access | Camera tools | Final answer |
|---|---|---|
| Apple, observation only | No movement or zoom; MLX is not required | Apple |
| Apple, eligible AI movement or zoom | Already-downloaded MLX runs the complete tool loop; the app obtains a fresh final frame | Apple answers the new frame |
| MLX | MLX runs its own permitted tools | MLX |

The combined route does not make Apple the camera tool executor. The app never
automatically downloads MLX: if the model is missing when control is available,
the UI explains what is needed. Download it explicitly, or switch to **Observe only**
to use Apple without MLX. Existing access, capability, cancellation and result
checks still apply; a controller role does not prove that an action happened.

Development response `metadata.executionRoles` identifies `controllerEngine=mlx`,
`answerEngine=apple` and `finalFrameRefresh=app` for this route. One live-camera
run completed in 38.039 seconds with all 11 checks passing. The MLX tool order was
`capture_frame → camera_zoom_status → camera_set_zoom → capture_frame`, with one
raw-200 zoom and verified readback. The app refreshed the final frame again before
Apple answered; this host refresh is not a fifth model or SDK tool call. Raw 100
and manual access were restored. This validates that bounded case, not every MCP
workflow or Apple independently controlling the camera. Published beta 1 remains
build 9; screenshots are versioned separately. See the [hardware record](HARDWARE_ACCEPTANCE.md).

Choose **Observe only** before asking about an image. OCR and barcode tools also
operate locally. Grant camera control only when that workflow is wanted; code
checks permissions and tool results independently of the model's wording.
Inspect uncertain answers, especially object counts or claims about completed actions.

## MCP and CLI

Keep the app running. Copy the MCP JSON from the integration page, or use the
[configuration in the README](../README.md#mcp-and-cli). The installed helper is
`/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3`; MCP uses `args: ["mcp"]`.
It connects to the app through a private local Unix socket and respects the access selector.

```sh
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' status
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' snapshot --output "$PWD/pocket3-frame.jpg"
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' ask --engine apple --question 'Read the visible label.'
```

For MCP zoom, obtain `camera_status.capture.sessionID`, pass it as
`expectedSessionID` to `camera_zoom_status`, and select an integer `rawValue`
on the reported minimum / maximum / step grid for `camera_set_zoom`.
Check `completed` and `verified`, then obtain a fresh frame. A cancelled or
unconfirmed action must not trigger an automatic sequence of retry movements.

## Troubleshooting and updates

| Symptom | Next step |
|---|---|
| Camera not listed | Check the USB data connection and select Webcam on the camera. |
| Camera listed but no preview | Check camera permission, close another capture app if it holds the device, and reconnect with 1080p30 NV12. |
| MCP image request denied | Keep the app connected and choose Observe only before requesting an image. |
| Model unavailable | Check the system model's availability or complete the optional MLX download. |
| AF, rapid recenter or flip unavailable | These are unfinished app capabilities; pairing alone does not enable them. |
| Battery is falling over time | Check the camera's own battery indication and power connection; USB configuration values are not current measurements. |
| Main window closed, camera still in use | Use Privacy pause to release capture, or Quit to end the service. |

Beta 1 uses this project's Sparkle configuration. The signed beta feed is now
public, and the publicly downloaded feed and ZIP passed public-key signature
verification. Manual downloads remain available from [GitHub Releases](https://github.com/YuhuanStudio/Pocket3-Controller/releases).
Installation and relaunch from one published version to a newer one have not yet
been verified. The development version on `main` is not a newer published download.

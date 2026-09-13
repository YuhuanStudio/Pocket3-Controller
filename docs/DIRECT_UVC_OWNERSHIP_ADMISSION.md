# Direct UVC ownership admission

The current Pocket 3 transport evidence has two separate facts:

- the AVFoundation UYVY/`2vuy` host path can be active while its input port
  remains `420v` and produces zero callbacks for the 4K60 host candidate; and
- the local descriptor artifact contains an H.264 `FORMAT_FRAME_BASED` entry
  for 3840×2160 with intervals `166666/200000/208333/333333/400000/416666`
  (60/50/48/30/25/24 fps), independent of the host UYVY alias. A read-only
  normal open of the candidate Video Streaming interface returned
  `kIOReturnExclusiveAccess` (`busy`) while the system camera owner was
  present.

These facts do not identify the same failure. A zero callback is classified as
host-output evidence. A normal open with `DirectUVCOpenStatus.busy` is
`blocked_by_system_owner`; the owner identity remains unknown because public
macOS APIs do not provide a safe way to release another process's
`VDCAssistant`/CoreMediaIO client. The existing normal-open bridge therefore
keeps the handle unclaimed and does not try a second transport.

`DirectUVCOwnershipAdmission` is a pure evaluator for this boundary. A request
binds the exact IORegistry location, VS interface, alternate setting, endpoint,
codec, input FourCC, dimensions, frame rate, and optional registry/boot
identity. Evidence records whether AVFoundation stopped and drained, whether a
normal open was attempted and owned, the scalar open observation, and any
host-output callback count. `expectedZeroCallbacks` is explicit, so the
separate UYVY/4K60 host trial can remain an expected zero-callback result while
an unexplained zero is reported as `unexpected_zero_callbacks`.

The only admissible next state is `ready_for_negotiation`. It keeps
`directStreamReady=false`: descriptor matching and a normal open do not prove
bulk bytes or decoded frames. The typed unblock conditions are:

1. stop the App's own AVFoundation graph and drain its callback queue;
2. observe a normal, owned VS open after the owner has released the interface;
3. match the candidate interface, alternate setting, bulk IN endpoint, and
   exact attachment identity from the post-open observation; and
4. review any future bounded negotiation independently while preserving the
   no-seize, no-alternate-setting-change, no-PROBE/COMMIT, and no-pipe-read
   boundary.

The evaluator returns `blocked_by_avfoundation_owner` when stop/drain evidence
is incomplete, `blocked_by_system_owner` for the observed busy open,
`blocked_by_invalid_evidence` for missing or mismatched identity/endpoint
facts, and `blocked_by_unsafe_operation` if forbidden operations are reported.
It never recommends killing a system service, seizing an interface, changing
an alternate setting, storing an image, or retrying blindly.

The descriptor candidate is not a missing-device-capability result. The
4K60/H.264 direct-stream blocker is the current macOS ownership/backend
boundary: the app has not obtained an owned VS interface with a safe bulk
reader. Generic public
implementations such as `daijertech/obs-dji-uvc@504452d` and
`BELABOX/gstlibuvch264src@1644b6d` use libuvc enumeration, stream-control
selection, and `uvc_start_streaming`; they are useful transport references but
do not prove that this macOS process may claim the Pocket 3 interface. The
descriptor endpoint address (currently recorded as a candidate) becomes scalar
evidence only after a normal open returns a matching observation; a busy open
provides no post-open endpoint properties.

This document and its fixtures do not execute hardware, open UVC, read a pipe,
or change the Mac network. Public Linux/UVC examples can explain generic
control shapes, but they do not replace the Pocket 3 ownership and callback
evidence above.

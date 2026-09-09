# Third-party source

`Sources/Pocket3UVC/UVCController.{h,m}`, `UVCType.{h,m}` and `UVCValue.{h,m}` are
from [jtfrey/uvc-util](https://github.com/jtfrey/uvc-util), commit
`8110da7025c95eea3096a7181af9a46c0cc7ac37` (MIT).
The original copyright headers and license are retained. `P3UVC.m` is this
project's small boundary wrapper. Upstream code uses manual reference counting.
For persistent app use, the cached control-name list now owns its array with
`copy`/`dispatch_once`, and a duplicate IORegistry release was removed.
The wrapper reads the documented 8-byte pan/tilt layout directly to avoid the
upstream field-pointer helper treating offset zero as invalid. It validates
JSON and catches Objective-C serialization exceptions before crossing into Swift.

Swift Package Manager dependencies and exact revisions are recorded in
`Package.resolved`; their licenses are included in the app by the packaging script.

## Yun design system

The user explicitly requested reuse of the unified YunAudio/YunUI design.
`Sources/YunDesign` is copied from YunAudio without visual-token changes.
Window chrome/frame integration is copied from YunAudio. Source file hashes are
recorded in `ThirdParty/YunDesign/PROVENANCE.json`. This app uses its own defaults
domain; it does not modify the YunAudio or YunUI repositories.

## Core AI detector

`Sources/CoreAIShared` and `Sources/CoreAIObjectDetector` are copied from Apple's
`coreai-models` at `df8119879f125ad1e2e4c6249c2cddded75c190a` (BSD-3-Clause).
The detector's public asynchronous methods are marked `nonisolated(nonsending)`
for Swift 6.4 caller-actor isolation; `PerceptionEngine` serialises operations.
The bundled YOLOS-tiny model is exported from `hustvl/yolos-tiny` (Apache-2.0)
using the upstream `models/yolo/export.py` with float16/static options.

## MLX bridge compatibility

MLX Swift LM is pinned to `e3d4a20e9e20e7b8ab39aded7bbfad4ae22c9438` to use the
macOS 27 Foundation Models integration. `Scripts/patch-dependencies.py` applies
one reproducible metadata-type compatibility patch for Xcode 27 beta. It
preserves JSON metadata using the library's Codable JSONValue; it does not
alter model weights, prompts or tool arguments.

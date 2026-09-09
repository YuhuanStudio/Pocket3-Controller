# Contributing to Pocket 3 Controller

Start with the [product overview](README.md) and [documentation index](docs/README.md).
The published beta 1 is tagged `v0.0.1-beta.1`; `main` contains beta 2 development.
Discuss a new camera capability with its intended user interaction and the evidence
available for the relevant firmware and transport.

Keep changes focused. Describe the trigger, resulting behaviour and checks run.
For UI work, preserve the shared YunAudio / YunUI controls and inspect English,
Traditional Chinese and Simplified Chinese layouts. Documentation screenshots
must contain app UI only, with the camera disconnected; do not submit private
camera photographs, device identifiers or traffic captures.

For device control, preserve session and attachment checks, command cancellation,
exclusive ownership and Stop handling. A command being submitted or acknowledged
is not proof that the mechanism reached its target. Distinguish software tests,
simulated-camera tests and actual hardware trials, and record what remains untested.
Do not introduce a workflow that silently moves the Mac onto the camera's Wi-Fi.

Run checks appropriate to the change. `./Scripts/verify.sh` runs the default software
gate; the full `--release --ui --models --package` gate relaunches the app and needs
the optional local MLX model prepared in advance. Hardware trials require an
explicit, bounded procedure and restoration / Stop checks. See the [test artifact
policy](docs/TEST_ARTIFACTS.md) before retaining or sharing their output.

Never commit signing keys, credentials, local model caches or private diagnostics.
Keep published tags and asset bytes immutable. Dependency licences do not assign
a licence to this project's own source; consult [NOTICE.md](NOTICE.md) before
reusing code or proposing changes with new third-party material.

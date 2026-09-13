# ActiveTrack coordinate gate

The source audit for the next Pocket 3 writer uses these fixed revisions:

| Source | Revision | Result |
|---|---|---|
| [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine/tree/9b30b93572797c94db5ad9236fb746410f8d761f) | `9b30b93572797c94db5ad9236fb746410f8d761f` | Confirms `02/A6` set (`01 00 00`, little-endian ID, four little-endian float fields), all-zero 21-byte clear, `02/A5` poll, and `02/89` center/size parsing. |
| [Kaze for DJI](https://github.com/brianmerchant/Kaze-for-DJI/tree/341a35de18493ff61f97c93b8b10161a7512aa36) | `341a35de18493ff61f97c93b8b10161a7512aa36` | Does not provide an independent Pocket 3 A5/A6/A89 coordinate or rotation/mirror proof. |

The packet shape is therefore sufficient for a pure coordinator, but it is not
enough to unlock a Pocket 3 writer. OpenPocketCine's tracking implementation
uses normalized feed coordinates and its captured support matrix is different;
it does not prove how this app's portrait or mirrored display maps onto a
Pocket 3 camera coordinate system.

`NativeActiveTrackCalibrationWorkflow` records at least three asymmetric local
touch points paired with the camera-reported points. It fits only the eight
explicit rotation/mirror transforms, rejects arbitrary affine mappings, and
returns residuals plus the exact session, peer and generation. A caller may
feed its `validationCalibration` into the existing A6 validator only after the
result is `verified`; an unverified or stale result remains execute-blocked.
The workflow performs no Bluetooth, Station, or A6 I/O.

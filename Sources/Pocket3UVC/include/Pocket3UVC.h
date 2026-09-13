#ifndef POCKET3_UVC_H
#define POCKET3_UVC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Returned UTF-8 JSON strings are owned by the caller. Always p3_uvc_free them.
typedef struct P3UVCSession P3UVCSession;
typedef struct P3UVCStreamSession P3UVCStreamSession;
// Sessions own one attachment's controller and cached controls. Calls on the
// same session must be serialized. Close exactly once after all calls finish.
// open sets *outSession only on success; the caller owns the returned session.
char *p3_uvc_session_open(uint32_t location, P3UVCSession **outSession);
char *p3_uvc_session_status(P3UVCSession *session);
char *p3_uvc_session_set_position(P3UVCSession *session, int32_t pan, int32_t tilt);
// Full paired target; uses cached validated bounds, preserves exact raw units,
// and sends one 8-byte SET_CUR with no GET_CUR. Caller must apply its operation
// permit immediately around this serialized call (as for the legacy setter).
// 100 ms bounds the IOKit request, NOT attachment checks, interface open/close,
// caller scheduling, or mechanical stopping. No hard real-time guarantee.
enum { P3_UVC_FAST_REQUEST_TIMEOUT_MS = 100 };
char *p3_uvc_session_set_position_fast(P3UVCSession *session, int32_t pan, int32_t tilt);
// Zoom is an unsigned 16-bit UVC raw value, with no asserted optical ratio.
// Reads use the normal request timeout; set is one 2-byte request with the
// fast timeout and cached bounds/step checks. Same session/permit contract.
char *p3_uvc_session_zoom_status(P3UVCSession *session);
char *p3_uvc_session_set_zoom(P3UVCSession *session, uint32_t rawValue);
// Roll uses signed 16-bit device raw units, not calibrated physical angles.
// Status includes cached GET_DEF as defaultValue when available. SET requires
// validated bounds and a known positive step; no rounding or preceding GET.
char *p3_uvc_session_roll_status(P3UVCSession *session);
char *p3_uvc_session_set_roll(P3UVCSession *session, int32_t rawValue);
void p3_uvc_session_close(P3UVCSession *session);
// One-shot location wrappers retained for C/CLI compatibility.
char *p3_uvc_devices(void);
// Read-only IORegistry inventory. Does not create a UVCController, open an
// interface, claim a pipe, or issue any USB request.
char *p3_uvc_stream_interfaces(uint32_t location);
// Opt-in VideoStreaming interface lifecycle diagnostic. It attempts a normal
// open of VS interface 1 and immediately closes it on success. It never
// seizes, changes alt setting, sends a UVC request, claims a pipe, or reads
// payload bytes. Exclusive access is reported as busy.
char *p3_uvc_stream_open_diagnostic(uint32_t location);
// Retained VideoStreaming interface lifecycle boundary. It performs one
// normal USBInterfaceOpen for the requested VS interface/alternate/endpoint
// and never seizes or changes the alternate setting. The retained session may
// issue the reviewed VS controls and use the selected bulk pipe through the
// functions below. Close consumes the session exactly once, including after
// detach.
char *p3_uvc_stream_session_open(uint32_t location, uint8_t interfaceNumber,
                                  uint8_t alternateSetting, uint8_t endpointAddress,
                                  P3UVCStreamSession **outSession);
char *p3_uvc_stream_session_status(P3UVCStreamSession *session);
char *p3_uvc_stream_session_close(P3UVCStreamSession *session);
// UVC VideoStreaming class-interface controls over the already-owned normal
// open. These functions never seize, change the alternate setting, or open a
// second interface. Returned JSON owns a bounded base64 `data` string; callers
// must p3_uvc_free the returned value.
char *p3_uvc_stream_session_control(P3UVCStreamSession *session,
                                    uint8_t bmRequestType, uint8_t bRequest,
                                    uint16_t wValue, uint16_t wIndex,
                                    const uint8_t *payload, uint16_t length,
                                    uint32_t timeoutMilliseconds);
// One bounded synchronous bulk-IN completion from the endpoint selected at
// normal open (Pocket 3 direct H.264 uses descriptor-confirmed 0x82).
char *p3_uvc_stream_session_read_bulk(P3UVCStreamSession *session,
                                      uint8_t endpointAddress,
                                      uint32_t maximumBytes,
                                      uint32_t noDataTimeoutMilliseconds,
                                      uint32_t completionTimeoutMilliseconds);
// Abort only the selected owned bulk pipe. This is used by cancellation before
// the normal close fence; it never terminates a foreign owner.
char *p3_uvc_stream_session_abort_bulk(P3UVCStreamSession *session,
                                       uint8_t endpointAddress);
char *p3_uvc_status(uint32_t location);
char *p3_uvc_set_position(uint32_t location, int32_t pan, int32_t tilt, const char *expectedRegistryID);
void p3_uvc_free(char *value);
// No hardware access: exercises cache lifetime and JSON exception boundary.
int p3_uvc_contract_selftest(void);
#ifdef __cplusplus
}
#endif
#endif

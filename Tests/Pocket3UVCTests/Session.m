// Hardware-free retained-session acceptance against actual vendor + bridge code.
#define main unused_ownership_main
#include "Ownership.m"
#undef main

static uint64_t currentRegistryID = 1;
static const char *currentBoot = "boot-one";
static int sessionControllersCreated = 0, sessionReads = 0, sessionWrites = 0;
static int fastWrites = 0;
static IOReturn fastWriteResult = kIOReturnSuccess;
static uint16_t currentZoom = 100;
static int zoomWrites = 0;
static int16_t currentRoll = -20;
static int rollWrites = 0;
static int32_t currentPan = 0, currentTilt = -32400;
static BOOL omitPanTilt = NO;
static BOOL allowSet = YES, omitRange = NO;
static BOOL allowGet = YES, omitRoll = NO, wrongRollCurrentSize = NO, wrongRollRangeSize = NO, missingRollStep = NO;
static IMP originalCurrentValue, originalMinimum, originalStepSize;
static CFTypeRef SessionProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    return FakeProperty(entry, NULL, key, allocator, options);
}
static kern_return_t SessionRegistryID(io_registry_entry_t entry, uint64_t *value) {
    assert(entry == fakeService && serviceReferences > 0); *value = currentRegistryID; return KERN_SUCCESS;
}
static int SessionSysctl(const char *name, void *old, size_t *oldLength, void *newValue, size_t newLength) {
    assert(strcmp(name, "kern.bootsessionuuid") == 0 && newValue == NULL && newLength == 0);
    assert(*oldLength >= strlen(currentBoot) + 1);
    strcpy(old, currentBoot); *oldLength = strlen(currentBoot) + 1; return 0;
}
#define IORegistryEntryCreateCFProperty SessionProperty
#define IORegistryEntryGetRegistryEntryID SessionRegistryID
#define sysctlbyname SessionSysctl
#include "../../Sources/Pocket3UVC/P3UVC.m"

static BOOL SessionFindInterface(id object, SEL selector, io_service_t service) {
    sessionControllersCreated++; return FakeFindInterface(object, selector, service);
}
static BOOL SessionCapabilities(id object, SEL selector, NSUInteger *capabilities, NSUInteger control) {
    if (omitPanTilt && control == [object controlIndexForString:@"pan-tilt-abs"]) return NO;
    if (omitRoll && control == [object controlIndexForString:@"roll-abs"]) return NO;
    BOOL result = FakeCapabilities(object, selector, capabilities, control);
    if (!allowSet) *capabilities &= ~kUVCControlSupportsSet;
    if (!allowGet) *capabilities &= ~kUVCControlSupportsGet;
    return result;
}
static void SessionRange(id object, SEL selector, UVCValue **low, UVCValue **high, UVCValue **step, UVCValue **standard, NSUInteger *capabilities, NSUInteger control) {
    if (omitRange) { *low = nil; *high = nil; *step = nil; *standard = nil; return; }
    [*low retain]; [*high retain]; [*step retain]; [*standard retain];
    if (control == [object controlIndexForString:@"pan-tilt-abs"]) {
        assert([*low scanCString:"{pan=-126000,tilt=-324000}" flags:0]);
        assert([*high scanCString:"{pan=774000,tilt=324000}" flags:0]);
        assert([*step scanCString:"{pan=3600,tilt=3600}" flags:0]);
        assert([*standard scanCString:"{pan=0,tilt=-32400}" flags:0]);
    } else if (control == [object controlIndexForString:@"zoom-abs"]) {
        uint16_t min = 100, max = 400, stepValue = 10, defaultValue = 100;
        memcpy([*low valuePtr], &min, 2); memcpy([*high valuePtr], &max, 2);
        memcpy([*step valuePtr], &stepValue, 2); memcpy([*standard valuePtr], &defaultValue, 2);
    } else if (control == [object controlIndexForString:@"roll-abs"]) {
        int16_t min = -120, max = 86, stepValue = 2, defaultValue = -12;
        memcpy([*low valuePtr], &min, 2); memcpy([*high valuePtr], &max, 2);
        memcpy([*step valuePtr], &stepValue, 2); memcpy([*standard valuePtr], &defaultValue, 2);
    }
}
static BOOL SessionRead(id object, SEL selector, UVCValue *value, NSUInteger control) {
    sessionReads++;
    if (control == [object controlIndexForString:@"pan-tilt-abs"])
        return exactPosition(value, currentPan, currentTilt);
    if (control == [object controlIndexForString:@"zoom-abs"])
        memcpy([value valuePtr], &currentZoom, 2);
    if (control == [object controlIndexForString:@"roll-abs"])
        memcpy([value valuePtr], &currentRoll, 2);
    return YES;
}
static BOOL SessionWrite(id object, SEL selector, UVCValue *value, NSUInteger control) {
    assert(control == [object controlIndexForString:@"pan-tilt-abs"]);
    sessionWrites++; return pair(value, &currentPan, &currentTilt);
}
static IOReturn SessionFastWrite(id object, SEL selector, int32_t pan, int32_t tilt, UInt32 timeout) {
    assert(timeout == 100); fastWrites++;
    if (fastWriteResult == kIOReturnSuccess) { currentPan = pan; currentTilt = tilt; }
    return fastWriteResult;
}
static IOReturn SessionZoomWrite(id object, SEL selector, uint16_t value, UInt32 timeout) {
    assert(timeout == 100); zoomWrites++; currentZoom = value; return kIOReturnSuccess;
}
static IOReturn SessionRollWrite(id object, SEL selector, int16_t value, UInt32 timeout) {
    assert(timeout == 100); rollWrites++; currentRoll = value; return kIOReturnSuccess;
}
static UVCValue *SessionCurrentValue(id object, SEL selector) {
    if (wrongRollCurrentSize && [[object controlName] isEqual:@"roll-abs"])
        return [UVCValue uvcValueWithType:[UVCType uvcTypeWithCString:"{S1}"]];
    return ((UVCValue *(*)(id, SEL))originalCurrentValue)(object, selector);
}
static UVCValue *SessionMinimum(id object, SEL selector) {
    if (wrongRollRangeSize && [[object controlName] isEqual:@"roll-abs"])
        return [UVCValue uvcValueWithType:[UVCType uvcTypeWithCString:"{S4}"]];
    return ((UVCValue *(*)(id, SEL))originalMinimum)(object, selector);
}
static UVCValue *SessionStepSize(id object, SEL selector) {
    if (missingRollStep && [[object controlName] isEqual:@"roll-abs"]) return nil;
    return ((UVCValue *(*)(id, SEL))originalStepSize)(object, selector);
}
static NSDictionary *result(char *raw) {
    assert(raw != NULL);
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)]; p3_uvc_free(raw);
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    assert([value isKindOfClass:[NSDictionary class]]); return value;
}

int main(void) {
    @autoreleasepool {
        replace([UVCController class], @selector(findControllerInterfaceForServiceObject:), (IMP)SessionFindInterface);
        replace([UVCController class], @selector(capabilities:forControl:), (IMP)SessionCapabilities);
        replace([UVCController class], @selector(getLowValue:highValue:stepSize:defaultValue:updateCapabilitiesBitmask:forControl:), (IMP)SessionRange);
        replace([UVCController class], @selector(getValue:forControl:), (IMP)SessionRead);
        replace([UVCController class], @selector(setValue:forControl:), (IMP)SessionWrite);
        replace([UVCController class], @selector(writePanTiltAbsolutePan:tilt:requestTimeoutMilliseconds:), (IMP)SessionFastWrite);
        replace([UVCController class], @selector(writeZoomAbsolute:requestTimeoutMilliseconds:), (IMP)SessionZoomWrite);
        replace([UVCController class], @selector(writeRollAbsolute:requestTimeoutMilliseconds:), (IMP)SessionRollWrite);
        originalCurrentValue = replace([UVCControl class], @selector(currentValue), (IMP)SessionCurrentValue);
        originalMinimum = replace([UVCControl class], @selector(minimum), (IMP)SessionMinimum);
        originalStepSize = replace([UVCControl class], @selector(stepSize), (IMP)SessionStepSize);
        originalControllerDealloc = replace([UVCController class], @selector(dealloc), (IMP)CountControllerDealloc);
        originalControlDealloc = replace([UVCControl class], @selector(dealloc), (IMP)CountControlDealloc);
        P3UVCSession *session = NULL;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue] && session != NULL);
        const int retainedControls = (int)session->controls.count;
        for (int i = 0; i < 1000; i++) {
            @autoreleasepool {
                NSDictionary *status = result(p3_uvc_session_status(session));
                assert(status[@"error"] == nil && [status[@"position"][@"pan"] intValue] == currentPan);
                assert(sessionControllersCreated == 1 && controllerDeallocations == 0 && controlDeallocations == 0);
            }
        }
        assert(sessionReads == 1000);
        assert([result(p3_uvc_session_set_position(session, 6120, -29880))[@"sent"] boolValue]);
        assert(sessionWrites == 1 && currentPan == 6120 && currentTilt == -29880);
        assert([result(p3_uvc_session_set_position(session, 774001, -29880))[@"error"] isEqual:@"uvc_out_of_range"]);
        assert(sessionWrites == 1);
        int readsBefore = sessionReads;
        assert([result(p3_uvc_session_set_position_fast(session, 6119, -29881))[@"sent"] boolValue]);
        assert(fastWrites == 1 && sessionReads == readsBefore && currentPan == 6119 && currentTilt == -29881);
        assert([result(p3_uvc_session_set_position_fast(session, 774001, -29880))[@"error"] isEqual:@"uvc_out_of_range"]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, -324001))[@"error"] isEqual:@"uvc_out_of_range"]);
        UVCControl *pt = session->controls[@"pan-tilt-abs"];
        assert([[pt maximum] scanCString:"{pan=-126001,tilt=324000}" flags:0]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_control_unavailable"]);
        assert(fastWrites == 1 && sessionReads == readsBefore);
        assert([[pt maximum] scanCString:"{pan=774000,tilt=324000}" flags:0]);
        fastWriteResult = kIOUSBTransactionTimeout;
        NSDictionary *timeout = result(p3_uvc_session_set_position_fast(session, 0, 0));
        assert([timeout[@"error"] isEqual:@"uvc_request_timeout"] && [timeout[@"requestTimeoutMilliseconds"] intValue] == 100);
        assert(fastWrites == 2 && sessionReads == readsBefore && currentPan == 6119);
        fastWriteResult = kIOReturnError;
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_write_failed"]);
        assert(fastWrites == 3 && sessionReads == readsBefore);
        fastWriteResult = kIOReturnSuccess;
        NSDictionary *zoom = result(p3_uvc_session_zoom_status(session));
        assert([zoom[@"current"] intValue] == 100 && [zoom[@"minimum"] intValue] == 100);
        assert([zoom[@"maximum"] intValue] == 400 && [zoom[@"step"] intValue] == 10 && [zoom[@"writable"] boolValue]);
        readsBefore = sessionReads;
        assert([result(p3_uvc_session_set_zoom(session, 110))[@"sent"] boolValue]);
        assert(currentZoom == 110 && zoomWrites == 1 && sessionReads == readsBefore);
        assert([result(p3_uvc_session_set_zoom(session, 111))[@"error"] isEqual:@"uvc_zoom_step_mismatch"]);
        assert([result(p3_uvc_session_set_zoom(session, 401))[@"error"] isEqual:@"uvc_zoom_out_of_range"]);
        assert([result(p3_uvc_session_set_zoom(session, 65536))[@"error"] isEqual:@"uvc_zoom_out_of_range"]);
        assert(zoomWrites == 1 && sessionReads == readsBefore);
        NSDictionary *roll = result(p3_uvc_session_roll_status(session));
        assert([roll[@"current"] intValue] == -20 && [roll[@"minimum"] intValue] == -120);
        assert([roll[@"maximum"] intValue] == 86 && [roll[@"step"] intValue] == 2 && [roll[@"writable"] boolValue]);
        assert([roll[@"defaultValue"] intValue] == -12); // Actual GET_DEF, never a hard-coded zero.
        readsBefore = sessionReads;
        assert([result(p3_uvc_session_set_roll(session, -18))[@"sent"] boolValue]);
        assert(currentRoll == -18 && rollWrites == 1 && sessionReads == readsBefore);
        assert([result(p3_uvc_session_set_roll(session, -120))[@"sent"] boolValue]);
        assert([result(p3_uvc_session_set_roll(session, 86))[@"sent"] boolValue]);
        assert(currentRoll == 86 && rollWrites == 3 && sessionReads == readsBefore);
        for (int32_t invalid = -122; invalid <= 88; invalid += 210)
            assert([result(p3_uvc_session_set_roll(session, invalid))[@"error"] isEqual:@"uvc_roll_out_of_range"]);
        assert([result(p3_uvc_session_set_roll(session, INT32_MIN))[@"error"] isEqual:@"uvc_roll_out_of_range"]);
        assert([result(p3_uvc_session_set_roll(session, INT32_MAX))[@"error"] isEqual:@"uvc_roll_out_of_range"]);
        assert([result(p3_uvc_session_set_roll(session, -19))[@"error"] isEqual:@"uvc_roll_step_mismatch"]);
        UVCControl *rollControl = session->controls[@"roll-abs"];
        int16_t stepValue = 0;
        memcpy([[rollControl stepSize] valuePtr], &stepValue, 2);
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_step_unavailable"]);
        stepValue = -2; memcpy([[rollControl stepSize] valuePtr], &stepValue, 2);
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_step_unavailable"]);
        missingRollStep = YES;
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_step_unavailable"]);
        missingRollStep = NO; stepValue = 2; memcpy([[rollControl stepSize] valuePtr], &stepValue, 2);
        wrongRollRangeSize = YES;
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_limits_unavailable"]);
        wrongRollRangeSize = NO; wrongRollCurrentSize = YES;
        assert([result(p3_uvc_session_roll_status(session))[@"error"] isEqual:@"uvc_roll_read_failed"]);
        wrongRollCurrentSize = NO;
        assert(rollWrites == 3 && sessionReads == readsBefore);
        currentRegistryID = 2;
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_roll_status(session))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(rollWrites == 3 && sessionReads == readsBefore);
        assert([result(p3_uvc_session_set_zoom(session, 120))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_zoom_status(session))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(zoomWrites == 1 && sessionReads == readsBefore);
        assert([result(p3_uvc_session_status(session))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_set_position(session, 0, 0))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(fastWrites == 3);
        assert(sessionReads == readsBefore && sessionWrites == 1);
        currentRegistryID = 1; // A failed session remains invalid even if the ID is replayed.
        assert([result(p3_uvc_session_status(session))[@"error"] isEqual:@"uvc_attachment_changed"]);
        p3_uvc_session_close(session); session = NULL;
        assert(controllerDeallocations == 1 && controlDeallocations == retainedControls);
        assert(serviceReferences == 0 && iteratorReferences == 0);

        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue]);
        currentBoot = "boot-two";
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_set_position(session, 0, 0))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(sessionWrites == 1);
        p3_uvc_session_close(session); session = NULL;
        assert(controllerDeallocations == 2 && controlDeallocations == retainedControls * 2);

        // Fast writes require both cached writable capability and valid ranges.
        allowSet = NO;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue]);
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_read_only"]);
        assert([result(p3_uvc_session_set_zoom(session, 100))[@"error"] isEqual:@"uvc_zoom_read_only"]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_control_unavailable"]);
        p3_uvc_session_close(session); session = NULL; allowSet = YES;
        omitRange = YES;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue]);
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_limits_unavailable"]);
        assert([result(p3_uvc_session_set_zoom(session, 100))[@"error"] isEqual:@"uvc_zoom_limits_unavailable"]);
        assert([result(p3_uvc_session_set_position_fast(session, 0, 0))[@"error"] isEqual:@"uvc_control_unavailable"]);
        p3_uvc_session_close(session); session = NULL; omitRange = NO;
        assert([result(p3_uvc_session_set_position_fast(NULL, 0, 0))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(fastWrites == 3 && sessionReads == readsBefore);

        allowGet = NO;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue]);
        assert([result(p3_uvc_session_roll_status(session))[@"error"] isEqual:@"uvc_roll_not_readable"]);
        p3_uvc_session_close(session); session = NULL; allowGet = YES;
        omitRoll = YES;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"opened"] boolValue]);
        assert([result(p3_uvc_session_roll_status(session))[@"error"] isEqual:@"uvc_roll_unavailable"]);
        assert([result(p3_uvc_session_set_roll(session, -18))[@"error"] isEqual:@"uvc_roll_unavailable"]);
        p3_uvc_session_close(session); session = NULL; omitRoll = NO;
        assert(rollWrites == 3 && sessionReads == readsBefore);

        // Failed opens close all partial ownership and never publish a pointer.
        omitPanTilt = YES;
        assert([result(p3_uvc_session_open(0x01100000, &session))[@"error"] isEqual:@"uvc_control_unavailable"]);
        assert(session == NULL && sessionControllersCreated == controllerDeallocations);
        assert(serviceReferences == 0 && iteratorReferences == 0);
        omitPanTilt = NO;
        assert(result(p3_uvc_status(0x01100000))[@"error"] == nil);
        assert(sessionControllersCreated == controllerDeallocations);
        assert([result(p3_uvc_set_position(0x01100000, 0, 0, "wrong-attachment"))[@"error"] isEqual:@"uvc_attachment_changed"]);
        assert(sessionWrites == 1);
        assert(p3_uvc_contract_selftest() == 1);
        printf("{\"passed\":true,\"statusCalls\":1000,\"controllersDuringReuse\":1,\"exactHoldPreserved\":true,\"reattachmentBlocksReadsAndWrites\":true,\"bootChangeBlocksWrites\":true,\"invalidatedSessionCannotRecover\":true,\"failedOpenOwnershipBalanced\":true,\"oneShotWrappersCompatible\":true,\"controllersCreated\":%d,\"controllersReleased\":%d,\"serviceReferencesRemaining\":%d,\"fastWriterNoGetCur\":true,\"fastWriterCachedCapabilityAndRangeRequired\":true,\"fastTimeoutClassified\":true,\"rollCachedBoundsStepAndDefault\":true,\"rollNoGetBeforeSet\":true,\"rollSignedSizeAndAttachmentRejection\":true,\"hardwareAccess\":false}\n", sessionControllersCreated, controllerDeallocations, serviceReferences);
    }
    return 0;
}

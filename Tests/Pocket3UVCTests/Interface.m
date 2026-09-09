// Real controller open/request/close methods with a fake IOUSBInterface table.
// This does not enumerate devices, create an IOKit user client, or access USB.
#import "UVCController.h"
#include <assert.h>
#include "../../Sources/Pocket3UVC/UVCController.m"

typedef struct {
    IOUSBInterfaceInterface220 *interface;
    IOUSBInterfaceInterface220 methods;
    IOReturn openResult, requestResult, closeResult;
    int opens, requests, closes, releases;
    BOOL owned, foreignOpen, raisesRequest, shortRequest;
    IOUSBDevRequestTO lastRequest;
    uint8_t lastBytes[8];
} FakeInterface;

static IOReturn Open(void *reference) {
    FakeInterface *fake = reference; fake->opens++;
    if (fake->openResult == kIOReturnSuccess) { assert(!fake->owned); fake->owned = YES; }
    if (fake->openResult == kIOReturnExclusiveAccess) fake->foreignOpen = YES;
    return fake->openResult;
}
static IOReturn Close(void *reference) {
    FakeInterface *fake = reference; fake->closes++;
    // Closing a borrowed interface is the original ownership bug.
    assert(fake->owned && !fake->foreignOpen);
    if (fake->closeResult == kIOReturnSuccess || fake->closeResult == kIOReturnNotOpen || fake->closeResult == kIOReturnNoDevice)
        fake->owned = NO;
    return fake->closeResult;
}
static IOReturn Request(void *reference, UInt8 pipe, IOUSBDevRequestTO *request) {
    FakeInterface *fake = reference; fake->requests++;
    assert(fake->owned || fake->foreignOpen);
    assert(pipe == 0 && (request->wLength == 8 || request->wLength == 2));
    assert(request->noDataTimeout > 0 && request->completionTimeout > 0);
    fake->lastRequest = *request;
    memset(fake->lastBytes, 0, sizeof(fake->lastBytes));
    memcpy(fake->lastBytes, request->pData, request->wLength);
    request->wLenDone = fake->shortRequest ? request->wLength - 1 : request->wLength;
    if (fake->raisesRequest) [NSException raise:@"TestRequestException" format:@"Exercise request cleanup"];
    return fake->requestResult;
}
static ULONG Release(void *reference) {
    FakeInterface *fake = reference; fake->releases++;
    fake->owned = NO; // Destroying our user-client reference cannot close a foreign open.
    return 0;
}
static void prepare(FakeInterface *fake, IOReturn openResult, IOReturn requestResult, IOReturn closeResult) {
    memset(fake, 0, sizeof(*fake));
    fake->interface = &fake->methods;
    fake->methods.USBInterfaceOpen = Open;
    fake->methods.USBInterfaceClose = Close;
    fake->methods.ControlRequestTO = Request;
    fake->methods.Release = Release;
    fake->openResult = openResult; fake->requestResult = requestResult; fake->closeResult = closeResult;
}

@interface InterfaceTestController : UVCController
- (id)initWithFake:(FakeInterface *)fake;
- (void)configurePanTilt:(BOOL)available;
- (void)enableRoll;
@end
@implementation InterfaceTestController
- (id)initWithFake:(FakeInterface *)fake {
    if ((self = [super init])) _controllerInterface = &fake->interface;
    return self;
}
- (void)configurePanTilt:(BOOL)available {
    _hasCameraTerminalDescriptor = available;
    _videoInterfaceIndex = 7;
    [_unitIds release]; _unitIds = [@{@"UVC_INPUT_TERMINAL_ID":@9} mutableCopy];
    const uint8_t capabilities[] = {0x00, 0x0a, 0x00}; // CT pan/tilt bit 11, zoom absolute bit 9.
    [_terminalControlsAvailable release];
    _terminalControlsAvailable = [[NSData alloc] initWithBytes:capabilities length:sizeof(capabilities)];
}
- (void)enableRoll {
    const uint8_t capabilities[] = {0x00, 0x2a, 0x00}; // Add CT roll absolute bit 13.
    [_terminalControlsAvailable release];
    _terminalControlsAvailable = [[NSData alloc] initWithBytes:capabilities length:sizeof(capabilities)];
}
@end

static BOOL send(UVCController *controller) {
    uint8_t bytes[8] = {0};
    IOUSBDevRequest request = {.bmRequestType=0x21, .bRequest=1, .wValue=0x0d00,
                              .wIndex=0x0100, .wLength=8, .pData=bytes};
    return [controller sendControlRequest:request];
}

int main(void) {
    @autoreleasepool {
        int cases = 0;
        FakeInterface fake;

        CFUUIDRef expectedID = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("770DE60C-2FE8-11D8-A582-000393DCB1D0"));
        assert(CFEqual(P3UVCInterfaceID(), expectedID)); CFRelease(expectedID);
        assert(!CFEqual(P3UVCInterfaceID(), kIOUSBInterfaceInterfaceID100)); cases++;

        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        UVCController *controller = [[InterfaceTestController alloc] initWithFake:&fake];
        for (int i = 1; i <= 20; i++) {
            assert(send(controller));
            assert(fake.opens == i && fake.requests == i && fake.closes == i);
            assert(![controller isInterfaceOpen] && !fake.owned);
            assert(fake.lastRequest.noDataTimeout == 1000 && fake.lastRequest.completionTimeout == 1000);
        }
        [controller release]; assert(fake.closes == 20 && fake.releases == 1); cases++;

        prepare(&fake,kIOReturnSuccess,kIOReturnError,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        assert(!send(controller)); assert(fake.opens == 1 && fake.requests == 1 && fake.closes == 1);
        assert(![controller isInterfaceOpen]);
        [controller release]; assert(fake.closes == 1 && fake.releases == 1); cases++;

        for (int successful = 0; successful < 2; successful++) {
            prepare(&fake,kIOReturnExclusiveAccess,successful ? kIOReturnSuccess : kIOReturnError,kIOReturnSuccess);
            controller = [[InterfaceTestController alloc] initWithFake:&fake];
            for (int i = 1; i <= 3; i++) {
                assert(send(controller) == successful);
                assert(![controller isInterfaceOpen] && fake.opens == i && fake.requests == i);
                assert(fake.closes == 0 && fake.foreignOpen);
            }
            [controller release]; assert(fake.closes == 0 && fake.releases == 1 && fake.foreignOpen); cases++;
        }

        prepare(&fake,kIOReturnNotOpen,kIOReturnSuccess,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        assert(!send(controller)); assert(![controller isInterfaceOpen]);
        assert(fake.opens == 1 && fake.requests == 0 && fake.closes == 0);
        [controller release]; assert(fake.releases == 1 && fake.closes == 0); cases++;

        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        [controller setIsInterfaceOpen:YES]; [controller setIsInterfaceOpen:YES];
        assert([controller isInterfaceOpen] && fake.opens == 1);
        assert(send(controller) && send(controller));
        assert(fake.opens == 1 && fake.closes == 0 && fake.requests == 2 && fake.owned);
        fake.requestResult = kIOReturnError;
        assert(!send(controller) && [controller isInterfaceOpen] && fake.closes == 0);
        [controller setIsInterfaceOpen:NO]; [controller setIsInterfaceOpen:NO];
        assert(![controller isInterfaceOpen] && fake.closes == 1);
        [controller release]; assert(fake.closes == 1 && fake.releases == 1); cases++;

        // Even an explicit attempt cannot retain another client's borrowed open.
        prepare(&fake,kIOReturnExclusiveAccess,kIOReturnSuccess,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        [controller setIsInterfaceOpen:YES]; assert([controller isInterfaceOpen]);
        assert(send(controller)); assert(![controller isInterfaceOpen] && fake.closes == 0);
        [controller release]; assert(fake.releases == 1 && fake.foreignOpen); cases++;

        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        [controller setIsInterfaceOpen:YES]; [controller release];
        assert(fake.opens == 1 && fake.closes == 1 && fake.releases == 1 && !fake.owned); cases++;

        prepare(&fake,kIOReturnExclusiveAccess,kIOReturnSuccess,kIOReturnSuccess);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        [controller setIsInterfaceOpen:YES]; [controller release];
        assert(fake.opens == 1 && fake.closes == 0 && fake.releases == 1 && fake.foreignOpen); cases++;

        // A failed automatic close must not turn into persistent explicit intent.
        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnError);
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        assert(send(controller)); assert([controller isInterfaceOpen] && fake.owned && fake.closes == 1);
        fake.closeResult = kIOReturnSuccess;
        assert(send(controller));
        assert(![controller isInterfaceOpen] && fake.opens == 1 && fake.requests == 2 && fake.closes == 2);
        [controller release]; assert(fake.releases == 1 && fake.closes == 2); cases++;

        for (int noDevice = 0; noDevice < 2; noDevice++) {
            prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,noDevice ? kIOReturnNoDevice : kIOReturnNotOpen);
            controller = [[InterfaceTestController alloc] initWithFake:&fake];
            assert(send(controller)); assert(![controller isInterfaceOpen] && fake.closes == 1);
            [controller release]; assert(fake.releases == 1 && fake.closes == 1); cases++;
        }

        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess); fake.raisesRequest = YES;
        controller = [[InterfaceTestController alloc] initWithFake:&fake];
        BOOL caught = NO;
        @try { send(controller); } @catch (NSException *exception) { caught = [exception.name isEqual:@"TestRequestException"]; }
        assert(caught && fake.closes == 1 && ![controller isInterfaceOpen]);
        [controller release]; assert(fake.releases == 1 && fake.closes == 1); cases++;

        controller = [[UVCController alloc] init];
        assert(!send(controller)); [controller setIsInterfaceOpen:YES]; assert(![controller isInterfaceOpen]);
        [controller release]; cases++;

        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        InterfaceTestController *fast = [[InterfaceTestController alloc] initWithFake:&fake];
        assert([fast writePanTiltAbsolutePan:6120 tilt:-29880 requestTimeoutMilliseconds:100] == kIOReturnUnsupported);
        assert(fake.opens == 0 && fake.requests == 0);
        [fast configurePanTilt:YES];
        assert([fast writePanTiltAbsolutePan:6120 tilt:-29880 requestTimeoutMilliseconds:0] == kIOReturnBadArgument);
        assert([fast writePanTiltAbsolutePan:6120 tilt:-29880 requestTimeoutMilliseconds:251] == kIOReturnBadArgument);
        assert(fake.opens == 0 && fake.requests == 0);
        assert([fast writePanTiltAbsolutePan:6120 tilt:-29880 requestTimeoutMilliseconds:100] == kIOReturnSuccess);
        const uint8_t target[] = {0xe8,0x17,0x00,0x00,0x48,0x8b,0xff,0xff};
        assert(memcmp(fake.lastBytes,target,8) == 0);
        assert(fake.requests == 1 && fake.opens == 1 && fake.closes == 1);
        assert(fake.lastRequest.bmRequestType == 0x21 && fake.lastRequest.bRequest == 1);
        assert(fake.lastRequest.wValue == 0x0d00 && fake.lastRequest.wIndex == 0x0907);
        assert(fake.lastRequest.noDataTimeout == 100 && fake.lastRequest.completionTimeout == 100);
        fake.requestResult = kIOUSBTransactionTimeout;
        assert([fast writePanTiltAbsolutePan:INT32_MIN tilt:INT32_MAX requestTimeoutMilliseconds:100] == kIOUSBTransactionTimeout);
        const uint8_t extrema[] = {0,0,0,0x80,0xff,0xff,0xff,0x7f};
        assert(memcmp(fake.lastBytes,extrema,8) == 0 && fake.closes == 2);
        fake.requestResult = kIOReturnSuccess; fake.shortRequest = YES;
        assert([fast writePanTiltAbsolutePan:0 tilt:0 requestTimeoutMilliseconds:100] == kIOReturnUnderrun);
        assert(fake.requests == 3 && fake.closes == 3);
        [fast release]; assert(fake.releases == 1); cases++;
        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        fast = [[InterfaceTestController alloc] initWithFake:&fake];
        assert([fast writeZoomAbsolute:0x1234 requestTimeoutMilliseconds:100] == kIOReturnUnsupported);
        assert(fake.requests == 0);
        [fast configurePanTilt:YES];
        assert([fast writeZoomAbsolute:0x1234 requestTimeoutMilliseconds:100] == kIOReturnSuccess);
        assert(fake.requests == 1 && fake.lastRequest.wLength == 2);
        assert(fake.lastRequest.wIndex == 0x0907 && fake.lastRequest.wValue == 0x0b00);
        assert(fake.lastRequest.bRequest == 1 && fake.lastRequest.bmRequestType == 0x21);
        assert(fake.lastBytes[0] == 0x34 && fake.lastBytes[1] == 0x12);
        assert(fake.lastRequest.completionTimeout == 100 && fake.lastRequest.noDataTimeout == 100);
        fake.shortRequest = YES;
        assert([fast writeZoomAbsolute:65535 requestTimeoutMilliseconds:100] == kIOReturnUnderrun);
        assert(fake.lastBytes[0] == 0xff && fake.lastBytes[1] == 0xff);
        [fast release]; assert(fake.closes == 2 && fake.releases == 1); cases++;
        prepare(&fake,kIOReturnSuccess,kIOReturnSuccess,kIOReturnSuccess);
        fast = [[InterfaceTestController alloc] initWithFake:&fake];
        assert([fast writeRollAbsolute:-1234 requestTimeoutMilliseconds:100] == kIOReturnUnsupported);
        [fast configurePanTilt:YES];
        assert([fast writeRollAbsolute:-1234 requestTimeoutMilliseconds:100] == kIOReturnUnsupported);
        assert(fake.opens == 0 && fake.requests == 0); // Descriptor did not advertise roll.
        [fast enableRoll];
        assert([fast writeRollAbsolute:-1234 requestTimeoutMilliseconds:0] == kIOReturnBadArgument);
        assert([fast writeRollAbsolute:-1234 requestTimeoutMilliseconds:251] == kIOReturnBadArgument);
        assert(fake.opens == 0 && fake.requests == 0);
        assert([fast writeRollAbsolute:-1234 requestTimeoutMilliseconds:100] == kIOReturnSuccess);
        assert(fake.requests == 1 && fake.lastRequest.wLength == 2);
        assert(fake.lastRequest.wIndex == 0x0907 && fake.lastRequest.wValue == 0x0f00);
        assert(fake.lastRequest.bRequest == 1 && fake.lastRequest.bmRequestType == 0x21);
        assert(fake.lastBytes[0] == 0x2e && fake.lastBytes[1] == 0xfb);
        assert(fake.lastRequest.completionTimeout == 100 && fake.lastRequest.noDataTimeout == 100);
        assert([fast writeRollAbsolute:INT16_MIN requestTimeoutMilliseconds:100] == kIOReturnSuccess);
        assert(fake.lastBytes[0] == 0 && fake.lastBytes[1] == 0x80);
        assert([fast writeRollAbsolute:INT16_MAX requestTimeoutMilliseconds:100] == kIOReturnSuccess);
        assert(fake.lastBytes[0] == 0xff && fake.lastBytes[1] == 0x7f);
        NSUInteger rollIndex = [fast controlIndexForString:@"roll-abs"];
        const char *declaredType = UVCControllerControls[rollIndex].uvcTypeDescription;
        UVCControllerControls[rollIndex].uvcTypeDescription = "{S4}";
        assert([fast writeRollAbsolute:0 requestTimeoutMilliseconds:100] == kIOReturnUnsupported);
        assert(fake.requests == 3);
        UVCControllerControls[rollIndex].uvcTypeDescription = declaredType;
        fake.shortRequest = YES;
        assert([fast writeRollAbsolute:-1 requestTimeoutMilliseconds:100] == kIOReturnUnderrun);
        assert(fake.lastBytes[0] == 0xff && fake.lastBytes[1] == 0xff);
        fake.shortRequest = NO; fake.requestResult = kIOUSBTransactionTimeout;
        assert([fast writeRollAbsolute:0 requestTimeoutMilliseconds:100] == kIOUSBTransactionTimeout);
        [fast release]; assert(fake.requests == 5 && fake.closes == 5 && fake.releases == 1); cases++;
        printf("{\"passed\":true,\"cases\":%d,\"automaticOwnedOpenClosedPerRequest\":true,\"borrowedExclusiveAccessNeverClosed\":true,\"borrowedStateClearedPerRequest\":true,\"explicitOwnedOpenPersists\":true,\"failedRequestsCloseOwnedOpen\":true,\"closeFailureDoesNotBecomeExplicit\":true,\"deallocationBalancesOwnership\":true,\"interfaceID220\":true,\"finiteRequestTimeouts\":true,\"fastExactEightByteSet\":true,\"realUnitAndInterfaceAddress\":true,\"shortTransferRejected\":true,\"rollSignedTwoByteSET\":true,\"rollDeclaredSelectorAndDescriptor\":true,\"hardwareAccess\":false}\n",cases);
    }
    return 0;
}

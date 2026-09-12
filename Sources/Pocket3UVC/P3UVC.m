#import "include/Pocket3UVC.h"
#import "UVCController.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/sysctl.h>
#import <IOKit/IOKitLib.h>

static char *json(id value) {
    @try {
        if (![NSJSONSerialization isValidJSONObject:value]) return strdup("{\"error\":\"uvc_serialization_failed\"}");
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
        if (!data) return strdup("{\"error\":\"uvc_serialization_failed\"}");
        char *out = malloc(data.length + 1);
        if (!out) return NULL;
        memcpy(out, data.bytes, data.length); out[data.length] = 0;
        return out;
    } @catch (NSException *exception) {
        return strdup("{\"error\":\"uvc_serialization_failed\"}");
    }
}
static BOOL pair(UVCValue *value, int32_t *pan, int32_t *tilt) {
    if (!value || [value byteSize] != 8) return NO;
    [value byteSwapUSBToHostEndian];
    // Upstream pointerToFieldWithName treats offset zero as an invalid type.
    // Pan is the first field, so read the verified 8-byte UVC layout directly.
    const uint8_t *bytes = [value valuePtr];
    if (!bytes) return NO;
    memcpy(pan, bytes, 4); memcpy(tilt, bytes + 4, 4); return YES;
}
static NSDictionary *position(UVCValue *value) {
    int32_t pan, tilt;
    return pair(value, &pan, &tilt) ? @{@"pan":@(pan), @"tilt":@(tilt)} : nil;
}
static NSNumber *unsignedShortValue(UVCValue *value) {
    if (!value || [value byteSize] != 2 || ![value valuePtr]) return nil;
    [value byteSwapUSBToHostEndian];
    uint16_t raw = 0; memcpy(&raw, [value valuePtr], sizeof(raw));
    return @(raw);
}
static NSNumber *signedShortValue(UVCValue *value) {
    if (!value || [value byteSize] != 2 || ![value valuePtr]) return nil;
    [value byteSwapUSBToHostEndian];
    int16_t raw = 0; memcpy(&raw, [value valuePtr], sizeof(raw));
    return @(raw);
}
static BOOL exactPosition(UVCValue *value, int32_t pan, int32_t tilt) {
    if (!value || [value byteSize] != 8) return NO;
    [value byteSwapUSBToHostEndian];
    NSString *text = [NSString stringWithFormat:@"{pan=%d,tilt=%d}",pan,tilt];
    // Range validation belongs to the caller. The upstream control parser
    // silently rounds to GET_RES (3600), changing a live hold target such as
    // 6120 into 7200. Preserve the exact readback requested by the stop policy.
    return [value scanCString:text.UTF8String flags:0];
}
static uint32_t registryNumber(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int64_t number = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &number);
    if (value) CFRelease(value);
    return (uint32_t)number;
}
static NSString *registryString(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    NSString *result = nil;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) result = [(__bridge NSString *)value copy];
    if (value) CFRelease(value);
    return result;
}
static BOOL isPocket3Service(io_service_t service, uint32_t location) {
    return registryNumber(service, CFSTR("locationID")) == location
        && registryNumber(service, CFSTR("idVendor")) == 0x2ca3
        && registryNumber(service, CFSTR("idProduct")) == 0x0023;
}
static NSString *attachmentIdentity(uint32_t location) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return nil;
    NSString *identity = nil;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (registryNumber(service, CFSTR("locationID")) == location && registryNumber(service, CFSTR("idVendor")) == 0x2ca3 && registryNumber(service, CFSTR("idProduct")) == 0x0023) {
            uint64_t entryID = 0;
            if (IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS) identity = [NSString stringWithFormat:@"%016llx", (unsigned long long)entryID];
        }
        IOObjectRelease(service);
        if (identity) break;
    }
    IOObjectRelease(iterator);
    return identity;
}
static NSString *bootIdentity(void) {
    char value[128] = {0}; size_t size = sizeof(value);
    if (sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0) != 0) return nil;
    value[sizeof(value)-1] = 0;
    return [NSString stringWithUTF8String:value];
}
static UVCController *device(uint32_t location) {
    UVCController *c = [UVCController uvcControllerWithLocationId:location];
    if ([c vendorId] != 0x2ca3 || [c productId] != 0x0023) return nil;
    return c;
}
struct P3UVCSession {
    uint32_t location;
    UVCController *controller;
    NSDictionary *controls;
    NSString *registryID;
    NSString *bootSessionID;
    BOOL invalidated;
};

// Opt-in lab trace of pan/tilt writes only; no frames, credentials or generic
// device packets. Normal launches never write this diagnostic file.
static void tracePositionBytes(const char *stage, int32_t pan, int32_t tilt, const uint8_t *bytes, double transferSeconds) {
    const char *path = getenv("POCKET3_UVC_TRACE");
    if (!path || !*path || !bytes) return;
    char hex[17];
    for (int i = 0; i < 8; i++) snprintf(hex + i * 2, 3, "%02x", bytes[i]);
    char *record = json(@{@"stage":[NSString stringWithUTF8String:stage], @"pan":@(pan), @"tilt":@(tilt),
                         @"bytes":[NSString stringWithUTF8String:hex], @"uptime":@([NSProcessInfo processInfo].systemUptime), @"transferSeconds":@(transferSeconds)});
    if (!record) return;
    FILE *file = fopen(path, "a");
    if (file) { fprintf(file, "%s\n", record); fclose(file); }
    free(record);
}
static void tracePosition(const char *stage, int32_t pan, int32_t tilt, UVCValue *value, double transferSeconds) {
    if ([value byteSize] == 8) tracePositionBytes(stage, pan, tilt, [value valuePtr], transferSeconds);
}

void p3_uvc_session_close(P3UVCSession *session) {
    if (!session) return;
    @autoreleasepool {
        // Controls retain their parent; the parent's cache is zeroing-weak.
        // Drop these explicit owners before releasing the final controller.
        [session->controls release];
        [session->controller release];
        [session->registryID release];
        [session->bootSessionID release];
        free(session);
    }
}

static BOOL sessionIsCurrent(P3UVCSession *session) {
    if (!session || session->invalidated) return NO;
    if (![session->registryID isEqualToString:attachmentIdentity(session->location)] ||
        ![session->bootSessionID isEqualToString:bootIdentity()]) {
        // Never replace a retained handle by looking up a newly attached camera.
        session->invalidated = YES;
        return NO;
    }
    return YES;
}

char *p3_uvc_session_open(uint32_t location, P3UVCSession **outSession) {
    if (!outSession) return json(@{@"error":@"uvc_session_unavailable"});
    *outSession = NULL;
    @autoreleasepool {
        NSString *registryID = attachmentIdentity(location), *boot = bootIdentity();
        if (!registryID.length || !boot.length) return json(@{@"error":@"uvc_attachment_changed"});
        UVCController *controller = device(location);
        if (!controller) return json(@{@"error":@"uvc_device_missing"});
        P3UVCSession *session = calloc(1, sizeof(*session));
        if (!session) return json(@{@"error":@"uvc_memory"});
        session->location = location;
        session->controller = [controller retain];
        session->registryID = [registryID copy];
        session->bootSessionID = [boot copy];
        // Opening is bound to the pre-open attachment too. If the port changed
        // while the controller was constructed, discard it before any reads.
        if (!sessionIsCurrent(session)) {
            p3_uvc_session_close(session);
            return json(@{@"error":@"uvc_attachment_changed"});
        }
        NSMutableDictionary *controls = [NSMutableDictionary dictionary];
        for (NSString *name in [controller controlStrings]) {
            if (!sessionIsCurrent(session)) {
                p3_uvc_session_close(session);
                return json(@{@"error":@"uvc_attachment_changed"});
            }
            UVCControl *control = [controller controlWithName:name];
            if (control) controls[name] = control;
        }
        session->controls = [controls copy];
        if (!sessionIsCurrent(session)) {
            p3_uvc_session_close(session);
            return json(@{@"error":@"uvc_attachment_changed"});
        }
        if (!session->controls[@"pan-tilt-abs"]) {
            p3_uvc_session_close(session);
            return json(@{@"error":@"uvc_control_unavailable"});
        }
        char *result = json(@{@"opened":@YES});
        if (!result) { p3_uvc_session_close(session); return NULL; }
        *outSession = session;
        return result;
    }
}

char *p3_uvc_devices(void) {
    @autoreleasepool {
        NSMutableArray *items = [NSMutableArray array];
        for (UVCController *c in [UVCController uvcControllers]) {
            if ([c vendorId] == 0x2ca3 && [c productId] == 0x0023)
                [items addObject:@{@"name":[c deviceName], @"location":@([c locationId]), @"vendor":@([c vendorId]), @"product":@([c productId])}];
        }
        return json(items);
    }
}
char *p3_uvc_stream_interfaces(uint32_t location) {
    @autoreleasepool {
        io_iterator_t devices = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) != KERN_SUCCESS) {
            return json(@{ @"deviceFound": @NO, @"requestedLocation": @(location), @"error": @"usb_registry_unavailable" });
        }
        NSMutableArray *interfaces = [NSMutableArray array];
        BOOL found = NO;
        io_service_t device;
        while ((device = IOIteratorNext(devices))) {
            if (!isPocket3Service(device, location)) { IOObjectRelease(device); continue; }
            found = YES;
            io_iterator_t children = IO_OBJECT_NULL;
            if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS) {
                io_service_t child;
                while ((child = IOIteratorNext(children))) {
                    if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                        uint32_t klass = registryNumber(child, CFSTR("bInterfaceClass"));
                        uint32_t subclass = registryNumber(child, CFSTR("bInterfaceSubClass"));
                        if (klass == 14 && (subclass == 1 || subclass == 2)) {
                            NSString *name = registryString(child, CFSTR("kUSBString"));
                            [interfaces addObject:@{
                                @"number": @(registryNumber(child, CFSTR("bInterfaceNumber"))),
                                @"alternateSetting": @(registryNumber(child, CFSTR("bAlternateSetting"))),
                                @"interfaceClass": @(klass), @"interfaceSubclass": @(subclass),
                                @"interfaceProtocol": @(registryNumber(child, CFSTR("bInterfaceProtocol"))),
                                @"declaredEndpointCount": @(registryNumber(child, CFSTR("bNumEndpoints"))),
                                @"name": name ?: @""
                            }];
                        }
                    }
                    IOObjectRelease(child);
                }
                IOObjectRelease(children);
            }
            IOObjectRelease(device);
            break;
        }
        IOObjectRelease(devices);
        return json(@{ @"deviceFound": @(found), @"requestedLocation": @(location),
                       @"interfaces": interfaces, @"access": @"ioregistry_read_only" });
    }
}

char *p3_uvc_stream_open_diagnostic(uint32_t location) {
    @autoreleasepool {
        io_iterator_t devices = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) != KERN_SUCCESS) {
            return json(@{ @"deviceFound": @NO, @"opened": @NO, @"result": @"registry_unavailable" });
        }
        io_service_t deviceService = IO_OBJECT_NULL;
        io_service_t candidate = IO_OBJECT_NULL;
        while ((deviceService = IOIteratorNext(devices))) {
            if (!isPocket3Service(deviceService, location)) { IOObjectRelease(deviceService); continue; }
            IOUSBDeviceInterface **deviceInterface = NULL;
            IOCFPlugInInterface **plugin = NULL;
            SInt32 score = 0;
            kern_return_t created = IOCreatePlugInInterfaceForService(deviceService, kIOUSBDeviceUserClientTypeID,
                kIOCFPlugInInterfaceID, &plugin, &score);
            if (created == kIOReturnSuccess && plugin) {
                IOReturn queried = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID)&deviceInterface);
                IODestroyPlugInInterface(plugin); plugin = NULL;
                if (queried == kIOReturnSuccess && deviceInterface) {
                    IOUSBFindInterfaceRequest request = { .bInterfaceClass = kUSBVideoInterfaceClass,
                        .bInterfaceSubClass = kUSBVideoStreamingSubClass, .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
                        .bAlternateSetting = kIOUSBFindInterfaceDontCare };
                    io_iterator_t iterator = IO_OBJECT_NULL;
                    if ((*deviceInterface)->CreateInterfaceIterator(deviceInterface, &request, &iterator) == kIOReturnSuccess && iterator) {
                        candidate = IOIteratorNext(iterator);
                        IOObjectRelease(iterator);
                    }
                    (*deviceInterface)->Release(deviceInterface);
                }
            }
            IOObjectRelease(deviceService);
            break;
        }
        IOObjectRelease(devices);
        if (!candidate) return json(@{ @"deviceFound": @(deviceService != IO_OBJECT_NULL), @"opened": @NO, @"result": @"streaming_interface_unavailable" });

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kern_return_t created = IOCreatePlugInInterfaceForService(candidate, kIOUSBInterfaceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(candidate);
        if (created != kIOReturnSuccess || !plugin) return json(@{ @"deviceFound": @YES, @"opened": @NO, @"result": @"interface_plugin_unavailable" });
        IOUSBInterfaceInterface220 **interface = NULL;
        IOReturn queried = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID220), (LPVOID)&interface);
        IODestroyPlugInInterface(plugin);
        if (queried != kIOReturnSuccess || !interface) return json(@{ @"deviceFound": @YES, @"opened": @NO, @"result": @"interface_unavailable" });

        UInt8 number = 0, endpointCount = 0;
        (void)(*interface)->GetInterfaceNumber(interface, &number);
        (void)(*interface)->GetNumEndpoints(interface, &endpointCount);
        IOReturn opened = (*interface)->USBInterfaceOpen(interface);
        BOOL ownsOpen = opened == kIOReturnSuccess;
        NSMutableArray *endpoints = [NSMutableArray array];
        // Some IOUSBLib implementations expose the count before ownership
        // but return empty properties until USBInterfaceOpen succeeds.
        if (ownsOpen) for (UInt8 pipe = 1; pipe <= endpointCount; pipe++) {
            UInt8 direction = 0, pipeNumber = 0, transfer = 0, interval = 0; UInt16 maxPacket = 0;
            if ((*interface)->GetPipeProperties(interface, pipe, &direction, &pipeNumber, &transfer, &maxPacket, &interval) == kIOReturnSuccess) {
                UInt8 address = (UInt8)((pipeNumber & 0x0f) |
                                        (direction == kUSBIn ? 0x80 : 0));
                [endpoints addObject:@{ @"pipe": @(pipe), @"address": @(address),
                    @"direction": @(direction), @"transferType": @(transfer),
                    @"maxPacket": @(maxPacket), @"interval": @(interval) }];
            }
        }
        IOReturn closed = ownsOpen ? (*interface)->USBInterfaceClose(interface) : kIOReturnNotOpen;
        (*interface)->Release(interface);
        NSString *result = ownsOpen ? (closed == kIOReturnSuccess ? @"opened_and_closed" : @"close_failed") :
            (opened == kIOReturnExclusiveAccess ? @"busy" : @"open_failed");
        return json(@{ @"deviceFound": @YES, @"interfaceNumber": @(number), @"endpointCount": @(endpointCount),
            @"endpoints": endpoints, @"opened": @(ownsOpen), @"closed": @(closed == kIOReturnSuccess),
            @"openIOReturn": @(opened), @"closeIOReturn": @(closed), @"result": result,
            @"access": @"normal_open_immediate_close_no_seize_no_pipe" });
    }
}

struct P3UVCStreamSession {
    uint32_t location;
    UInt8 interfaceNumber;
    UInt8 alternateSetting;
    UInt8 endpointAddress;
    IOUSBInterfaceInterface220 **interface;
    NSArray *endpoints;
    NSString *registryID;
    NSString *bootSessionID;
    BOOL invalidated;
    BOOL ownsOpen;
};

static IOUSBInterfaceInterface220 **streamInterfaceForService(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t created = IOCreatePlugInInterfaceForService(
        service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    if (created != kIOReturnSuccess || !plugin) {
        if (plugin) IODestroyPlugInInterface(plugin);
        return NULL;
    }
    IOUSBInterfaceInterface220 **interface = NULL;
    IOReturn queried = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID220),
        (LPVOID)&interface);
    IODestroyPlugInInterface(plugin);
    if (queried != kIOReturnSuccess) {
        if (interface) (*interface)->Release(interface);
        return NULL;
    }
    return interface;
}

static NSString *streamOpenResult(IOReturn result) {
    if (result == kIOReturnExclusiveAccess) return @"busy";
    if (result == kIOReturnNoDevice || result == kIOReturnNotResponding)
        return @"detached";
    if (result == kIOReturnTimeout || result == kIOUSBTransactionTimeout)
        return @"timeout";
    return @"open_failed";
}

static BOOL streamSessionIsCurrent(P3UVCStreamSession *session) {
    if (!session || session->invalidated) return NO;
    NSString *currentRegistryID = attachmentIdentity(session->location);
    NSString *currentBootSessionID = bootIdentity();
    if (![session->registryID isEqualToString:currentRegistryID] ||
        ![session->bootSessionID isEqualToString:currentBootSessionID]) {
        session->invalidated = YES;
        return NO;
    }
    return YES;
}

static NSArray *streamEndpointInventory(IOUSBInterfaceInterface220 **interface,
                                        UInt8 endpointCount,
                                        UInt8 expectedAddress,
                                        BOOL *matchingEndpoint) {
    NSMutableArray *endpoints = [NSMutableArray arrayWithCapacity:endpointCount];
    BOOL matching = NO;
    for (UInt8 pipe = 1; pipe <= endpointCount; pipe++) {
        UInt8 direction = 0, number = 0, transfer = 0, interval = 0;
        UInt16 maxPacket = 0;
        IOReturn properties = (*interface)->GetPipeProperties(
            interface, pipe, &direction, &number, &transfer, &maxPacket,
            &interval);
        if (properties != kIOReturnSuccess) continue;
        // IOUSBLib reports direction as kUSBIn (1) or kUSBOut (0), while
        // descriptor endpoint addresses encode IN in bit 7.
        UInt8 address = (UInt8)((number & 0x0f) |
                                (direction == kUSBIn ? 0x80 : 0));
        [endpoints addObject:@{
            @"pipe": @(pipe), @"address": @(address),
            @"direction": @(direction), @"transferType": @(transfer),
            @"maxPacket": @(maxPacket), @"interval": @(interval)
        }];
        if (address == expectedAddress && direction == kUSBIn &&
            transfer == kUSBBulk && maxPacket > 0) matching = YES;
    }
    if (matchingEndpoint) *matchingEndpoint = matching;
    return [endpoints copy];
}

static IOUSBInterfaceInterface220 **findStreamInterface(
    io_service_t deviceService, UInt8 requestedNumber, UInt8 requestedAlternate,
    BOOL *interfaceFound) {
    if (interfaceFound) *interfaceFound = NO;
    IOUSBDeviceInterface **deviceInterface = NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t created = IOCreatePlugInInterfaceForService(
        deviceService, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    if (created != kIOReturnSuccess || !plugin) {
        if (plugin) IODestroyPlugInInterface(plugin);
        return NULL;
    }
    IOReturn queried = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        (LPVOID)&deviceInterface);
    IODestroyPlugInInterface(plugin);
    if (queried != kIOReturnSuccess || !deviceInterface) return NULL;

    IOUSBFindInterfaceRequest request = {
        .bInterfaceClass = kUSBVideoInterfaceClass,
        .bInterfaceSubClass = kUSBVideoStreamingSubClass,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = requestedAlternate
    };
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn iteratorResult = (*deviceInterface)->CreateInterfaceIterator(
        deviceInterface, &request, &iterator);
    IOUSBInterfaceInterface220 **selected = NULL;
    if (iteratorResult == kIOReturnSuccess && iterator) {
        io_service_t candidate = IO_OBJECT_NULL;
        while ((candidate = IOIteratorNext(iterator))) {
            IOUSBInterfaceInterface220 **interface =
                streamInterfaceForService(candidate);
            BOOL matches = NO;
            if (interface) {
                UInt8 number = 0, alternate = 0;
                IOReturn numberResult = (*interface)->GetInterfaceNumber(
                    interface, &number);
                IOReturn alternateResult = (*interface)->GetAlternateSetting(
                    interface, &alternate);
                matches = numberResult == kIOReturnSuccess &&
                    alternateResult == kIOReturnSuccess &&
                    number == requestedNumber && alternate == requestedAlternate;
                if (matches) {
                    selected = interface;
                    if (interfaceFound) *interfaceFound = YES;
                } else {
                    (*interface)->Release(interface);
                }
            }
            IOObjectRelease(candidate);
            if (selected) break;
        }
        IOObjectRelease(iterator);
    }
    (*deviceInterface)->Release(deviceInterface);
    return selected;
}

char *p3_uvc_stream_session_open(uint32_t location, uint8_t interfaceNumber,
                                  uint8_t alternateSetting, uint8_t endpointAddress,
                                  P3UVCStreamSession **outSession) {
    if (!outSession) return json(@{ @"error": @"uvc_stream_invalid_argument" });
    *outSession = NULL;
    @autoreleasepool {
        NSString *registryID = [attachmentIdentity(location) copy];
        NSString *bootSessionID = [bootIdentity() copy];
        if (!registryID.length || !bootSessionID.length) {
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_attachment_changed",
                           @"result": @"detached" });
        }

        io_iterator_t devices = IO_OBJECT_NULL;
        kern_return_t matchingResult = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices);
        if (matchingResult != KERN_SUCCESS) {
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_registry_unavailable",
                           @"result": @"registry_unavailable" });
        }

        io_service_t deviceService = IO_OBJECT_NULL;
        BOOL deviceFound = NO;
        IOUSBInterfaceInterface220 **interface = NULL;
        while ((deviceService = IOIteratorNext(devices))) {
            if (!isPocket3Service(deviceService, location)) {
                IOObjectRelease(deviceService);
                continue;
            }
            deviceFound = YES;
            BOOL interfaceFound = NO;
            interface = findStreamInterface(deviceService, interfaceNumber,
                                            alternateSetting, &interfaceFound);
            IOObjectRelease(deviceService);
            if (!interfaceFound) interface = NULL;
            break;
        }
        IOObjectRelease(devices);

        if (!deviceFound) {
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_device_missing",
                           @"result": @"device_unavailable" });
        }
        if (!interface) {
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_streaming_interface_unavailable",
                           @"result": @"interface_unavailable" });
        }

        // IOUSBLib exposes the endpoint count before an open, but some
        // devices do not expose pipe properties until the interface is owned.
        // Do not use a pre-open GetPipeProperties result to decide capability.
        UInt8 endpointCount = 0;
        IOReturn endpointCountResult = (*interface)->GetNumEndpoints(
            interface, &endpointCount);
        if (endpointCountResult != kIOReturnSuccess) {
            (*interface)->Release(interface);
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_stream_endpoint_unavailable",
                           @"result": @"endpoint_unavailable",
                           @"endpointCountIOReturn": @((uint32_t)endpointCountResult) });
        }

        // This is the only open attempt. A foreign owner is never borrowed;
        // no close is sent when USBInterfaceOpen reports ExclusiveAccess.
        IOReturn opened = (*interface)->USBInterfaceOpen(interface);
        if (opened != kIOReturnSuccess) {
            NSString *result = streamOpenResult(opened);
            NSString *error = [result isEqualToString:@"busy"]
                ? @"uvc_stream_busy"
                : [result isEqualToString:@"detached"]
                    ? @"uvc_attachment_changed"
                    : [result isEqualToString:@"timeout"]
                        ? @"uvc_stream_open_timeout"
                        : @"uvc_stream_open_failed";
            (*interface)->Release(interface);
            [registryID release];
            [bootSessionID release];
            char *value = json(@{ @"error": error, @"result": result,
                           @"opened": @NO, @"ownedOpen": @NO,
                           @"interfaceNumber": @(interfaceNumber),
                           @"alternateSetting": @(alternateSetting),
                           @"endpointAddress": @(endpointAddress),
                           @"endpointCount": @(endpointCount),
                           // Pipe properties are intentionally not queried
                           // before a successful normal open.
                           @"endpoints": @[],
                           @"openIOReturn": @((uint32_t)opened),
                           @"access": @"normal_open_no_seize_no_pipe" });
            return value;
        }

        NSString *currentRegistryID = attachmentIdentity(location);
        NSString *currentBootSessionID = bootIdentity();
        BOOL stillCurrent = [registryID isEqualToString:currentRegistryID] &&
            [bootSessionID isEqualToString:currentBootSessionID];
        if (!stillCurrent) {
            IOReturn closed = (*interface)->USBInterfaceClose(interface);
            (*interface)->Release(interface);
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_attachment_changed",
                           @"result": @"detached", @"opened": @NO,
                           @"closed": @(closed == kIOReturnSuccess ||
                                         closed == kIOReturnNoDevice),
                           @"openIOReturn": @((uint32_t)opened),
                           @"closeIOReturn": @((uint32_t)closed) });
        }

        BOOL matchingEndpoint = NO;
        NSArray *endpoints = streamEndpointInventory(
            interface, endpointCount, endpointAddress, &matchingEndpoint);
        if (!endpoints) {
            IOReturn closed = (*interface)->USBInterfaceClose(interface);
            (*interface)->Release(interface);
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_stream_endpoint_unavailable",
                           @"result": @"endpoint_unavailable",
                           @"opened": @YES, @"closed": @(closed == kIOReturnSuccess ||
                                                         closed == kIOReturnNoDevice),
                           @"interfaceNumber": @(interfaceNumber),
                           @"alternateSetting": @(alternateSetting),
                           @"endpointAddress": @(endpointAddress),
                           @"endpointCount": @(endpointCount), @"endpoints": @[],
                           @"openIOReturn": @((uint32_t)opened),
                           @"closeIOReturn": @((uint32_t)closed),
                           @"access": @"normal_open_no_seize_no_pipe" });
        }
        if (!matchingEndpoint) {
            // Endpoint properties are authoritative only after ownership;
            // close the owned interface immediately when 0x82 is absent.
            IOReturn closed = (*interface)->USBInterfaceClose(interface);
            char *value = json(@{ @"error": @"uvc_stream_endpoint_unavailable",
                           @"result": @"endpoint_unavailable",
                           @"opened": @YES,
                           @"closed": @(closed == kIOReturnSuccess ||
                                         closed == kIOReturnNoDevice),
                           @"interfaceNumber": @(interfaceNumber),
                           @"alternateSetting": @(alternateSetting),
                           @"endpointAddress": @(endpointAddress),
                           @"endpointCount": @(endpointCount),
                           @"endpoints": endpoints,
                           @"openIOReturn": @((uint32_t)opened),
                           @"closeIOReturn": @((uint32_t)closed),
                           @"access": @"normal_open_no_seize_no_pipe" });
            (*interface)->Release(interface);
            [endpoints release];
            [registryID release];
            [bootSessionID release];
            return value;
        }

        P3UVCStreamSession *session = calloc(1, sizeof(*session));
        if (!session) {
            (*interface)->USBInterfaceClose(interface);
            (*interface)->Release(interface);
            [endpoints release];
            [registryID release];
            [bootSessionID release];
            return json(@{ @"error": @"uvc_memory",
                           @"result": @"memory_unavailable" });
        }
        session->location = location;
        session->interfaceNumber = interfaceNumber;
        session->alternateSetting = alternateSetting;
        session->endpointAddress = endpointAddress;
        session->interface = interface;
        session->endpoints = endpoints;
        session->registryID = registryID;
        session->bootSessionID = bootSessionID;
        session->ownsOpen = YES;
        *outSession = session;
        return json(@{
            @"opened": @YES, @"ownedOpen": @YES,
            @"location": @(location),
            @"interfaceNumber": @(interfaceNumber),
            @"alternateSetting": @(alternateSetting),
            @"endpointAddress": @(endpointAddress),
            @"endpointCount": @(endpointCount), @"endpoints": endpoints,
            @"openIOReturn": @((uint32_t)opened),
            @"registryID": registryID, @"bootSessionID": bootSessionID,
            @"result": @"opened", @"access": @"normal_open_no_seize_no_pipe"
        });
    }
}

char *p3_uvc_stream_session_status(P3UVCStreamSession *session) {
    @autoreleasepool {
        if (!session) return json(@{ @"error": @"uvc_stream_not_open" });
        if (!streamSessionIsCurrent(session)) {
            return json(@{ @"error": @"uvc_attachment_changed",
                           @"result": @"detached", @"opened": @NO,
                           @"interfaceNumber": @(session->interfaceNumber),
                           @"alternateSetting": @(session->alternateSetting),
                           @"endpointAddress": @(session->endpointAddress) });
        }
        return json(@{
            @"opened": @(session->ownsOpen), @"ownedOpen": @(session->ownsOpen),
            @"location": @(session->location),
            @"interfaceNumber": @(session->interfaceNumber),
            @"alternateSetting": @(session->alternateSetting),
            @"endpointAddress": @(session->endpointAddress),
            @"endpointCount": @(session->endpoints.count),
            @"endpoints": session->endpoints ?: @[],
            @"registryID": session->registryID ?: @"",
            @"bootSessionID": session->bootSessionID ?: @"",
            @"result": @"opened", @"access": @"normal_open_no_seize_no_pipe"
        });
    }
}

char *p3_uvc_stream_session_close(P3UVCStreamSession *session) {
    if (!session) return json(@{ @"error": @"uvc_stream_not_open" });
    @autoreleasepool {
        BOOL current = streamSessionIsCurrent(session);
        IOReturn closed = kIOReturnNotOpen;
        if (session->interface && session->ownsOpen)
            closed = (*session->interface)->USBInterfaceClose(session->interface);
        BOOL interfaceReleased = closed == kIOReturnSuccess ||
            closed == kIOReturnNotOpen || closed == kIOReturnNoDevice;
        BOOL detached = !current || closed == kIOReturnNoDevice;
        NSString *result = detached ? @"detached" :
            (interfaceReleased ? @"closed" : @"close_failed");
        char *value = json(@{
            @"closed": @(interfaceReleased),
            @"interfaceReleased": @(interfaceReleased),
            @"objectsReleased": @YES,
            // No pipe or reader was claimed by this scalar-only boundary.
            @"readerStopped": @YES, @"pipeReleased": @YES,
            @"closeIOReturn": @((uint32_t)closed), @"result": result,
            @"access": @"normal_open_no_seize_no_pipe"
        });
        if (session->interface) {
            (*session->interface)->Release(session->interface);
            session->interface = NULL;
        }
        [session->endpoints release];
        [session->registryID release];
        [session->bootSessionID release];
        free(session);
        return value;
    }
}

char *p3_uvc_session_status(P3UVCSession *session) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *pt = session->controls[@"pan-tilt-abs"];
        NSDictionary *cur = position([pt currentValue]);
        if (!cur) return json(@{@"error":@"uvc_position_unavailable"});
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
            @"location":@(session->location), @"position":cur, @"writable":@([pt supportsSetValue]),
            @"controls":[session->controls allKeys], @"uvcVersion":@([session->controller uvcVersion]),
            @"registryID":session->registryID, @"bootSessionID":session->bootSessionID}];
        NSDictionary *minimum = position([pt minimum]), *maximum = position([pt maximum]), *step = position([pt stepSize]);
        if (minimum) result[@"minimum"] = minimum;
        if (maximum) result[@"maximum"] = maximum;
        if (step) result[@"step"] = step;
        NSDictionary *standard = position([pt defaultValue]);
        if (standard) result[@"defaultPosition"] = standard;
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        return json(result);
    }
}
char *p3_uvc_session_set_position(P3UVCSession *session, int32_t pan, int32_t tilt) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"pan-tilt-abs"];
        int32_t pmin, tmin, pmax, tmax;
        if (![control supportsSetValue] || !pair([control minimum], &pmin, &tmin) || !pair([control maximum], &pmax, &tmax))
            return json(@{@"error":@"uvc_control_unavailable"});
        if (pan < pmin || pan > pmax || tilt < tmin || tilt > tmax)
            return json(@{@"error":@"uvc_out_of_range"});
        UVCValue *value = [control currentValue];
        if (!exactPosition(value, pan, tilt))
            return json(@{@"error":@"uvc_write_failed"});
        // Recheck immediately before SET_CUR. A later detach invalidates the
        // already-retained old USB handle instead of redirecting the request.
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        tracePosition("prepared", pan, tilt, value, 0);
        double transferStart = [NSProcessInfo processInfo].systemUptime;
        BOOL sent = [control writeFromCurrentValue];
        double transferSeconds = [NSProcessInfo processInfo].systemUptime - transferStart;
        tracePosition(sent ? "sent" : "failed", pan, tilt, value, transferSeconds);
        if (!sent)
            return json(@{@"error":@"uvc_write_failed"});
        return json(@{@"sent":@YES, @"target":@{@"pan":@(pan),@"tilt":@(tilt)}});
    }
}
char *p3_uvc_session_set_position_fast(P3UVCSession *session, int32_t pan, int32_t tilt) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"pan-tilt-abs"];
        int32_t pmin, tmin, pmax, tmax;
        // These are the retained control's initialization-time GET_MIN/MAX,
        // never a read of the live setpoint. Invalid or missing limits fail shut.
        if (![control supportsSetValue] || !pair([control minimum], &pmin, &tmin) ||
            !pair([control maximum], &pmax, &tmax) || pmin > pmax || tmin > tmax)
            return json(@{@"error":@"uvc_control_unavailable"});
        if (pan < pmin || pan > pmax || tilt < tmin || tilt > tmax)
            return json(@{@"error":@"uvc_out_of_range"});
        uint8_t bytes[8];
        for (unsigned index = 0; index < 4; index++) {
            bytes[index] = (uint8_t)((uint32_t)pan >> (8 * index));
            bytes[4 + index] = (uint8_t)((uint32_t)tilt >> (8 * index));
        }
        tracePositionBytes("prepared", pan, tilt, bytes, 0);
        // Check after optional diagnostic work, at the final call boundary.
        // A retained old handle can fail on detach but cannot retarget a replug.
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        double started = [NSProcessInfo processInfo].systemUptime;
        IOReturn rc = [session->controller writePanTiltAbsolutePan:pan tilt:tilt
                                      requestTimeoutMilliseconds:P3_UVC_FAST_REQUEST_TIMEOUT_MS];
        tracePositionBytes(rc == kIOReturnSuccess ? "sent" : "failed", pan, tilt, bytes,
                           [NSProcessInfo processInfo].systemUptime - started);
        if (rc != kIOReturnSuccess) {
            NSString *error = (rc == kIOReturnTimeout || rc == kIOUSBTransactionTimeout)
                ? @"uvc_request_timeout" : @"uvc_write_failed";
            return json(@{@"error":error, @"ioReturn":@((uint32_t)rc),
                          @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
        }
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed", @"sent":@YES});
        return json(@{@"sent":@YES, @"target":@{@"pan":@(pan),@"tilt":@(tilt)},
                      @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
    }
}
char *p3_uvc_session_zoom_status(P3UVCSession *session) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"zoom-abs"];
        if (!control) return json(@{@"error":@"uvc_zoom_unavailable"});
        if (![control supportsGetValue]) return json(@{@"error":@"uvc_zoom_not_readable"});
        NSNumber *current = unsignedShortValue([control currentValue]);
        if (!current) return json(@{@"error":@"uvc_zoom_read_failed"});
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
            @"current":current, @"writable":@([control supportsSetValue])}];
        NSNumber *minimum = unsignedShortValue([control minimum]), *maximum = unsignedShortValue([control maximum]);
        NSNumber *step = unsignedShortValue([control stepSize]);
        if (minimum) result[@"minimum"] = minimum;
        if (maximum) result[@"maximum"] = maximum;
        if (step) result[@"step"] = step;
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        return json(result);
    }
}
char *p3_uvc_session_set_zoom(P3UVCSession *session, uint32_t rawValue) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"zoom-abs"];
        if (!control) return json(@{@"error":@"uvc_zoom_unavailable"});
        if (![control supportsSetValue]) return json(@{@"error":@"uvc_zoom_read_only"});
        NSNumber *low = unsignedShortValue([control minimum]), *high = unsignedShortValue([control maximum]);
        if (!low || !high || low.unsignedIntValue > high.unsignedIntValue)
            return json(@{@"error":@"uvc_zoom_limits_unavailable"});
        if (rawValue > UINT16_MAX || rawValue < low.unsignedIntValue || rawValue > high.unsignedIntValue)
            return json(@{@"error":@"uvc_zoom_out_of_range"});
        NSNumber *step = unsignedShortValue([control stepSize]);
        // Missing/zero GET_RES supplies no useful grid. Preserve the requested
        // raw value within validated bounds instead of inventing a step/ratio.
        if (step.unsignedIntValue && (rawValue - low.unsignedIntValue) % step.unsignedIntValue)
            return json(@{@"error":@"uvc_zoom_step_mismatch"});
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        IOReturn rc = [session->controller writeZoomAbsolute:(uint16_t)rawValue
                                requestTimeoutMilliseconds:P3_UVC_FAST_REQUEST_TIMEOUT_MS];
        if (rc != kIOReturnSuccess) return json(@{
            @"error":(rc == kIOReturnTimeout || rc == kIOUSBTransactionTimeout) ? @"uvc_request_timeout" : @"uvc_zoom_write_failed",
            @"ioReturn":@((uint32_t)rc), @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed", @"sent":@YES});
        return json(@{@"sent":@YES, @"target":@(rawValue), @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
    }
}
char *p3_uvc_session_roll_status(P3UVCSession *session) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"roll-abs"];
        if (!control) return json(@{@"error":@"uvc_roll_unavailable"});
        if (![control supportsGetValue]) return json(@{@"error":@"uvc_roll_not_readable"});
        NSNumber *current = signedShortValue([control currentValue]);
        if (!current) return json(@{@"error":@"uvc_roll_read_failed"});
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
            @"current":current, @"writable":@([control supportsSetValue])}];
        NSNumber *minimum = signedShortValue([control minimum]), *maximum = signedShortValue([control maximum]);
        NSNumber *step = signedShortValue([control stepSize]), *standard = signedShortValue([control defaultValue]);
        if (minimum) result[@"minimum"] = minimum;
        if (maximum) result[@"maximum"] = maximum;
        if (step) result[@"step"] = step;
        if (standard) result[@"defaultValue"] = standard;
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        return json(result);
    }
}
char *p3_uvc_session_set_roll(P3UVCSession *session, int32_t rawValue) {
    @autoreleasepool {
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        UVCControl *control = session->controls[@"roll-abs"];
        if (!control) return json(@{@"error":@"uvc_roll_unavailable"});
        if (![control supportsSetValue]) return json(@{@"error":@"uvc_roll_read_only"});
        NSNumber *low = signedShortValue([control minimum]), *high = signedShortValue([control maximum]);
        if (!low || !high || low.intValue > high.intValue) return json(@{@"error":@"uvc_roll_limits_unavailable"});
        if (rawValue < INT16_MIN || rawValue > INT16_MAX || rawValue < low.intValue || rawValue > high.intValue)
            return json(@{@"error":@"uvc_roll_out_of_range"});
        NSNumber *step = signedShortValue([control stepSize]);
        if (!step || step.intValue <= 0) return json(@{@"error":@"uvc_roll_step_unavailable"});
        if (((int64_t)rawValue - low.intValue) % step.intValue) return json(@{@"error":@"uvc_roll_step_mismatch"});
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed"});
        IOReturn rc = [session->controller writeRollAbsolute:(int16_t)rawValue
                                requestTimeoutMilliseconds:P3_UVC_FAST_REQUEST_TIMEOUT_MS];
        if (rc != kIOReturnSuccess) return json(@{
            @"error":(rc == kIOReturnTimeout || rc == kIOUSBTransactionTimeout) ? @"uvc_request_timeout" : @"uvc_roll_write_failed",
            @"ioReturn":@((uint32_t)rc), @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
        if (!sessionIsCurrent(session)) return json(@{@"error":@"uvc_attachment_changed", @"sent":@YES});
        return json(@{@"sent":@YES, @"target":@(rawValue), @"requestTimeoutMilliseconds":@(P3_UVC_FAST_REQUEST_TIMEOUT_MS)});
    }
}
char *p3_uvc_status(uint32_t location) {
    P3UVCSession *session = NULL;
    char *opened = p3_uvc_session_open(location, &session);
    if (!session) return opened;
    free(opened);
    char *result = p3_uvc_session_status(session);
    p3_uvc_session_close(session);
    return result;
}
char *p3_uvc_set_position(uint32_t location, int32_t pan, int32_t tilt, const char *expectedRegistryID) {
    @autoreleasepool {
        NSString *expected = expectedRegistryID ? [NSString stringWithUTF8String:expectedRegistryID] : nil;
        if (!expected.length || ![attachmentIdentity(location) isEqualToString:expected])
            return json(@{@"error":@"uvc_attachment_changed"});
        P3UVCSession *session = NULL;
        char *opened = p3_uvc_session_open(location, &session);
        if (!session) return opened;
        free(opened);
        char *result = [session->registryID isEqualToString:expected]
            ? p3_uvc_session_set_position(session, pan, tilt)
            : json(@{@"error":@"uvc_attachment_changed"});
        p3_uvc_session_close(session);
        return result;
    }
}
void p3_uvc_free(char *value) { free(value); }

int p3_uvc_contract_selftest(void) {
    @autoreleasepool {
        UVCType *type = [UVCType uvcTypeWithCString:"{S4 pan;S4 tilt;}"];
        UVCValue *value = [UVCValue uvcValueWithType:type];
        if (![value scanCString:"{pan=0,tilt=-32400}" flags:0]) return 0;
        int32_t pan = 1, tilt = 1;
        if (!pair(value, &pan, &tilt) || pan != 0 || tilt != -32400) return 0;
        if (!exactPosition(value, 6120, -29880) || !pair(value, &pan, &tilt) || pan != 6120 || tilt != -29880) return 0;
    }
    NSUInteger expected = 0;
    for (int iteration = 0; iteration < 100; iteration++) {
        @autoreleasepool {
            NSArray *names = [UVCController controlStrings];
            if (!expected) expected = names.count;
            if (!expected || names.count != expected) return 0;
            for (id name in names) if (![name isKindOfClass:[NSString class]]) return 0;
            char *encoded = json(@{@"controls":names});
            if (!encoded || strstr(encoded, "uvc_serialization_failed")) { free(encoded); return 0; }
            free(encoded);
            // Invalid objects must become an error result, never an exception.
            char *invalid = json(@{@"invalid":[NSDate date]});
            if (!invalid || !strstr(invalid, "uvc_serialization_failed")) { free(invalid); return 0; }
            free(invalid);
        }
    }
    return 1;
}

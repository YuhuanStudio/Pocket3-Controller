// Hardware-free regression for the retained normal VS-open boundary.
// GetPipeProperties is intentionally empty before ownership and populated
// only after USBInterfaceOpen, matching the observed Pocket 3 behavior.
#define main unused_stream_ownership_main
#include "Ownership.m"
#undef main

#include <assert.h>
#include <string.h>

static const io_service_t streamDeviceService = 7001;
static const io_service_t streamInterfaceService = 7002;
static const io_iterator_t streamDeviceIteratorBase = 7100;
static const io_iterator_t streamInterfaceIterator = 7200;
static int streamMatchingCalls = 0;
static int streamDeviceSteps[8];
static int streamInterfaceSteps = 0;
static int streamOpenCalls = 0, streamCloseCalls = 0;
static int streamPipePropertyCalls = 0, streamPipeBeforeOpen = 0;
static int streamInterfaceReleases = 0, streamDeviceReleases = 0;
static IOReturn streamFakeOpenResult = kIOReturnSuccess;
static IOReturn streamCloseResult = kIOReturnSuccess;
static UInt8 streamEndpointNumber = 2;
static UInt8 streamEndpointDirection = kUSBIn;
static UInt8 streamEndpointTransfer = kUSBBulk;
static UInt16 streamEndpointPacketSize = 512;

typedef struct {
    IOUSBInterfaceInterface220 *interface;
    IOUSBInterfaceInterface220 methods;
    BOOL opened;
} FakeStreamInterface;

typedef struct {
    IOUSBDeviceInterface *device;
    IOUSBDeviceInterface methods;
} FakeStreamDevice;

static FakeStreamInterface fakeStreamInterface;
static FakeStreamDevice fakeStreamDevice;
static int streamLastPluginKind = 0;

static CFDictionaryRef StreamIOServiceMatching(const char *name) {
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                     &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
}

static kern_return_t StreamMatchingServices(mach_port_t port,
                                             CFDictionaryRef matching,
                                             io_iterator_t *iterator) {
    (void)port;
    assert(matching != NULL && iterator != NULL);
    CFRelease(matching);
    streamMatchingCalls++;
    assert(streamMatchingCalls < 8);
    *iterator = streamDeviceIteratorBase + streamMatchingCalls;
    streamDeviceSteps[streamMatchingCalls] = 0;
    return KERN_SUCCESS;
}

static io_object_t StreamIteratorNext(io_iterator_t iterator) {
    if (iterator >= streamDeviceIteratorBase + 1 &&
        iterator < streamDeviceIteratorBase + 8) {
        int index = (int)(iterator - streamDeviceIteratorBase);
        if (streamDeviceSteps[index]++ == 0) return streamDeviceService;
        return IO_OBJECT_NULL;
    }
    if (iterator == streamInterfaceIterator) {
        return streamInterfaceSteps++ == 0
            ? streamInterfaceService : IO_OBJECT_NULL;
    }
    assert(!"unexpected fake iterator");
    return IO_OBJECT_NULL;
}

static kern_return_t StreamObjectRelease(io_object_t object) {
    if (object == streamDeviceService) streamDeviceReleases++;
    if (object == streamInterfaceService) streamDeviceReleases++;
    return KERN_SUCCESS;
}

static CFTypeRef StreamProperty(io_registry_entry_t entry,
                                CFStringRef key, CFAllocatorRef allocator,
                                IOOptionBits options) {
    (void)allocator; (void)options;
    assert(entry == streamDeviceService);
    int64_t value = 0;
    if (CFEqual(key, CFSTR("locationID"))) value = 0x01100000;
    else if (CFEqual(key, CFSTR("idVendor"))) value = 0x2ca3;
    else if (CFEqual(key, CFSTR("idProduct"))) value = 0x0023;
    else return NULL;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
}

static kern_return_t StreamRegistryID(io_registry_entry_t entry,
                                      uint64_t *value) {
    assert(entry == streamDeviceService && value != NULL);
    *value = 1;
    return KERN_SUCCESS;
}

static int StreamSysctl(const char *name, void *old, size_t *oldLength,
                        void *newValue, size_t newLength) {
    assert(strcmp(name, "kern.bootsessionuuid") == 0);
    assert(old != NULL && oldLength != NULL && newValue == NULL && newLength == 0);
    const char *boot = "stream-boot";
    assert(*oldLength >= strlen(boot) + 1);
    strcpy(old, boot);
    *oldLength = strlen(boot) + 1;
    return 0;
}

static IOReturn StreamDeviceCreateInterfaceIterator(
    void *self, IOUSBFindInterfaceRequest *request, io_iterator_t *iterator) {
    FakeStreamDevice *device = self;
    assert(device == &fakeStreamDevice);
    assert(request->bInterfaceClass == kUSBVideoInterfaceClass);
    assert(request->bInterfaceSubClass == kUSBVideoStreamingSubClass);
    assert(request->bAlternateSetting == 0);
    assert(iterator != NULL);
    streamInterfaceSteps = 0;
    *iterator = streamInterfaceIterator;
    return kIOReturnSuccess;
}

static ULONG StreamDeviceRelease(void *self) {
    assert(self == &fakeStreamDevice);
    return 0;
}

static IOReturn StreamInterfaceNumber(void *self, UInt8 *number) {
    assert(self == &fakeStreamInterface && number != NULL);
    *number = 1;
    return kIOReturnSuccess;
}

static IOReturn StreamInterfaceAlternate(void *self, UInt8 *alternate) {
    assert(self == &fakeStreamInterface && alternate != NULL);
    *alternate = 0;
    return kIOReturnSuccess;
}

static IOReturn StreamInterfaceEndpointCount(void *self, UInt8 *count) {
    assert(self == &fakeStreamInterface && count != NULL);
    *count = 1;
    return kIOReturnSuccess;
}

static IOReturn StreamInterfacePipeProperties(void *self, UInt8 pipe,
                                              UInt8 *direction, UInt8 *number,
                                              UInt8 *transferType,
                                              UInt16 *maxPacketSize,
                                              UInt8 *interval) {
    FakeStreamInterface *interface = self;
    assert(interface == &fakeStreamInterface && pipe == 1);
    streamPipePropertyCalls++;
    if (!interface->opened) streamPipeBeforeOpen++;
    assert(interface->opened); // Regression: pipe properties require ownership.
    *direction = streamEndpointDirection;
    *number = streamEndpointNumber;
    *transferType = streamEndpointTransfer;
    *maxPacketSize = streamEndpointPacketSize;
    *interval = 0;
    return kIOReturnSuccess;
}

static IOReturn StreamInterfaceOpen(void *self) {
    FakeStreamInterface *interface = self;
    assert(interface == &fakeStreamInterface);
    streamOpenCalls++;
    if (streamFakeOpenResult == kIOReturnSuccess) interface->opened = YES;
    return streamFakeOpenResult;
}

static IOReturn StreamInterfaceClose(void *self) {
    FakeStreamInterface *interface = self;
    assert(interface == &fakeStreamInterface && interface->opened);
    streamCloseCalls++;
    interface->opened = NO;
    return streamCloseResult;
}

static ULONG StreamInterfaceRelease(void *self) {
    FakeStreamInterface *interface = self;
    assert(interface == &fakeStreamInterface);
    streamInterfaceReleases++;
    interface->opened = NO;
    return 0;
}

static HRESULT StreamPluginQuery(void *self, REFIID iid, LPVOID *result) {
    (void)self;
    (void)iid;
    assert(result != NULL);
    if (streamLastPluginKind == 1) {
        *result = (LPVOID)&fakeStreamDevice.device;
    } else {
        assert(streamLastPluginKind == 2);
        *result = (LPVOID)&fakeStreamInterface.interface;
    }
    return S_OK;
}

static ULONG StreamPluginAddRef(void *self) { return 1; }
static ULONG StreamPluginRelease(void *self) { return 0; }

static IOCFPlugInInterface streamDevicePluginMethods;
static IOCFPlugInInterface streamInterfacePluginMethods;
static IOCFPlugInInterface *streamDevicePlugin = &streamDevicePluginMethods;
static IOCFPlugInInterface *streamInterfacePlugin = &streamInterfacePluginMethods;

static kern_return_t StreamCreatePlugin(io_service_t service,
                                        CFUUIDRef pluginType,
                                        CFUUIDRef interfaceType,
                                        IOCFPlugInInterface ***plugin,
                                        SInt32 *score) {
    (void)interfaceType;
    assert(plugin != NULL && score != NULL);
    *score = 0;
    if (service == streamDeviceService &&
        CFEqual(pluginType, kIOUSBDeviceUserClientTypeID)) {
        streamLastPluginKind = 1;
        *plugin = &streamDevicePlugin;
        return kIOReturnSuccess;
    }
    if (service == streamInterfaceService &&
        CFEqual(pluginType, kIOUSBInterfaceUserClientTypeID)) {
        streamLastPluginKind = 2;
        *plugin = &streamInterfacePlugin;
        return kIOReturnSuccess;
    }
    return kIOReturnError;
}

static kern_return_t StreamDestroyPlugin(IOCFPlugInInterface **plugin) {
    (void)plugin;
    return KERN_SUCCESS;
}

#undef IOServiceMatching
#undef IOServiceGetMatchingServices
#undef IOIteratorNext
#undef IOObjectRelease
#undef IORegistryEntryCreateCFProperty
#undef IORegistryEntryGetRegistryEntryID
#undef sysctlbyname
#undef IOCreatePlugInInterfaceForService
#undef IODestroyPlugInInterface
#define IOServiceMatching StreamIOServiceMatching
#define IOServiceGetMatchingServices StreamMatchingServices
#define IOIteratorNext StreamIteratorNext
#define IOObjectRelease StreamObjectRelease
#define IORegistryEntryCreateCFProperty StreamProperty
#define IORegistryEntryGetRegistryEntryID StreamRegistryID
#define sysctlbyname StreamSysctl
#define IOCreatePlugInInterfaceForService StreamCreatePlugin
#define IODestroyPlugInInterface StreamDestroyPlugin

#include "../../Sources/Pocket3UVC/P3UVC.m"

static void prepareStreamFake(void) {
    memset(&fakeStreamInterface, 0, sizeof(fakeStreamInterface));
    memset(&fakeStreamDevice, 0, sizeof(fakeStreamDevice));
    fakeStreamInterface.interface = &fakeStreamInterface.methods;
    fakeStreamInterface.methods.GetInterfaceNumber = StreamInterfaceNumber;
    fakeStreamInterface.methods.GetAlternateSetting = StreamInterfaceAlternate;
    fakeStreamInterface.methods.GetNumEndpoints = StreamInterfaceEndpointCount;
    fakeStreamInterface.methods.GetPipeProperties = StreamInterfacePipeProperties;
    fakeStreamInterface.methods.USBInterfaceOpen = StreamInterfaceOpen;
    fakeStreamInterface.methods.USBInterfaceClose = StreamInterfaceClose;
    fakeStreamInterface.methods.Release = StreamInterfaceRelease;
    fakeStreamDevice.device = &fakeStreamDevice.methods;
    fakeStreamDevice.methods.CreateInterfaceIterator = StreamDeviceCreateInterfaceIterator;
    fakeStreamDevice.methods.Release = StreamDeviceRelease;
    streamDevicePluginMethods.QueryInterface = StreamPluginQuery;
    streamDevicePluginMethods.AddRef = StreamPluginAddRef;
    streamDevicePluginMethods.Release = StreamPluginRelease;
    streamInterfacePluginMethods.QueryInterface = StreamPluginQuery;
    streamInterfacePluginMethods.AddRef = StreamPluginAddRef;
    streamInterfacePluginMethods.Release = StreamPluginRelease;
    streamMatchingCalls = 0;
    memset(streamDeviceSteps, 0, sizeof(streamDeviceSteps));
    streamInterfaceSteps = 0;
    streamOpenCalls = streamCloseCalls = streamPipePropertyCalls = 0;
    streamPipeBeforeOpen = streamInterfaceReleases = streamDeviceReleases = 0;
    streamFakeOpenResult = kIOReturnSuccess;
    streamCloseResult = kIOReturnSuccess;
    streamEndpointNumber = 2;
    streamEndpointDirection = kUSBIn;
    streamEndpointTransfer = kUSBBulk;
    streamEndpointPacketSize = 512;
}

static NSDictionary *StreamResult(char *raw) {
    assert(raw != NULL);
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    p3_uvc_free(raw);
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data
                                                              options:0 error:NULL];
    assert([value isKindOfClass:[NSDictionary class]]);
    return value;
}

int main(void) {
    @autoreleasepool {
        int cases = 0;
        prepareStreamFake();
        P3UVCStreamSession *session = NULL;
        NSDictionary *opened = StreamResult(p3_uvc_stream_session_open(
            0x01100000, 1, 0, 0x82, &session));
        assert([opened[@"opened"] boolValue] && session != NULL);
        assert(streamOpenCalls == 1 && streamPipePropertyCalls == 1);
        assert(streamPipeBeforeOpen == 0);
        assert([opened[@"endpointCount"] intValue] == 1);
        assert([opened[@"endpoints"][0][@"address"] intValue] == 0x82);
        assert([opened[@"endpoints"][0][@"direction"] intValue] == 1);
        NSDictionary *status = StreamResult(p3_uvc_stream_session_status(session));
        assert([status[@"opened"] boolValue] && [status[@"ownedOpen"] boolValue]);
        NSDictionary *closed = StreamResult(p3_uvc_stream_session_close(session));
        assert([closed[@"closed"] boolValue] && [closed[@"interfaceReleased"] boolValue]);
        assert(streamCloseCalls == 1 && streamInterfaceReleases == 1);
        cases++;

        // A post-open endpoint mismatch must close the owned interface before
        // publishing no session pointer.
        prepareStreamFake();
        streamEndpointNumber = 3;
        session = NULL;
        NSDictionary *mismatch = StreamResult(p3_uvc_stream_session_open(
            0x01100000, 1, 0, 0x82, &session));
        assert(session == NULL);
        assert([mismatch[@"error"] isEqual:@"uvc_stream_endpoint_unavailable"]);
        assert([mismatch[@"opened"] boolValue] && [mismatch[@"closed"] boolValue]);
        assert(streamOpenCalls == 1 && streamPipePropertyCalls == 1 &&
               streamPipeBeforeOpen == 0 && streamCloseCalls == 1 &&
               streamInterfaceReleases == 1);
        cases++;

        // Exclusive access is a foreign system owner. Never close a borrowed
        // interface and never publish a direct handle.
        prepareStreamFake();
        streamFakeOpenResult = kIOReturnExclusiveAccess;
        session = NULL;
        NSDictionary *busy = StreamResult(p3_uvc_stream_session_open(
            0x01100000, 1, 0, 0x82, &session));
        assert(session == NULL && [busy[@"error"] isEqual:@"uvc_stream_busy"]);
        assert(streamOpenCalls == 1 && streamPipePropertyCalls == 0 &&
               streamCloseCalls == 0 && streamInterfaceReleases == 1);
        cases++;

        printf("{\"passed\":true,\"cases\":%d,\"openBeforePipeProperties\":true,\"mismatchClosesOwnedInterface\":true,\"exclusiveAccessNeverBorrowed\":true,\"hardwareAccess\":false}\n", cases);
    }
    return 0;
}

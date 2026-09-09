// Standalone MRC test harness. All registry lookups and device initialization
// are replaced before any factory runs; this never opens a USB device.
#import "UVCController.h"
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>

static const io_service_t fakeService = 1234;
static const io_iterator_t fakeIterator = 5678;
static int serviceReferences = 0, matchingAcquisitions = 0, serviceReleases = 0;
static int iteratorReferences = 0, iteratorStep = 0;
static int controllerDeallocations = 0, controlDeallocations = 0, fakeReads = 0;
static BOOL initializationSucceeds = YES;

static io_service_t FakeMatchingService(mach_port_t port, CFDictionaryRef matching) {
    CFRelease(matching); serviceReferences++; matchingAcquisitions++; return fakeService;
}
static kern_return_t FakeMatchingServices(mach_port_t port, CFDictionaryRef matching, io_iterator_t *iterator) {
    CFRelease(matching); *iterator = fakeIterator; iteratorReferences++; iteratorStep = 0; return KERN_SUCCESS;
}
static io_object_t FakeIteratorNext(io_iterator_t iterator) {
    assert(iterator == fakeIterator);
    if (iteratorStep++) return IO_OBJECT_NULL;
    serviceReferences++; matchingAcquisitions++; return fakeService;
}
static kern_return_t FakeRelease(io_object_t object) {
    if (object == fakeService) { assert(serviceReferences > 0); serviceReferences--; serviceReleases++; }
    else { assert(object == fakeIterator && iteratorReferences > 0); iteratorReferences--; }
    return KERN_SUCCESS;
}
static kern_return_t FakeRetain(io_object_t object) {
    assert(object == fakeService); serviceReferences++; return KERN_SUCCESS;
}
static kern_return_t FakeName(io_registry_entry_t entry, io_name_t name) {
    assert(entry == fakeService && serviceReferences > 0); strcpy(name, "No hardware test camera"); return KERN_SUCCESS;
}
static CFTypeRef FakeProperty(io_registry_entry_t entry, const io_name_t plane, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    assert(entry == fakeService && serviceReferences > 0);
    int value = CFEqual(key, CFSTR(kUSBVendorID)) ? 0x2ca3 : CFEqual(key, CFSTR(kUSBProductID)) ? 0x23 : 0x01100000;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

#define IOServiceGetMatchingService FakeMatchingService
#define IOServiceGetMatchingServices FakeMatchingServices
#define IOIteratorNext FakeIteratorNext
#define IOObjectRelease FakeRelease
#define IOObjectRetain FakeRetain
#define IORegistryEntryGetName FakeName
#define IORegistryEntrySearchCFProperty FakeProperty
#include "../../Sources/Pocket3UVC/UVCController.m"

static IMP originalControllerDealloc, originalControlDealloc;
static BOOL FakeFindInterface(id object, SEL selector, io_service_t service) {
    assert(service == fakeService && serviceReferences > 0); return initializationSucceeds;
}
static BOOL FakeCapabilities(id object, SEL selector, NSUInteger *capabilities, NSUInteger control) {
    *capabilities = 3; return YES;
}
static void FakeRange(id object, SEL selector, UVCValue **low, UVCValue **high, UVCValue **step, UVCValue **standard, NSUInteger *capabilities, NSUInteger control) {
    *low = nil; *high = nil; *step = nil; *standard = nil;
}
static BOOL FakeRead(id object, SEL selector, UVCValue *value, NSUInteger control) {
    fakeReads++; return YES;
}
static void CountControllerDealloc(id object, SEL selector) {
    controllerDeallocations++; ((void (*)(id, SEL))originalControllerDealloc)(object, selector);
}
static void CountControlDealloc(id object, SEL selector) {
    controlDeallocations++; ((void (*)(id, SEL))originalControlDealloc)(object, selector);
}
static IMP replace(Class type, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(type, selector); assert(method != NULL);
    return method_setImplementation(method, implementation);
}

int main(void) {
    @autoreleasepool {
        replace([UVCController class], @selector(findControllerInterfaceForServiceObject:), (IMP)FakeFindInterface);
        replace([UVCController class], @selector(capabilities:forControl:), (IMP)FakeCapabilities);
        replace([UVCController class], @selector(getLowValue:highValue:stepSize:defaultValue:updateCapabilitiesBitmask:forControl:), (IMP)FakeRange);
        replace([UVCController class], @selector(getValue:forControl:), (IMP)FakeRead);
        originalControllerDealloc = replace([UVCController class], @selector(dealloc), (IMP)CountControllerDealloc);
        originalControlDealloc = replace([UVCControl class], @selector(dealloc), (IMP)CountControlDealloc);

        // Current pool retains neither side after return values drain.
        for (int iteration = 0; iteration < 1000; iteration++) {
            int controllersBefore = controllerDeallocations, controlsBefore = controlDeallocations;
            @autoreleasepool {
                UVCController *controller = [UVCController uvcControllerWithLocationId:0x01100000];
                UVCControl *control = [controller controlWithName:@"pan-tilt-abs"];
                assert(control != nil && control == [controller controlWithName:@"pan-tilt-abs"]);
            }
            assert(controllerDeallocations == controllersBefore + 1);
            assert(controlDeallocations == controlsBefore + 1);
            assert(serviceReferences == 0);
        }

        // Public callers may retain a control after their controller is gone.
        int controllersBefore = controllerDeallocations, controlsBefore = controlDeallocations;
        UVCControl *standalone = nil;
        @autoreleasepool {
            UVCController *controller = [UVCController uvcControllerWithLocationId:0x01100000];
            standalone = [[controller controlWithName:@"pan-tilt-abs"] retain];
        }
        assert(controllerDeallocations == controllersBefore && controlDeallocations == controlsBefore);
        @autoreleasepool { assert([standalone currentValue] != nil); }
        assert(fakeReads == 1);
        [standalone release];
        assert(controllerDeallocations == controllersBefore + 1 && controlDeallocations == controlsBefore + 1);

        // A retained parent must safely recreate controls after weak values clear.
        UVCController *retainedController = nil;
        @autoreleasepool {
            retainedController = [[UVCController uvcControllerWithLocationId:0x01100000] retain];
            assert([retainedController controlWithName:@"pan-tilt-abs"] != nil);
        }
        controlsBefore = controlDeallocations;
        @autoreleasepool {
            NSMutableString *name = [NSMutableString stringWithString:@"pan-tilt-abs"];
            UVCControl *replacement = [retainedController controlWithName:name];
            assert(replacement != nil);
            [name setString:@"changed by caller"];
            assert([retainedController controlWithName:@"pan-tilt-abs"] == replacement);
        }
        assert(controlDeallocations == controlsBefore + 1);
        [retainedController release];

        // Every factory balances acquired services on both success and failure;
        // withService borrows the caller's existing reference instead.
        for (int success = 0; success < 2; success++) {
            initializationSucceeds = success;
            @autoreleasepool {
                assert(([UVCController uvcControllerWithLocationId:0x01100000] != nil) == success);
                assert(serviceReferences == 0);
                assert(([UVCController uvcControllerWithVendorId:0x2ca3 productId:0x23] != nil) == success);
                assert(serviceReferences == 0);
                serviceReferences++;
                assert(([UVCController uvcControllerWithService:fakeService] != nil) == success);
                assert(serviceReferences == 1);
                FakeRelease(fakeService);
                NSArray *controllers = [UVCController uvcControllers];
                assert((controllers.count == 1) == success);
                assert(serviceReferences == 0 && iteratorReferences == 0);
            }
        }
        assert(serviceReferences == 0 && iteratorReferences == 0);
        assert(serviceReleases == matchingAcquisitions + 2); // Two explicit callers.
        printf("{\"passed\":true,\"autoreleaseIterations\":1000,\"standaloneControlLifetime\":true,\"weakCacheRecreation\":true,\"factoryOwnershipSuccessAndFailure\":true,\"registryReferencesRemaining\":%d,\"controllerDeallocations\":%d,\"controlDeallocations\":%d,\"hardwareAccess\":false}\n", serviceReferences, controllerDeallocations, controlDeallocations);
    }
    return 0;
}

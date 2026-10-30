#import "Native.h"
#import <IOUSBHost/IOUSBHost.h>

static const uint16_t kGoogle = 0x18D1, kSamsung = 0x04E8;
static const uint8_t kGetProtocol = 51, kSendString = 52, kStart = 53;
static const NSTimeInterval kSwitchWait = 10;  // seconds for the tablet to come back as an accessory

static NSError *Error(NSString *message) {
    return [NSError errorWithDomain:@"Screenlet" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The first IOService of class with these properties, or 0. Uses
/// IOPropertyMatch, because a plain idVendor key only matches in a driver's
/// personality.
static io_service_t First(const char *class, NSDictionary *properties) {
    CFMutableDictionaryRef matching = IOServiceMatching(class);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)properties);
    return IOServiceGetMatchingService(kIOMainPortDefault, matching);  // consumes matching
}

static io_service_t AccessoryDevice(void) {
    return First("IOUSBHostDevice", @{@"idVendor": @(kGoogle), @"idProduct": @0x2D01})
        ?: First("IOUSBHostDevice", @{@"idVendor": @(kGoogle), @"idProduct": @0x2D00});
}

static io_service_t AccessoryInterface(void) {
    return First("IOUSBHostInterface", @{@"idVendor": @(kGoogle), @"idProduct": @0x2D01, @"bInterfaceNumber": @0})
        ?: First("IOUSBHostInterface", @{@"idVendor": @(kGoogle), @"idProduct": @0x2D00, @"bInterfaceNumber": @0});
}

// Samsung's vendor ID only. Other makers can be added when needed.
static io_service_t SamsungDevice(void) {
    return First("IOUSBHostDevice", @{@"idVendor": @(kSamsung)});
}

static IOUSBDeviceRequest Request(uint8_t type, uint8_t request, uint16_t index, uint16_t length) {
    IOUSBDeviceRequest r = {.bmRequestType = type, .bRequest = request, .wValue = 0, .wIndex = index, .wLength = length};
    return r;
}

@implementation POAccessory {
    IOUSBHostInterface *_interface;
    IOUSBHostPipe *_in, *_out;
    NSUInteger _packet;
}

+ (BOOL)tabletPresent {
    io_service_t found = AccessoryDevice() ?: SamsungDevice();
    if (found) IOObjectRelease(found);
    return found != 0;
}

- (instancetype)initWithIdentity:(NSArray<NSString *> *)identity error:(NSError **)error {
    if (!(self = [super init])) return nil;
    io_service_t device = AccessoryDevice();
    if (device) {
        // Still an accessory from an earlier session, possibly mid-frame. Reset
        // it so both ends start clean. Android then either leaves accessory mode
        // (and is asked again below) or stays in it and the app reopens it.
        NSLog(@"usb: the tablet was an accessory already: reset");
        IOUSBHostDevice *open = [[IOUSBHostDevice alloc] initWithIOService:device options:0 queue:nil error:nil
                                                           interestHandler:nil];
        [open resetWithError:nil];
        [open destroy];
        IOObjectRelease(device);
        device = 0;
        // It comes back shortly, either still as the accessory or as itself.
        for (int tries = 0; tries < 50 && !device; tries++) {
            [NSThread sleepForTimeInterval:0.1];
            if (tries >= 5 && (device = AccessoryDevice())) break;
            io_service_t samsung = tries >= 5 ? SamsungDevice() : 0;
            if (samsung) {
                IOObjectRelease(samsung);
                break;
            }
        }
    }
    if (!device && ![self switchTablet:identity error:error]) return nil;
    if (device) IOObjectRelease(device);
    return [self openInterface:error] ? self : nil;
}

/// Asks the tablet to switch to accessory mode and waits for it to reappear.
- (BOOL)switchTablet:(NSArray<NSString *> *)identity error:(NSError **)error {
    io_service_t service = SamsungDevice();
    if (!service) {
        if (error) *error = Error(@"no tablet on the cable");
        return NO;
    }
    NSError *why = nil;
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service options:0 queue:nil error:&why
                                                         interestHandler:nil];
    IOObjectRelease(service);
    if (!device) {
        if (error) *error = Error([NSString stringWithFormat:@"the tablet's USB is busy (%@)", why.localizedDescription]);
        return NO;
    }
    NSMutableData *version = [NSMutableData dataWithLength:2];
    BOOL ok = [device sendDeviceRequest:Request(0xC0, kGetProtocol, 0, 2) data:version bytesTransferred:nil
                      completionTimeout:2 error:&why];
    const uint8_t *v = version.bytes;
    if (!ok || !(v[0] | v[1] << 8)) {
        [device destroy];
        if (error) *error = Error(@"the tablet cannot be an accessory (Android Open Accessory)");
        return NO;
    }
    for (NSUInteger i = 0; i < identity.count && ok; i++) {
        NSMutableData *text = [[identity[i] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [text appendBytes:"" length:1];
        ok = [device sendDeviceRequest:Request(0x40, kSendString, (uint16_t)i, (uint16_t)text.length) data:text
                      bytesTransferred:nil completionTimeout:2 error:&why];
    }
    ok = ok && [device sendDeviceRequest:Request(0x40, kStart, 0, 0) data:nil bytesTransferred:nil
                       completionTimeout:2 error:&why];
    [device destroy];
    if (!ok) {
        if (error) *error = Error([NSString stringWithFormat:@"the tablet did not take the request (%@)", why.localizedDescription]);
        return NO;
    }
    NSLog(@"usb: asked the tablet to be Screenlet's accessory");
    for (NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kSwitchWait]; deadline.timeIntervalSinceNow > 0;) {
        [NSThread sleepForTimeInterval:0.3];
        io_service_t found = AccessoryDevice();
        if (found) {
            IOObjectRelease(found);
            return YES;
        }
    }
    if (error) *error = Error(@"the tablet did not come back as an accessory");
    return NO;
}

/// Opens interface 0 and its two bulk pipes, configuring the device first if
/// macOS has not.
- (BOOL)openInterface:(NSError **)error {
    io_service_t service = 0;
    for (int tries = 0; tries < 20 && !(service = AccessoryInterface()); tries++) {
        if (tries == 0) {
            io_service_t device = AccessoryDevice();
            IOUSBHostDevice *open = device ? [[IOUSBHostDevice alloc] initWithIOService:device options:0 queue:nil
                                                                                 error:nil interestHandler:nil] : nil;
            [open configureWithValue:1 matchInterfaces:YES error:nil];
            [open destroy];
            if (device) IOObjectRelease(device);
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    if (!service) {
        if (error) *error = Error(@"the accessory has no interface");
        return NO;
    }
    NSError *why = nil;
    _interface = [[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&why
                                               interestHandler:nil];
    IOObjectRelease(service);
    if (!_interface) {
        if (error) *error = Error([NSString stringWithFormat:@"the accessory is busy (%@)", why.localizedDescription]);
        return NO;
    }
    const IOUSBConfigurationDescriptor *config = _interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *iface = _interface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(config, iface, (const IOUSBDescriptorHeader *)ep))) {
        if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeBulk) continue;
        IOUSBHostPipe *pipe = [_interface copyPipeWithAddress:IOUSBGetEndpointAddress(ep) error:nil];
        if (IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn) {
            _in = pipe;
        } else {
            _out = pipe;
            _packet = IOUSBGetEndpointMaxPacketSize(kIOUSBHostConnectionSpeedHigh, ep);
        }
    }
    if (!_in || !_out) {
        if (error) *error = Error(@"the accessory has no bulk pipes");
        [self close];
        return NO;
    }
    return YES;
}

- (NSInteger)read:(NSMutableData *)buffer timeout:(NSTimeInterval)timeout error:(NSError **)error {
    NSUInteger n = 0;
    NSError *why = nil;
    if ([_in sendIORequestWithData:buffer bytesTransferred:&n completionTimeout:timeout error:&why]) return (NSInteger)n;
    if (why.code == kIOReturnTimeout || why.code == kUSBHostReturnPipeStalled) {
        if (why.code == kUSBHostReturnPipeStalled) [_in clearStallWithError:nil];
        return (NSInteger)n;
    }
    if (error) *error = why;
    return -1;
}

- (BOOL)write:(NSData *)data timeout:(NSTimeInterval)timeout error:(NSError **)error {
    NSMutableData *copy = [data mutableCopy];
    if (![_out sendIORequestWithData:copy bytesTransferred:nil completionTimeout:timeout error:error]) return NO;
    // A transfer ends on a short packet, so one that ends on a full packet needs an empty one.
    if (_packet && data.length % _packet == 0) {
        return [_out sendIORequestWithData:nil bytesTransferred:nil completionTimeout:timeout error:error];
    }
    return YES;
}

- (void)close {
    [_in abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [_out abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [_interface destroy];
    _interface = nil;
    _in = _out = nil;
}

@end

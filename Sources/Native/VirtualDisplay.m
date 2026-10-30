#import "Native.h"

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nullable) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property unsigned int productID;
@property unsigned int vendorID;
@property unsigned int serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray *modes;
@property unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

@implementation ScreenletVirtualDisplay {
    CGVirtualDisplay *_display;  // released with this object, removing the display
}

- (instancetype)initWithPixels:(CGSize)pixels points:(CGSize)points refreshRate:(double)refreshRate
                          name:(NSString *)name vendor:(uint32_t)vendor product:(uint32_t)product {
    if (!(self = [super init])) return nil;
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned)pixels.width;
    descriptor.maxPixelsHigh = (unsigned)pixels.height;
    // 110 points per inch, so text looks the size it does on a laptop.
    descriptor.sizeInMillimeters = CGSizeMake(points.width * 25.4 / 110, points.height * 25.4 / 110);
    descriptor.vendorID = vendor;
    descriptor.productID = product;
    // Serial 1 lets macOS remember where the user placed the display. If a
    // display from an earlier session still holds it, try the next one.
    for (unsigned serial = 1; serial <= 8 && !_display; serial++) {
        descriptor.serialNum = serial;
        _display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    }
    if (!_display) return nil;
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = points.width < pixels.width ? 1 : 0;
    // The tablet's refresh rate (and 60 as a fallback mode): WindowServer
    // composes the display that often, so a change waits less to be captured.
    NSMutableArray *modes = [NSMutableArray arrayWithObject:[[CGVirtualDisplayMode alloc]
        initWithWidth:(NSUInteger)points.width height:(NSUInteger)points.height refreshRate:refreshRate]];
    if (refreshRate != 60) {
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(NSUInteger)points.width
                                                              height:(NSUInteger)points.height refreshRate:60]];
    }
    settings.modes = modes;
    if (![_display applySettings:settings]) return nil;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end

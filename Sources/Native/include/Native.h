// The parts Swift cannot reach easily: virtual displays through
// CGVirtualDisplay, a private CoreGraphics API that a macOS update may
// change, and the tablet as a USB accessory through IOUSBHost.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenletVirtualDisplay : NSObject
/// A display of the given size in pixels, laid out in points (half the pixels
/// when HiDPI). Returns nil if macOS refuses to create it.
- (nullable instancetype)initWithPixels:(CGSize)pixels points:(CGSize)points refreshRate:(double)refreshRate
                                   name:(NSString *)name vendor:(uint32_t)vendor product:(uint32_t)product;
@property (readonly) CGDirectDisplayID displayID;
@end

/// The tablet as a USB accessory (Android Open Accessory). The Mac is the
/// USB host, with one bulk pipe in each direction.
@interface ScreenletAccessory : NSObject
/// Whether an Android device of a known maker, or one already in accessory mode, is connected.
+ (BOOL)tabletPresent;
/// Opens the accessory, switching the tablet to accessory mode first if needed.
/// identity is manufacturer, model, description, version, URI and serial. Blocks.
- (nullable instancetype)initWithIdentity:(NSArray<NSString *> *)identity error:(NSError **)error;
/// Reads up to buffer's length. Returns the bytes read, 0 on timeout, -1 on error.
- (NSInteger)read:(NSMutableData *)buffer timeout:(NSTimeInterval)timeout error:(NSError **)error;
/// Writes all of data (not copied: it must stay unchanged until this returns),
/// adding a zero-length packet when it ends on a full one.
- (BOOL)write:(NSMutableData *)data timeout:(NSTimeInterval)timeout error:(NSError **)error;
- (void)close;
@end

NS_ASSUME_NONNULL_END

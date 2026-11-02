/**
 * Native interface bridging CoreGraphics virtual display management and IOUSBHost accessory communication.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Creates and manages a virtual display device backed by private CoreGraphics APIs.
 */
@interface POVirtualDisplay : NSObject
/**
 * Initializes a virtual display with the specified pixel dimensions, logical points, and refresh rate.
 *
 * @param pixels Pixel dimensions of the display buffer.
 * @param points Logical point dimensions determining HiDPI scaling factor.
 * @param refreshRate Target refresh rate in Hertz.
 * @param name Display device name presented to the system.
 * @param vendor Vendor identification code.
 * @param product Product identification code.
 * @return An initialized virtual display instance, or nil if creation failed.
 */
- (nullable instancetype)initWithPixels:(CGSize)pixels points:(CGSize)points refreshRate:(double)refreshRate
                                   name:(NSString *)name vendor:(uint32_t)vendor product:(uint32_t)product;
@property (readonly) CGDirectDisplayID displayID;
@end

/**
 * Manages USB accessory transport communication using IOUSBHost bulk endpoints.
 */
@interface POAccessory : NSObject
/**
 * Enumerates attached Android devices and active accessories matching supported vendor IDs.
 */
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)tablets;
/**
 * Opens a USB accessory connection to the specified tablet, initiating protocol negotiation if required.
 *
 * @param tablet Target tablet identifier, or nil for the first available device.
 * @param identity Accessory identification strings (manufacturer, model, description, version, URI, serial).
 * @param error Output pointer for error details upon failure.
 * @return An initialized accessory transport instance, or nil on failure.
 */
- (nullable instancetype)initWithTablet:(nullable NSString *)tablet identity:(NSArray<NSString *> *)identity
                                  error:(NSError **)error;
@property (readonly) NSString *key;
/**
 * Reads data from the input bulk pipe into the destination buffer up to the specified timeout.
 */
- (NSInteger)read:(NSMutableData *)buffer timeout:(NSTimeInterval)timeout error:(NSError **)error;
/**
 * Writes data to the output bulk pipe with automatic zero-length packet termination.
 */
- (BOOL)write:(NSMutableData *)data timeout:(NSTimeInterval)timeout error:(NSError **)error;
/**
 * Closes active USB pipe interfaces and releases underlying device claims.
 */
- (void)close;
@end

NS_ASSUME_NONNULL_END

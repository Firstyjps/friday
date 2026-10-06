#import <Foundation/Foundation.h>

/// รัน block แล้วดัก NSException (Swift `try` จับไม่ได้ — เช่น AVAudioEngine installTap ตอนอุปกรณ์เปลี่ยน)
/// คืน NO + error เมื่อมี exception แทนที่จะให้แอปตาย
BOOL FridayObjCTry(NS_NOESCAPE void (^_Nonnull block)(void), NSError *_Nullable *_Nullable error);

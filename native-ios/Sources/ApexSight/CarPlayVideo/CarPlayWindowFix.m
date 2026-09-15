// CarPlay full-screen window fix — PRIVATE API, SIDELOAD BUILDS ONLY.
//
// Compiled in only when APEX_CARPLAY_WINDOW is defined (scratchpad/sideload.sh passes it). The
// TestFlight / App Store pipeline never defines it, so the selector strings below never reach
// Apple's binary scanner. Even when compiled in, every selector is looked up at runtime and the
// swizzle is skipped (with a log line) if a future iOS renames it — nothing here can crash.
//
// What it does: asks CarPlay to hand the navigation scene a full-screen CPWindow and routes touches
// on that window to our view controller. It only has an effect when the app ALSO holds the
// com.apple.developer.carplay-maps entitlement (Apple-granted); without it CarPlay never creates
// the window and these methods are simply never consulted.
//
// Technique adapted from github.com/thomasdye12/TDS-Carplay (personal, non-commercial).

#ifdef APEX_CARPLAY_WINDOW

#import <CarPlay/CarPlay.h>
#import <objc/runtime.h>

static void ASSwizzle(Class cls, SEL original, SEL replacement) {
    Method o = class_getInstanceMethod(cls, original);
    Method r = class_getInstanceMethod(cls, replacement);
    if (!o || !r) { NSLog(@"[ApexSight] CarPlay window swizzle skipped: %@", NSStringFromSelector(original)); return; }
    if (class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r))) {
        class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o));
    } else {
        method_exchangeImplementations(o, r);
    }
}

@interface CPTemplateApplicationScene (ApexWindow)
@end

@implementation CPTemplateApplicationScene (ApexWindow)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ASSwizzle(self, NSSelectorFromString(@"_shouldCreateCarWindow"),  @selector(as_shouldCreateCarWindow));
        ASSwizzle(self, NSSelectorFromString(@"__supportsCarFullScreen"), @selector(as_supportsCarFullScreen));
    });
}
- (BOOL)as_shouldCreateCarWindow  { return YES; }
- (BOOL)as_supportsCarFullScreen  { return YES; }
@end

@interface CPWindow (ApexTouch)
@end

@implementation CPWindow (ApexTouch)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    return view ?: self.rootViewController.view;
}
- (BOOL)canBecomeFirstResponder { return YES; }
@end

#endif

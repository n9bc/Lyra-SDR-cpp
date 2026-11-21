// Lyra — Observatory window host.  See ObservatoryWindow.h.

#import <AppKit/AppKit.h>

#import "bridge/LyraEngineFacade.h"
#import "bridge/ObservatoryWindow.h"

// Strong statics: the C++ caller discards the returned objects, so under ARC
// nothing else would keep them alive past the next autorelease pool drain.
// There is only ever one Observatory window / facade per process.
static LyraEngineFacade *sFacade;
static NSWindow *sObservatoryWindow;

LyraEngineFacade *lyra_create_engine_facade(void *stream, void *dsp,
                                            void *meter)
{
    sFacade = [LyraEngineFacade facadeWithStream:stream dsp:dsp meter:meter];
    return sFacade;
}

NSWindow *lyra_show_observatory_window(LyraEngineFacade *facade)
{
    (void)facade;  // consumed by the Swift host once Task 6 links it in

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1200, 800)
                  styleMask:(NSWindowStyleMaskTitled
                             | NSWindowStyleMaskClosable
                             | NSWindowStyleMaskMiniaturizable
                             | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Lyra Observatory";
    window.releasedWhenClosed = NO;

    // TODO(Task 6): replace this placeholder with the NSHostingView returned
    // by the Swift ObservatoryHost once the Swift module builds under CMake.
    NSTextField *label = [NSTextField
        labelWithString:@"Observatory — Swift bridge pending"];
    label.alignment = NSTextAlignmentCenter;
    window.contentView = label;

    sObservatoryWindow = window;
    [window center];
    [window makeKeyAndOrderFront:nil];
    return window;
}

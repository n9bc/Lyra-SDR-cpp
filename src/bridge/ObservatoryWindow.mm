// Lyra — Observatory window host.  See ObservatoryWindow.h.

#import <AppKit/AppKit.h>

#import "bridge/LyraEngineFacade.h"
#import "bridge/ObservatoryWindow.h"
#import "Observatory-Swift.h"

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

    NSView *hostingView = [ObservatoryHost createHostingViewWithFacade:facade];
    window.contentView = hostingView;

    sObservatoryWindow = window;
    [window center];
    [window makeKeyAndOrderFront:nil];
    return window;
}

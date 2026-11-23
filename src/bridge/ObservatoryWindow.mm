// Lyra — Observatory window host.  See ObservatoryWindow.h.

#import <AppKit/AppKit.h>

#import "bridge/LyraEngineFacade.h"
#import "bridge/ObservatoryWindow.h"
#import "Observatory-Swift.h"

#include "mainwindow.h"

// Strong statics: the C++ caller discards the returned objects, so under ARC
// nothing else would keep them alive past the next autorelease pool drain.
// There is only ever one Observatory window / facade per process.
static LyraEngineFacade *sFacade;
static NSWindow *sObservatoryWindow;
static lyra::ui::MainWindow *sHostWindow = nullptr;

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

    // Add a Settings menu item (Cmd+,) to the app menu.
    NSMenu *appMenu = [[NSApp mainMenu] itemAtIndex:0].submenu;
    if (appMenu) {
        NSMenuItem *settingsItem =
            [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                      action:@selector(lyraOpenSettings:)
                               keyEquivalent:@","];
        settingsItem.target = nil;  // first-responder chain
        [appMenu insertItem:settingsItem atIndex:1];
        [appMenu insertItem:[NSMenuItem separatorItem] atIndex:2];
    }

    sObservatoryWindow = window;
    [window center];
    [window makeKeyAndOrderFront:nil];
    return window;
}

void lyra_set_observatory_host(void *mainWindow)
{
    sHostWindow = static_cast<lyra::ui::MainWindow *>(mainWindow);
}

void lyra_raise_observatory_window(void)
{
    if (sObservatoryWindow) {
        [sObservatoryWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

void lyra_observatory_show_settings(void)
{
    if (sHostWindow)
        QMetaObject::invokeMethod(sHostWindow, "openSettings",
                                  Qt::QueuedConnection);
}

// NSApplication first-responder action for the Settings menu item.
@interface NSApplication (LyraObservatorySettings)
- (void)lyraOpenSettings:(id)sender;
@end

@implementation NSApplication (LyraObservatorySettings)
- (void)lyraOpenSettings:(id)sender
{
    lyra_observatory_show_settings();
}
@end

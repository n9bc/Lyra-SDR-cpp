// Lyra — Observatory window host.  See ObservatoryWindow.h.

#import <AppKit/AppKit.h>

#import "bridge/LyraEngineFacade.h"
#import "bridge/ObservatoryWindow.h"
#import "Observatory-Swift.h"

#include "mainwindow.h"

#include <QCoreApplication>
#include <QObject>

// Strong statics: the C++ caller discards the returned objects, so under ARC
// nothing else would keep them alive past the next autorelease pool drain.
// There is only ever one Observatory window / facade per process.
static LyraEngineFacade *sFacade;
static NSWindow *sObservatoryWindow;
static lyra::ui::MainWindow *sHostWindow = nullptr;

LyraEngineFacade *lyra_create_engine_facade(void *stream, void *dsp,
                                            void *meter, void *prefs,
                                            void *discovery, void *profiles)
{
    sFacade = [LyraEngineFacade facadeWithStream:stream
                                             dsp:dsp
                                           meter:meter
                                           prefs:prefs
                                       discovery:discovery
                                        profiles:profiles];
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

    // The console installs its own menus, Settings… ⌘, included
    // (ConsoleShell.installMenus), and re-installs them after Qt rebuilds the
    // menu bar.
    NSView *hostingView = [ObservatoryHost createHostingViewWithFacade:facade];
    window.contentView = hostingView;

    sObservatoryWindow = window;
    [window center];
    [window makeKeyAndOrderFront:nil];
    return window;
}

void lyra_set_observatory_host(void *mainWindow)
{
    sHostWindow = static_cast<lyra::ui::MainWindow *>(mainWindow);
    [sFacade attachHostWindow:mainWindow];

    // Drop the facade's Qt connections and engine pointers before the engine
    // objects are destroyed after app.exec() returns.  Order-independent among
    // the aboutToQuit handlers: -invalidate only disconnects and forgets, and
    // the engine objects all still exist while aboutToQuit runs.  (Connected
    // after main.cpp's teardown handlers, so in practice it runs after their
    // stream close; if it ran first, that close would just notify no one.)
    if (QCoreApplication *app = QCoreApplication::instance()) {
        QObject::connect(app, &QCoreApplication::aboutToQuit, app,
                         []() { [sFacade invalidate]; });
    }
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
    [sFacade openSettings];
}

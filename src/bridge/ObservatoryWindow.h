// Lyra — C-linkage entry points main.cpp uses to start the SwiftUI
// Observatory UI instead of the Qt MainWindow (LYRA_OBSERVATORY builds).
//
// Plain C declarations only, so the header is includable from C++ (main.cpp)
// and Obj-C++ alike.  Pointers are passed as void* for the same reason the
// facade factory takes them.

#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>
@class LyraEngineFacade;
@class NSWindow;
#endif

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __OBJC__
/// Creates the Obj-C++ facade from raw C++ pointers (HL2Stream*, WdspEngine*,
/// MeterModel*).  The facade does not own them.
LyraEngineFacade * _Nonnull lyra_create_engine_facade(
    void * _Nonnull stream,
    void * _Nonnull dsp,
    void * _Nonnull meter);

/// Creates, shows and returns (retained) the Observatory NSWindow.
NSWindow * _Nonnull lyra_show_observatory_window(
    LyraEngineFacade * _Nonnull facade);
#else
// C++ callers see opaque pointers.
void *lyra_create_engine_facade(void *stream, void *dsp, void *meter);
void *lyra_show_observatory_window(void *facade);
#endif

#ifdef __cplusplus
}
#endif

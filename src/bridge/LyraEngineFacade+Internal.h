// Lyra — the facade's C++ side, shared by LyraEngineFacade.mm (which owns the
// ivars) and LyraEngineFacadeConsole.mm (the Console category).  Obj-C++ only;
// never imported from Swift.

#pragma once

#import "bridge/LyraEngineFacade.h"

#include <QMetaObject>
#include <QString>

#include <vector>

namespace lyra::dsp { class WdspEngine; }
namespace lyra::ipc { class HL2Stream; class HL2Discovery; }
namespace lyra::profile { class ProfileManager; }
namespace lyra::ui { class MeterModel; class Prefs; class MainWindow; class BandMemory; }

NS_ASSUME_NONNULL_BEGIN

@interface LyraEngineFacade (Internal)

// Null after -invalidate (and, for host / bandMemory, until attached).
- (nullable lyra::ipc::HL2Stream *)engineStream;
- (nullable lyra::dsp::WdspEngine *)engineDsp;
- (nullable lyra::ui::MeterModel *)engineMeter;
- (nullable lyra::ui::Prefs *)enginePrefs;
- (nullable lyra::ipc::HL2Discovery *)engineDiscovery;
- (nullable lyra::profile::ProfileManager *)engineProfiles;
- (nullable lyra::ui::MainWindow *)engineHost;
- (void)setEngineHost:(nullable lyra::ui::MainWindow *)host;
- (nullable lyra::ui::BandMemory *)engineBandMemory;
- (void)setEngineBandMemory:(nullable lyra::ui::BandMemory *)bandMemory;

// The status bus's last text (kept by the Console category).
- (QString)lastStatusText;
- (void)setLastStatusText:(const QString &)text;

- (nullable LyraEngineChangeCallback)consoleChangeCallback;
- (void)setEngineChangeCallback:(nullable LyraEngineChangeCallback)callback;

// Qt connections -invalidate disconnects.
- (void)addEngineConnection:(const QMetaObject::Connection &)connection;

@end

// Implemented in LyraEngineFacadeConsole.mm.
@interface LyraEngineFacade (ConsoleInternal)

// The factory calls this once.
- (void)connectConsoleSignals;
// MainWindow::beginConnect (a no-op until the host window is attached).
- (void)beginConnectToIp:(NSString *)ip;
// Cancels a connect still waiting for the radio layer or the discovery
// sweep, and drops the sweep's connections.  -invalidate calls it.
- (void)cancelConsoleConnect;

@end

NS_ASSUME_NONNULL_END

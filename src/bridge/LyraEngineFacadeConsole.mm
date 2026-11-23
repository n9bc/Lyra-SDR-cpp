// Lyra — the facade's Console category: what the native console reads and
// calls (Observatory/Backend/EngineFacade.swift).  See LyraEngineFacade.h.
// Engine APIs per .superpowers/sdd/m3-engine-api-map.md §A-§C.  Main thread
// only.  Compiled with ARC (see CMakeLists.txt).

#import "bridge/LyraEngineFacade.h"
#import "bridge/LyraEngineFacade+Internal.h"

#include "bandmemory.h"
#include "hl2_discovery.h"
#include "hl2_stream.h"
#include "mainwindow.h"
#include "metermodel.h"
#include "prefs.h"
#include "profile/ProfileManager.h"
#include "rig/RigRegistry.h"
#include "statusbus.h"
#include "wdsp_engine.h"
#include "wire/P2RxBridge.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

#include <cmath>
#include <memory>

// wire/RadioNet.h pulls in win32_compat.h, whose BOOL clashes with Objective-C,
// so declare only the radio-layer pointer (create_rnet() sets it).
namespace lyra::wire {
class RadioNet;
extern RadioNet *prn;
}  // namespace lyra::wire

using lyra::dsp::WdspEngine;
using lyra::ipc::HL2Discovery;
using lyra::ipc::HL2Stream;
using lyra::profile::ProfileManager;
using lyra::ui::BandMemory;
using lyra::ui::MainWindow;
using lyra::ui::MeterModel;
using lyra::ui::Prefs;
using lyra::wire::P2RxBridge;

namespace {
// WDSP txaMeterType ordinals (wdsp_engine.h, WdspEngine::txMeterRaw), as
// MeterModel's TX level meters use them: MIC peak, ALC average.
constexpr int kTxaMicPk = 0;
constexpr int kTxaAlcAv = 13;

// Console connect state (one facade).  Each -connectRadio and -disconnectRadio
// bumps the generation, so a superseded readiness retry or sweep does nothing.
quint64 sConnectGeneration = 0;
QMetaObject::Connection sConsoleScanFound;
QMetaObject::Connection sConsoleScanDone;
constexpr int kRadioLayerRetryMs = 250;
constexpr int kRadioLayerRetries = 80;  // 20 s

void dropConsoleScan()
{
    QObject::disconnect(sConsoleScanFound);
    QObject::disconnect(sConsoleScanDone);
}

// The host's P2 bridge while a P2 session runs, else null.
P2RxBridge *runningP2(LyraEngineFacade *facade)
{
    MainWindow *host = [facade engineHost];
    P2RxBridge *p2 = host ? host->p2Bridge() : nullptr;
    return (p2 && p2->isRunning()) ? p2 : nullptr;
}
}  // namespace

@implementation LyraRadioReading
@end
@implementation LyraFilterReading
@end
@implementation LyraDspReading
@end
@implementation LyraFrontEndReading
@end
@implementation LyraAudioReading
@end
@implementation LyraMeterReading
@end
@implementation LyraTelemetryReading
@end
@implementation LyraTransmitReading
@end
@implementation LyraSessionReading
@end
@implementation LyraLinkReading
@end

@implementation LyraEngineFacade (ConsoleInternal)

#pragma mark Signals

- (void)connectConsoleSignals
{
    // Every signal maps to one EngineChange group; the console re-reads live.
    // The lambdas hold self weakly and -invalidate disconnects them.
    __weak LyraEngineFacade *weakSelf = self;

#define LYRA_CHANGE(sender, signal, group)                                   \
    do {                                                                     \
        if (sender) {                                                        \
            [self addEngineConnection:QObject::connect(                      \
                sender, signal, sender, [weakSelf]() {                       \
                    LyraEngineFacade *s = weakSelf;                          \
                    LyraEngineChangeCallback cb = [s consoleChangeCallback]; \
                    if (cb) cb(group);                                       \
                })];                                                         \
        }                                                                    \
    } while (0)

    HL2Stream *st = [self engineStream];
    WdspEngine *we = [self engineDsp];
    MeterModel *mm = [self engineMeter];
    Prefs *pr = [self enginePrefs];
    ProfileManager *pm = [self engineProfiles];

    const LyraEngineChange radio = LyraEngineChangeRadio;
    LYRA_CHANGE(st, &HL2Stream::runningChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::rx1FreqChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::rx2FreqChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::vfoBHzChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::subEnabledChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::focusedRxChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::splitEnabledChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::rptActiveChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::ritChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::xitChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::ctuneChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::lnaGainChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::autoLnaChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::adcOverloadChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::hl2RxPortChanged, radio);
    // Transmit state the console shows (never drives): on-air, inhibit, levels.
    LYRA_CHANGE(st, &HL2Stream::moxActiveChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::txDisplayActiveChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::txInhibitChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::txDriveLevelChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::micGainDbChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::voxEnabledChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::attOnTxEnabledChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::swrProtectEnabledChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::psArmedChanged, radio);
    LYRA_CHANGE(st, &HL2Stream::psFeedbackLevelChanged, radio);
    LYRA_CHANGE(we, &WdspEngine::markerOffsetChanged, radio);
    LYRA_CHANGE(pr, &Prefs::tuneDrivePctChanged, radio);

    const LyraEngineChange dsp = LyraEngineChangeDsp;
    LYRA_CHANGE(we, &WdspEngine::modeChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::modeRx2Changed, dsp);
    LYRA_CHANGE(we, &WdspEngine::bandwidthChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::bandwidthRx2Changed, dsp);
    LYRA_CHANGE(we, &WdspEngine::agcModeChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::agcThreshDbChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::nrChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::nbChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::binChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::anfChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::lmsChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::squelchChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::apfChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::notchesChanged, dsp);
    LYRA_CHANGE(we, &WdspEngine::spanChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::modeChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::modeRx2Changed, dsp);
    LYRA_CHANGE(pr, &Prefs::rxBandwidthChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::rx2BandwidthChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::filterLowChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::txFilterLowChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::txBandwidthChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::bwLockedChanged, dsp);
    LYRA_CHANGE(pr, &Prefs::sampleRateChanged, dsp);

    const LyraEngineChange audio = LyraEngineChangeAudio;
    LYRA_CHANGE(we, &WdspEngine::volumeChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::mutedChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::volumeRx2Changed, audio);
    LYRA_CHANGE(we, &WdspEngine::mutedRx2Changed, audio);
    LYRA_CHANGE(we, &WdspEngine::afGainChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::balanceChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::monEnabledChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::monVolumeChanged, audio);
    LYRA_CHANGE(we, &WdspEngine::audioDeviceChanged, audio);

    // AGC max gain notifies on levelsChanged (5 Hz); MeterModel ticks at 20 Hz.
    LYRA_CHANGE(we, &WdspEngine::levelsChanged, LyraEngineChangeMeters);
    LYRA_CHANGE(mm, &MeterModel::updated, LyraEngineChangeMeters);

    LYRA_CHANGE(st, &HL2Stream::statsChanged, LyraEngineChangeStats);
    LYRA_CHANGE(pr, &Prefs::autoStartOnLaunchChanged, LyraEngineChangeStats);

    LYRA_CHANGE(pm, &ProfileManager::activeChanged, LyraEngineChangeSession);
    LYRA_CHANGE(pm, &ProfileManager::modifiedChanged, LyraEngineChangeSession);

#undef LYRA_CHANGE
}

#pragma mark Connect

- (void)cancelConsoleConnect
{
    // A pending retry timer sees the new generation and returns; the sweep's
    // handlers are disconnected.
    ++sConnectGeneration;
    dropConsoleScan();
}

- (void)beginConnectToIp:(NSString *)ip
{
    const QString address = QString::fromNSString(ip);
    if (MainWindow *host = [self engineHost]) {
        // Not a slot or Q_INVOKABLE: called directly (main thread).  It owns
        // the P2 routing, the 8 s watchdog and the desk / radio-layer guards.
        host->beginConnect(address);
        return;
    }
    // No host window yet: the pre-console behaviour of -startWithIp:.
    if (HL2Stream *st = [self engineStream]; st && !address.isEmpty())
        st->open(address);
}

@end

@implementation LyraEngineFacade (Console)

#pragma mark Host window

- (void)attachHostWindow:(void *)mainWindow
{
    auto *host = static_cast<MainWindow *>(mainWindow);
    // Once only, and never after -invalidate (which nulls the stream).
    if (!host || [self engineHost] || ![self engineStream]) return;
    [self setEngineHost:host];
    [self setEngineBandMemory:host->bandMemory()];

    P2RxBridge *p2 = host->p2Bridge();
    if (MeterModel *mm = [self engineMeter])
        mm->setP2Bridge(p2);

    __weak LyraEngineFacade *weakSelf = self;
    auto fire = [weakSelf](LyraEngineChange group) {
        LyraEngineFacade *s = weakSelf;
        LyraEngineChangeCallback cb = [s consoleChangeCallback];
        if (cb) cb(group);
    };

    if (p2) {
        for (auto signal : {&P2RxBridge::runningChanged, &P2RxBridge::openChanged,
                            &P2RxBridge::telemetryChanged}) {
            [self addEngineConnection:QObject::connect(
                p2, signal, p2, [fire]() { fire(LyraEngineChangeStats); })];
        }
    }

    if (lyra::ui::StatusBus *bus = host->statusBus()) {
        [self addEngineConnection:QObject::connect(
            bus, &lyra::ui::StatusBus::message, bus,
            [weakSelf, fire](const QString &text, int) {
                LyraEngineFacade *s = weakSelf;
                if (!s) return;
                [s setLastStatusText:text];
                fire(LyraEngineChangeSession);
            })];
    }

    // Prefs.rxBandwidth -> WdspEngine: in the Qt UI only the QML
    // ModeFilterPanel binds this, and QML never loads in this mode (map §B).
    Prefs *pr = [self enginePrefs];
    WdspEngine *we = [self engineDsp];
    if (pr && we) {
        [self addEngineConnection:QObject::connect(
            pr, &Prefs::rxBandwidthChanged, we,
            [pr, we]() { we->setBandwidth(pr->rxBandwidth()); })];
        we->setBandwidth(pr->rxBandwidth());
    }

    fire(LyraEngineChangeRadio | LyraEngineChangeDsp | LyraEngineChangeAudio
         | LyraEngineChangeMeters | LyraEngineChangeStats | LyraEngineChangeSession);
}

- (void)setConsoleChangeCallback:(LyraEngineChangeCallback)callback
{
    [self setEngineChangeCallback:callback];
}

#pragma mark Reads

- (LyraRadioReading *)consoleRadio
{
    LyraRadioReading *r = [LyraRadioReading new];
    if (HL2Stream *st = [self engineStream]) {
        r.rx1Hz = st->rx1FreqHz();
        r.rx2Hz = st->rx2FreqHz();
        r.vfoBHz = st->vfoBHz();
        r.subEnabled = st->subEnabled();
        r.splitEnabled = st->splitEnabled();
        r.focusedRx = st->focusedRx();
        r.ritEnabled = st->ritEnabled();
        r.ritHz = st->ritOffsetHz();
        r.xitEnabled = st->xitEnabled();
        r.xitHz = st->xitOffsetHz();
        r.ctuneEnabled = st->ctuneEnabled();
        r.ctuneCenterHz = st->ctuneCenterHz();
    } else {
        r.focusedRx = 1;
    }
    if (WdspEngine *we = [self engineDsp]) {
        r.markerOffsetHz = we->markerOffsetHz();
        r.markerOffsetHzRx2 = we->markerOffsetHzRx2();
    }
    if (Prefs *pr = [self enginePrefs])
        r.splitShiftHz = pr->splitShiftHz(pr->mode());
    return r;
}

- (LyraFilterReading *)consoleFilter
{
    LyraFilterReading *f = [LyraFilterReading new];
    f.mode = @"";
    f.modeRx2 = @"";
    if (Prefs *pr = [self enginePrefs]) {
        f.mode = pr->mode().toNSString();
        f.modeRx2 = pr->modeRx2().toNSString();
        f.rxBandwidth = pr->rxBandwidth();
        f.rx2Bandwidth = pr->rx2Bandwidth();
        f.stepHz = pr->vfoStepHz(pr->mode());
        f.stepHzRx2 = pr->vfoStepHzRx2(pr->modeRx2());
        f.filterLowHz = pr->filterLow();
        f.txFilterLowHz = pr->txFilterLow();
        f.txBandwidthHz = pr->txBandwidth();
        f.bwLocked = pr->bwLocked();
    }
    return f;
}

- (LyraDspReading *)consoleDsp
{
    LyraDspReading *d = [LyraDspReading new];
    d.agcMode = @"";
    d.nrMode = 1;
    if (WdspEngine *we = [self engineDsp]) {
        d.agcMode = we->agcMode().toNSString();
        d.agcThreshDb = we->agcThreshDb();
        d.agcMaxGainDb = we->agcMaxGainDb();
        d.nbEnabled = we->nbEnabled();
        d.nbStrength = we->nbStrength();
        d.binEnabled = we->binEnabled();
        d.nrEnabled = we->nrEnabled();
        d.nrMode = we->nrMode();
        d.nnrEnabled = we->nnrEnabled();
        d.nnrAvailable = we->nnrAvailable();
        d.anfEnabled = we->anfEnabled();
        d.lmsEnabled = we->lmsEnabled();
        d.squelchEnabled = we->squelchEnabled();
        d.apfEnabled = we->apfEnabled();
        d.notchEnabled = we->notchEnabled();
        d.notchCount = we->notchCount();
    }
    return d;
}

- (LyraFrontEndReading *)consoleFrontEnd
{
    LyraFrontEndReading *f = [LyraFrontEndReading new];
    HL2Stream *st = [self engineStream];
    if (P2RxBridge *p2 = runningP2(self)) {
        // P2 front end: step attenuator 0..31 dB and its auto step.
        f.lnaDb = p2->rxAttenuationDb();
        f.autoLna = p2->autoStep();
    } else if (st) {
        f.lnaDb = st->lnaGainDb();
        f.autoLna = st->autoLna();
    }
    if (st) {
        f.adcOverload = st->adcOverload();
        f.rxPort = st->hl2RxPort();
    }
    return f;
}

- (LyraAudioReading *)consoleAudio
{
    LyraAudioReading *a = [LyraAudioReading new];
    a.outputDevice = @"";
    if (WdspEngine *we = [self engineDsp]) {
        a.afGainDb = we->afGainDb();
        a.volume = we->volume();
        a.muted = we->muted();
        a.volumeRx2 = we->volumeRx2();
        a.mutedRx2 = we->mutedRx2();
        a.balance = we->balance();
        a.monEnabled = we->monEnabled();
        a.monVolume = we->monVolume();
        const QStringList devices = we->audioOutputDevices();
        const int index = we->audioDeviceIndex();
        if (index >= 0 && index < devices.size())
            a.outputDevice = devices.at(index).toNSString();
    }
    return a;
}

- (LyraMeterReading *)consoleMeters
{
    LyraMeterReading *m = [LyraMeterReading new];
    m.sMeterDbm = -140.0;
    m.sMeterDbmRx2 = -140.0;
    m.snrDb = NAN;
    if (MeterModel *mm = [self engineMeter]) {
        m.sMeterDbm = mm->rxSMeterDbm();
        m.sMeterDbmRx2 = mm->rxSMeterDbmRx2();
        m.snrDb = mm->rxSnrDb();
    }
    if (WdspEngine *we = [self engineDsp]) {
        m.spanHz = we->spanHz();
        m.iqRateHz = we->iqRateHz();
        m.sampleRateHz = we->sampleRate();
    }
    if (Prefs *pr = [self enginePrefs])
        m.sampleRateHz = pr->sampleRate();
    return m;
}

- (LyraTelemetryReading *)consoleTelemetry
{
    LyraTelemetryReading *t = [LyraTelemetryReading new];
    t.tempC = NAN;
    t.supplyV = NAN;
    t.paCurrentA = NAN;
    if (HL2Stream *st = [self engineStream]) {
        t.tempC = st->hl2TempC();
        t.supplyV = st->hl2SupplyV();
        t.paCurrentA = st->paCurrentA();
    }
    if (P2RxBridge *p2 = runningP2(self)) {
        t.supplyV = p2->supplyVolts();
        t.paCurrentA = p2->paCurrentA();
    }
    return t;
}

- (LyraTransmitReading *)consoleTransmit
{
    LyraTransmitReading *t = [LyraTransmitReading new];
    t.fwdPowerW = NAN;
    t.swr = -1.0;
    t.alcDb = NAN;
    t.micLevelDb = NAN;
    if (HL2Stream *st = [self engineStream]) {
        t.moxActive = st->moxActive();
        t.txDisplayActive = st->txDisplayActive();
        t.txInhibit = st->txInhibit();
        t.driveRaw = st->txDriveLevel();
        t.micGainDb = st->micGainDb();
        t.vox = st->voxEnabled();
        t.attOnTx = st->attOnTxEnabled();
        t.swrProtect = st->swrProtectEnabled();
        t.psArmed = st->psArmed();
        t.psFeedback = st->psFeedbackLevel();
        t.fwdPowerW = st->fwdPowerW();
    }
    if (P2RxBridge *p2 = runningP2(self))
        t.fwdPowerW = p2->forwardPowerW();
    if (Prefs *pr = [self enginePrefs])
        t.tuneDrivePct = pr->tuneDrivePct();
    if (MeterModel *mm = [self engineMeter])
        t.swr = mm->liveSwr();
    // Only while keyed, as MeterModel reads them: the TXA channel is not
    // there to read before the engine has run (GetTXAMeter crashes on it).
    HL2Stream *st = [self engineStream];
    WdspEngine *we = [self engineDsp];
    if (we && st && st->moxActive()) {
        t.alcDb = we->txMeterRaw(kTxaAlcAv);
        t.micLevelDb = we->txMeterRaw(kTxaMicPk);
    }
    return t;
}

- (LyraSessionReading *)consoleSession
{
    LyraSessionReading *s = [LyraSessionReading new];
    s.profileName = @"";
    if (ProfileManager *pm = [self engineProfiles]) {
        s.profileName = pm->activeName().toNSString();
        s.profileModified = pm->isModified();
    }
    s.statusMessage = [self lastStatusText].toNSString();
    return s;
}

- (LyraLinkReading *)consoleLink
{
    namespace reg = lyra::rig::registry;
    LyraLinkReading *l = [LyraLinkReading new];
    const lyra::rig::RigProfile rig = reg::rig(reg::activeRigId());
    HL2Stream *st = [self engineStream];
    P2RxBridge *p2 = runningP2(self);

    l.running = st && st->isRunning();
    l.p2Running = p2 != nullptr;
    l.isP2Rig = lyra::rig::capabilitiesFor(rig.family).protocol == 2;
    l.datagramsPerSec = st ? st->datagramsPerSec() : 0.0;
    l.targetIp = p2 ? p2->targetIp().toNSString()
                    : (st ? st->targetIp().toNSString() : @"");
    l.savedIp = self.savedRadioIp;
    l.rigLabel = (p2 && !p2->modelLabel().isEmpty()) ? p2->modelLabel().toNSString()
                                                      : rig.label.toNSString();

    // Firmware comes only from discovery's remembered record, so it is shown
    // only when that record is for the address the console shows.
    if (HL2Discovery *disc = [self engineDiscovery]) {
        const QVariantMap saved = disc->savedRadio();
        const QString ip = saved.value(QStringLiteral("ip")).toString();
        const int code = saved.value(QStringLiteral("codeVersion"), 0).toInt();
        NSString *shown = (l.running || l.p2Running) ? l.targetIp : l.savedIp;
        if (code > 0 && !ip.isEmpty() && ip == QString::fromNSString(shown)) {
            l.firmware = HL2Discovery::formatFirmware(
                saved.value(QStringLiteral("protocol"), 1).toInt(), code,
                saved.value(QStringLiteral("betaVersion"), 0).toInt()).toNSString();
        }
    }

    Prefs *pr = [self enginePrefs];
    l.autoConnectOnLaunch = pr && pr->autoStartOnLaunch()
                            && !qEnvironmentVariableIsSet("LYRA_SAFE");
    return l;
}

#pragma mark Connection

- (void)connectRadio
{
    dropConsoleScan();
    [self connectRadioGeneration:++sConnectGeneration attempt:0];
}

// One connect attempt: wait for the radio layer, leave a live session alone,
// clear a dead attempt, then find the radio by scanning (see connectRadio in
// LyraEngineFacade.h).
- (void)connectRadioGeneration:(quint64)generation attempt:(int)attempt
{
    if (generation != sConnectGeneration) return;  // superseded or cancelled
    MainWindow *host = [self engineHost];
    HL2Stream *st = [self engineStream];
    if (!host || !st) return;

    // create_rnet() runs after FFTW wisdom loads, and MainWindow::beginConnect
    // refuses ("radio layer not ready yet") until it has.  A launch-time
    // connect gets here first, so wait for it.
    if (!lyra::wire::prn) {
        if (attempt >= kRadioLayerRetries) {
            qWarning("[console] connect: radio layer never came up");
            return;
        }
        __weak LyraEngineFacade *weakSelf = self;
        QTimer::singleShot(kRadioLayerRetryMs, host, [weakSelf, generation, attempt]() {
            [weakSelf connectRadioGeneration:generation attempt:attempt + 1];
        });
        return;
    }

    // A live session is left alone: then there is nothing to connect.  A P2
    // session is running only once the radio has confirmed it, and P2RxBridge
    // has no "stopped delivering" signal, so a running P2 session counts as
    // live.  A P1 stream that is running without data is a dead attempt (the
    // socket opens before any radio contact) or a stalled one; beginConnect
    // ignores a running stream, so close it first.
    if (P2RxBridge *p2 = host->p2Bridge(); p2 && p2->isRunning()) return;
    if (st->isRunning()) {
        if (st->datagramsPerSec() > 0) return;
        st->close();
    }

    const auto rig = lyra::rig::registry::rig(lyra::rig::registry::activeRigId());
    const QString saved = QString::fromNSString(self.savedRadioIp);
    HL2Discovery *disc = [self engineDiscovery];
    // P2 rigs open by address through beginConnect's P2 path; the sweep below
    // is P1-only, as MainWindow's scan is.
    if (!disc || lyra::rig::capabilitiesFor(rig.family).protocol == 2) {
        host->beginConnect(saved);
        return;
    }

    // The radio's address can change (DHCP, or the HL2's 169.254 fallback), so
    // find it where it is now, as Settings -> Hardware -> Scan does.  Open the
    // HL2 with the active rig's MAC as soon as it answers; otherwise, when the
    // sweep ends, the first other HL2, else the saved address (so the 8 s
    // watchdog and the console's timeout report it).
    struct Sweep {
        bool opened = false;
        QString ip, mac, board;
        int code = 0, beta = 0, numRxs = 0, protocol = 1;
        bool busy = false;
        bool found = false;
    };
    auto sweep = std::make_shared<Sweep>();
    const QString rigMac = rig.mac;
    auto open = [disc, host](const QString &ip, const QString &mac, const QString &board,
                             int code, int beta, bool busy, int numRxs, int protocol) {
        dropConsoleScan();
        disc->rememberRadio(ip, mac, board, code, beta, busy, numRxs, protocol);
        qWarning("[console] scan found %s (%s) — connecting", qPrintable(ip), qPrintable(mac));
        host->beginConnect(ip);
    };
    sConsoleScanFound = QObject::connect(disc, &HL2Discovery::radioFound, host,
        [sweep, rigMac, generation, open](const QString &ip, const QString &mac,
                                          const QString &board, int code, int beta,
                                          bool busy, int numRxs, int protocol) {
            if (generation != sConnectGeneration || sweep->opened) return;
            if (protocol != 1 || lyra::rig::registry::familyForBoardName(board)
                                     != lyra::rig::RadioFamily::Hl2)
                return;
            if (rigMac.isEmpty() || mac.compare(rigMac, Qt::CaseInsensitive) == 0) {
                sweep->opened = true;
                open(ip, mac, board, code, beta, busy, numRxs, protocol);
                return;
            }
            if (!sweep->found) {
                *sweep = Sweep{false, ip, mac, board, code, beta, numRxs, protocol, busy, true};
            }
        });
    sConsoleScanDone = QObject::connect(disc, &HL2Discovery::scanFinished, host,
        [sweep, generation, open, host, saved](int) {
            if (generation != sConnectGeneration || sweep->opened) return;
            sweep->opened = true;
            if (sweep->found) {
                open(sweep->ip, sweep->mac, sweep->board, sweep->code, sweep->beta,
                     sweep->busy, sweep->numRxs, sweep->protocol);
                return;
            }
            dropConsoleScan();
            qWarning("[console] scan found no HL2 — trying saved %s", qPrintable(saved));
            host->beginConnect(saved);
        });
    disc->scan(1.5, 2, 1);
}

- (void)disconnectRadio
{
    // Cancels a connect still waiting for the radio layer or the sweep.
    [self cancelConsoleConnect];
    MainWindow *host = [self engineHost];
    P2RxBridge *p2 = host ? host->p2Bridge() : nullptr;
    if (p2 && p2->isRunning()) {
        p2->close();
        return;
    }
    if (HL2Stream *st = [self engineStream])
        st->close();
}

#pragma mark Receiver calls

- (BOOL)requireJumpAllowedFromHz:(uint32_t)fromHz toHz:(uint32_t)toHz
{
    HL2Stream *st = [self engineStream];
    return st ? !st->txBlocksJumpFrom(fromHz, toHz) : YES;
}

- (void)stopTxForBlockedJump
{
    if (HL2Stream *st = [self engineStream]) st->stopTxForBlockedJump();
}

- (void)setRx2FreqHz:(uint32_t)hz
{
    if (HL2Stream *st = [self engineStream]) st->setRx2FreqHz(hz);
}

- (void)setSubEnabled:(BOOL)on
{
    if (HL2Stream *st = [self engineStream]) st->setSubEnabled(on);
}

- (void)setFocusedRx:(NSInteger)rx
{
    if (HL2Stream *st = [self engineStream]) st->setFocusedRx(static_cast<int>(rx));
}

- (void)setRptActive:(BOOL)on
{
    if (HL2Stream *st = [self engineStream]) st->setRptActive(on);
}

- (void)setRitEnabled:(BOOL)on
{
    if (HL2Stream *st = [self engineStream]) st->setRitEnabled(on);
}

- (void)setXitEnabled:(BOOL)on
{
    if (HL2Stream *st = [self engineStream]) st->setXitEnabled(on);
}

- (void)setCtuneEnabled:(BOOL)on
{
    if (HL2Stream *st = [self engineStream]) st->setCtuneEnabled(on);
}

- (void)setReceiverMode:(NSString *)mode
{
    if (Prefs *pr = [self enginePrefs]) pr->setMode(QString::fromNSString(mode));
}

- (void)setReceiverModeRx2:(NSString *)mode
{
    if (Prefs *pr = [self enginePrefs]) pr->setModeRx2(QString::fromNSString(mode));
}

- (void)setRxBandwidth:(NSInteger)hz
{
    if (Prefs *pr = [self enginePrefs]) pr->setRxBandwidth(static_cast<int>(hz));
}

- (void)setRx2Bandwidth:(NSInteger)hz
{
    if (Prefs *pr = [self enginePrefs]) pr->setRx2Bandwidth(static_cast<int>(hz));
}

- (void)setBwLocked:(BOOL)on
{
    if (Prefs *pr = [self enginePrefs]) pr->setBwLocked(on);
}

- (void)recallBand:(NSString *)name defaultHz:(uint32_t)defaultHz rx2:(BOOL)rx2
{
    HL2Stream *st = [self engineStream];
    if (!st) return;
    const QString band = QString::fromNSString(name);
    const int def = static_cast<int>(defaultHz);
    BandMemory *bm = [self engineBandMemory];
    if (rx2) {
        const int f = bm ? bm->recallFreq(band, static_cast<int>(st->rx2FreqHz()), def, true) : def;
        st->setRx2FreqHz(static_cast<quint32>(f > 0 ? f : def));
        st->setSubEnabled(true);
        if (bm) bm->applyRx2Band(band);
        return;
    }
    const int f = bm ? bm->recallFreq(band, static_cast<int>(st->rx1FreqHz()), def, false) : def;
    st->setRx1FreqHz(static_cast<quint32>(f > 0 ? f : def));
}

- (void)setDspFunction:(NSString *)name enabled:(BOOL)on
{
    WdspEngine *we = [self engineDsp];
    if (!we) return;
    if ([name isEqualToString:@"NB"]) we->setNbEnabled(on);
    else if ([name isEqualToString:@"BIN"]) we->setBinEnabled(on);
    else if ([name isEqualToString:@"NR"]) we->setNrEnabled(on);
    else if ([name isEqualToString:@"NNR"]) we->setNnrEnabled(on);
    else if ([name isEqualToString:@"ANF"]) we->setAnfEnabled(on);
    else if ([name isEqualToString:@"LMS"]) we->setLmsEnabled(on);
    else if ([name isEqualToString:@"SQ"]) we->setSquelchEnabled(on);
    else if ([name isEqualToString:@"APF"]) we->setApfEnabled(on);
    else if ([name isEqualToString:@"NF"]) we->setNotchEnabled(on);
    // SNB has no engine path; the console keeps it disabled.
}

#pragma mark App

- (void)openSettings
{
    if (MainWindow *host = [self engineHost])
        QMetaObject::invokeMethod(host, "openSettings", Qt::QueuedConnection);
}

- (void)quitApplication
{
    QCoreApplication::quit();
}

@end

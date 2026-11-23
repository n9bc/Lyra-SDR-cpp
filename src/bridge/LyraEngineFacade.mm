// Lyra — Obj-C++ facade over HL2Stream / WdspEngine / MeterModel.  See
// LyraEngineFacade.h.  Compiled with ARC (see CMakeLists.txt).

#import "bridge/LyraEngineFacade.h"
#import "bridge/LyraEngineFacade+Internal.h"

#include "bands.h"
#include "hl2_stream.h"
#include "metermodel.h"
#include "rig/RigRegistry.h"
#include "wdsp_engine.h"

#include <QSettings>

#include <QMetaObject>
#include <QObject>
#include <QString>

#include <vector>

using lyra::dsp::WdspEngine;
using lyra::ipc::HL2Discovery;
using lyra::ipc::HL2Stream;
using lyra::profile::ProfileManager;
using lyra::ui::BandMemory;
using lyra::ui::MainWindow;
using lyra::ui::MeterModel;
using lyra::ui::Prefs;

@interface LyraEngineFacade () {
    HL2Stream *_stream;
    WdspEngine *_dsp;
    MeterModel *_meter;
    Prefs *_prefs;
    HL2Discovery *_discovery;
    ProfileManager *_profiles;
    MainWindow *_host;
    BandMemory *_bandMemory;
    QString _lastStatusText;
    std::vector<QMetaObject::Connection> _connections;
    LyraEngineChangeCallback _consoleChangeCallback;

    LyraRadioCallback _radioCallback;
    LyraDspCallback _dspCallback;
    LyraAudioCallback _audioCallback;
    LyraMeterCallback _meterCallback;
}
// The readonly properties declared in the header are synthesized as _<name>
// ivars.  They are deliberately NOT redeclared readwrite: several share a
// selector with an action method (-setMode:, -setVolume:, ...) that writes
// to the engine, so the read helpers below assign the ivars directly.
@end

@implementation LyraEngineFacade

+ (instancetype)facadeWithStream:(void *)stream dsp:(void *)dsp meter:(void *)meter
{
    return [self facadeWithStream:stream dsp:dsp meter:meter
                            prefs:nullptr discovery:nullptr profiles:nullptr];
}

+ (instancetype)facadeWithStream:(void *)stream
                             dsp:(void *)dsp
                           meter:(void *)meter
                           prefs:(void *)prefs
                       discovery:(void *)discovery
                        profiles:(void *)profiles
{
    return [[self alloc] initWithStream:static_cast<HL2Stream *>(stream)
                                    dsp:static_cast<WdspEngine *>(dsp)
                                  meter:static_cast<MeterModel *>(meter)
                                  prefs:static_cast<Prefs *>(prefs)
                              discovery:static_cast<HL2Discovery *>(discovery)
                               profiles:static_cast<ProfileManager *>(profiles)];
}

- (instancetype)initWithStream:(HL2Stream *)stream
                           dsp:(WdspEngine *)dsp
                         meter:(MeterModel *)meter
                         prefs:(Prefs *)prefs
                     discovery:(HL2Discovery *)discovery
                      profiles:(ProfileManager *)profiles
{
    self = [super init];
    if (!self) return nil;
    _stream = stream;
    _dsp = dsp;
    _meter = meter;
    _prefs = prefs;
    _discovery = discovery;
    _profiles = profiles;
    _host = nullptr;
    _bandMemory = nullptr;
    _mode = @"";
    _agcMode = @"";
    _meterText = @"";
    _meterDbmText = @"";

    [self readStream];
    [self readStats];
    [self readDsp];
    [self readAudio];
    [self readMeter];
    [self connectSignals];
    [self connectConsoleSignals];
    return self;
}

- (void)dealloc
{
    [self invalidate];
}

#pragma mark Reads (C++ -> ivars)

- (void)readStream
{
    if (!_stream) return;
    _isRunning = _stream->isRunning();
    _rx1FreqHz = _stream->rx1FreqHz();
    _moxActive = _stream->moxActive();
    _splitEnabled = _stream->splitEnabled();
    _vfoBHz = _stream->vfoBHz();
    _txDisplayActive = _stream->txDisplayActive();
}

- (void)readStats
{
    if (!_stream) return;
    _hl2TempC = _stream->hl2TempC();
    _hl2SupplyV = _stream->hl2SupplyV();
    _fwdPowerW = _stream->fwdPowerW();
    _revPowerW = _stream->revPowerW();
}

- (void)readDsp
{
    if (!_dsp) return;
    _mode = _dsp->mode().toNSString();
    _bandwidth = _dsp->bandwidth();
    _nrEnabled = _dsp->nrEnabled();
    _nbEnabled = _dsp->nbEnabled();
    _anfEnabled = _dsp->anfEnabled();
    _agcMode = _dsp->agcMode().toNSString();
    _squelchEnabled = _dsp->squelchEnabled();
    _passbandLowHz = _dsp->passbandLowHz();
    _passbandHighHz = _dsp->passbandHighHz();
}

- (void)readAudio
{
    if (!_dsp) return;
    _volume = _dsp->volume();
    _muted = _dsp->muted();
    _afGainDb = _dsp->afGainDb();
    _balance = _dsp->balance();
}

- (void)readMeter
{
    if (!_meter) return;
    _meterLevel = _meter->level();
    _meterPeak = _meter->peak();
    _meterNormAtS9 = _meter->normAtS9();
    _meterText = _meter->text().toNSString();
    _meterDbmText = _meter->dbmText().toNSString();
    _liveSwr = _meter->liveSwr();
    _noiseFloorDbm = _meter->noiseFloorDbm();
    _rxSnrDb = _meter->rxSnrDb();
}

#pragma mark Signal wiring

- (void)connectSignals
{
    // The lambdas hold self weakly: a connection must not keep the facade
    // alive, and -invalidate / -dealloc disconnect them anyway.
    __weak LyraEngineFacade *weakSelf = self;

    // Connect `signal` on `sender` to a block that runs `reads` on the facade
    // and then fires the callback ivar named by `cb`.
#define LYRA_CONNECT(sender, signal, reads, cb)                              \
    do {                                                                     \
        if (sender) {                                                        \
            _connections.push_back(QObject::connect(                         \
                sender, signal, sender, [weakSelf]() {                       \
                    LyraEngineFacade *s = weakSelf;                          \
                    if (!s) return;                                          \
                    reads;                                                   \
                    if (s->cb) s->cb(s);                                     \
                }));                                                         \
        }                                                                    \
    } while (0)

    LYRA_CONNECT(_stream, &HL2Stream::runningChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::rx1FreqChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::moxActiveChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::splitEnabledChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::vfoBHzChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::txDisplayActiveChanged,
                 ([s readStream]), _radioCallback);
    LYRA_CONNECT(_stream, &HL2Stream::statsChanged,
                 ([s readStats]), _radioCallback);

    LYRA_CONNECT(_dsp, &WdspEngine::modeChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::bandwidthChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::passbandChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::nrChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::nbChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::anfChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::agcModeChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::squelchChanged, ([s readDsp]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::volumeChanged, ([s readAudio]), _audioCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::mutedChanged, ([s readAudio]), _audioCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::afGainChanged, ([s readAudio]), _audioCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::balanceChanged, ([s readAudio]), _audioCallback);

    LYRA_CONNECT(_meter, &MeterModel::updated, ([s readMeter]), _meterCallback);

#undef LYRA_CONNECT
}

#pragma mark Radio actions

- (void)setRx1FreqHz:(uint32_t)hz { if (_stream) _stream->setRx1FreqHz(hz); }
- (void)setVfoBHz:(uint32_t)hz { if (_stream) _stream->setVfoBHz(hz); }
- (void)setMox:(BOOL)on { if (_stream) _stream->setMox(on); }
- (void)setSplitEnabled:(BOOL)on { if (_stream) _stream->setSplitEnabled(on); }

- (void)startWithIp:(NSString *)ip
{
    [self beginConnectToIp:ip];
}

- (void)startSavedRadio
{
    NSString *ip = self.savedRadioIp;
    if (ip.length > 0)
        [self startWithIp:ip];
}

- (NSString *)savedRadioIp
{
    QString ip = lyra::rig::registry::rig(
        lyra::rig::registry::activeRigId()).lastIp;
    if (ip.isEmpty())
        ip = QSettings().value(QStringLiteral("radio/lastIp")).toString();
    return ip.toNSString();
}

- (void)stop { if (_stream) _stream->close(); }

#pragma mark DSP actions

- (void)setMode:(NSString *)mode
{
    if (_dsp) _dsp->setMode(QString::fromNSString(mode));
}

- (void)setBandwidth:(int)hz { if (_dsp) _dsp->setBandwidth(hz); }
- (void)setNrEnabled:(BOOL)on { if (_dsp) _dsp->setNrEnabled(on); }
- (void)setNbEnabled:(BOOL)on { if (_dsp) _dsp->setNbEnabled(on); }
- (void)setAnfEnabled:(BOOL)on { if (_dsp) _dsp->setAnfEnabled(on); }

- (void)setAgcMode:(NSString *)mode
{
    if (_dsp) _dsp->setAgcMode(QString::fromNSString(mode));
}

#pragma mark Audio actions

- (void)setVolume:(double)volume { if (_dsp) _dsp->setVolume(volume); }
- (void)setMuted:(BOOL)on { if (_dsp) _dsp->setMuted(on); }
- (void)setAfGainDb:(double)db { if (_dsp) _dsp->setAfGainDb(db); }

#pragma mark Spectrum

- (int)copySpectrumInto:(float *)dst maxBins:(int)maxBins
{
    NSAssert([NSThread isMainThread], @"copySpectrumInto must be called from the main thread");
    if (!_dsp || !dst || maxBins <= 0) return 0;
    return _dsp->copySpectrum(dst, maxBins);
}

#pragma mark Bands

- (NSArray<NSDictionary<NSString *, id> *> *)amateurBands
{
    NSMutableArray *bands = [NSMutableArray array];
    for (const lyra::Band &b : lyra::amateurBands()) {
        [bands addObject:@{
            @"name": [NSString stringWithUTF8String:b.name],
            @"low": @(b.low),
            @"high": @(b.high),
            @"defaultHz": @(b.defaultHz),
            @"mode": [NSString stringWithUTF8String:b.mode],
        }];
    }
    return bands;
}

- (NSInteger)bandIndexForFreq:(NSInteger)hz
{
    return lyra::bandIndexForFreq(static_cast<int>(hz));
}

#pragma mark Callbacks

- (void)setRadioCallback:(LyraRadioCallback)callback { _radioCallback = [callback copy]; }
- (void)setDspCallback:(LyraDspCallback)callback { _dspCallback = [callback copy]; }
- (void)setAudioCallback:(LyraAudioCallback)callback { _audioCallback = [callback copy]; }
- (void)setMeterCallback:(LyraMeterCallback)callback { _meterCallback = [callback copy]; }

#pragma mark Teardown

- (void)invalidate
{
    for (const QMetaObject::Connection &c : _connections)
        QObject::disconnect(c);
    _connections.clear();
    _radioCallback = nil;
    _dspCallback = nil;
    _audioCallback = nil;
    _meterCallback = nil;
    _consoleChangeCallback = nil;
    _stream = nullptr;
    _dsp = nullptr;
    _meter = nullptr;
    _prefs = nullptr;
    _discovery = nullptr;
    _profiles = nullptr;
    _host = nullptr;
    _bandMemory = nullptr;
}

@end

#pragma mark - Internal (see LyraEngineFacade+Internal.h)

@implementation LyraEngineFacade (Internal)

- (HL2Stream *)engineStream { return _stream; }
- (WdspEngine *)engineDsp { return _dsp; }
- (MeterModel *)engineMeter { return _meter; }
- (Prefs *)enginePrefs { return _prefs; }
- (HL2Discovery *)engineDiscovery { return _discovery; }
- (ProfileManager *)engineProfiles { return _profiles; }
- (MainWindow *)engineHost { return _host; }
- (void)setEngineHost:(MainWindow *)host { _host = host; }
- (BandMemory *)engineBandMemory { return _bandMemory; }
- (void)setEngineBandMemory:(BandMemory *)bandMemory { _bandMemory = bandMemory; }
- (QString)lastStatusText { return _lastStatusText; }
- (void)setLastStatusText:(const QString &)text { _lastStatusText = text; }
- (LyraEngineChangeCallback)consoleChangeCallback { return _consoleChangeCallback; }

- (void)setEngineChangeCallback:(LyraEngineChangeCallback)callback
{
    _consoleChangeCallback = [callback copy];
}

- (void)addEngineConnection:(const QMetaObject::Connection &)connection
{
    _connections.push_back(connection);
}

@end

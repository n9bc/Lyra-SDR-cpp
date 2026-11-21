// Lyra — Obj-C++ facade over HL2Stream / WdspEngine / MeterModel.  See
// LyraEngineFacade.h.  Compiled with ARC (see CMakeLists.txt).

#import "bridge/LyraEngineFacade.h"

#include "bands.h"
#include "hl2_stream.h"
#include "metermodel.h"
#include "wdsp_engine.h"

#include <QMetaObject>
#include <QObject>
#include <QString>

#include <vector>

using lyra::dsp::WdspEngine;
using lyra::ipc::HL2Stream;
using lyra::ui::MeterModel;

@interface LyraEngineFacade () {
    HL2Stream *_stream;
    WdspEngine *_dsp;
    MeterModel *_meter;
    std::vector<QMetaObject::Connection> _connections;

    LyraRadioCallback _radioCallback;
    LyraDspCallback _dspCallback;
    LyraMeterCallback _meterCallback;
}

@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic, readwrite) uint32_t rx1FreqHz;
@property (nonatomic, readwrite) BOOL moxActive;
@property (nonatomic, readwrite) BOOL splitEnabled;
@property (nonatomic, readwrite) uint32_t vfoBHz;
@property (nonatomic, readwrite) BOOL txDisplayActive;
@property (nonatomic, readwrite) double hl2TempC;
@property (nonatomic, readwrite) double hl2SupplyV;
@property (nonatomic, readwrite) double fwdPowerW;
@property (nonatomic, readwrite) double revPowerW;

@property (nonatomic, readwrite, copy) NSString *mode;
@property (nonatomic, readwrite) int bandwidth;
@property (nonatomic, readwrite) BOOL nrEnabled;
@property (nonatomic, readwrite) BOOL nbEnabled;
@property (nonatomic, readwrite) BOOL anfEnabled;
@property (nonatomic, readwrite, copy) NSString *agcMode;
@property (nonatomic, readwrite) BOOL squelchEnabled;
@property (nonatomic, readwrite) double passbandLowHz;
@property (nonatomic, readwrite) double passbandHighHz;

@property (nonatomic, readwrite) double volume;
@property (nonatomic, readwrite) BOOL muted;
@property (nonatomic, readwrite) double afGainDb;
@property (nonatomic, readwrite) double balance;

@property (nonatomic, readwrite) double meterLevel;
@property (nonatomic, readwrite) double meterPeak;
@property (nonatomic, readwrite) double meterNormAtS9;
@property (nonatomic, readwrite, copy) NSString *meterDbmText;
@property (nonatomic, readwrite, copy) NSString *meterText;
@property (nonatomic, readwrite) double liveSwr;
@property (nonatomic, readwrite) double noiseFloorDbm;
@property (nonatomic, readwrite) double rxSnrDb;
@end

@implementation LyraEngineFacade

+ (instancetype)facadeWithStream:(void *)stream dsp:(void *)dsp meter:(void *)meter
{
    return [[self alloc] initWithStream:static_cast<HL2Stream *>(stream)
                                    dsp:static_cast<WdspEngine *>(dsp)
                                  meter:static_cast<MeterModel *>(meter)];
}

- (instancetype)initWithStream:(HL2Stream *)stream
                           dsp:(WdspEngine *)dsp
                         meter:(MeterModel *)meter
{
    self = [super init];
    if (!self) return nil;
    _stream = stream;
    _dsp = dsp;
    _meter = meter;
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
    self.isRunning = _stream->isRunning();
    self.rx1FreqHz = _stream->rx1FreqHz();
    self.moxActive = _stream->moxActive();
    self.splitEnabled = _stream->splitEnabled();
    self.vfoBHz = _stream->vfoBHz();
    self.txDisplayActive = _stream->txDisplayActive();
}

- (void)readStats
{
    if (!_stream) return;
    self.hl2TempC = _stream->hl2TempC();
    self.hl2SupplyV = _stream->hl2SupplyV();
    self.fwdPowerW = _stream->fwdPowerW();
    self.revPowerW = _stream->revPowerW();
}

- (void)readDsp
{
    if (!_dsp) return;
    self.mode = _dsp->mode().toNSString();
    self.bandwidth = _dsp->bandwidth();
    self.nrEnabled = _dsp->nrEnabled();
    self.nbEnabled = _dsp->nbEnabled();
    self.anfEnabled = _dsp->anfEnabled();
    self.agcMode = _dsp->agcMode().toNSString();
    self.squelchEnabled = _dsp->squelchEnabled();
    self.passbandLowHz = _dsp->passbandLowHz();
    self.passbandHighHz = _dsp->passbandHighHz();
}

- (void)readAudio
{
    if (!_dsp) return;
    self.volume = _dsp->volume();
    self.muted = _dsp->muted();
    self.afGainDb = _dsp->afGainDb();
    self.balance = _dsp->balance();
}

- (void)readMeter
{
    if (!_meter) return;
    self.meterLevel = _meter->level();
    self.meterPeak = _meter->peak();
    self.meterNormAtS9 = _meter->normAtS9();
    self.meterText = _meter->text().toNSString();
    self.meterDbmText = _meter->dbmText().toNSString();
    self.liveSwr = _meter->liveSwr();
    self.noiseFloorDbm = _meter->noiseFloorDbm();
    self.rxSnrDb = _meter->rxSnrDb();
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
    LYRA_CONNECT(_dsp, &WdspEngine::volumeChanged, ([s readAudio]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::mutedChanged, ([s readAudio]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::afGainChanged, ([s readAudio]), _dspCallback);
    LYRA_CONNECT(_dsp, &WdspEngine::balanceChanged, ([s readAudio]), _dspCallback);

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
    if (_stream) _stream->open(QString::fromNSString(ip));
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
- (void)setMeterCallback:(LyraMeterCallback)callback { _meterCallback = [callback copy]; }

#pragma mark Teardown

- (void)invalidate
{
    for (const QMetaObject::Connection &c : _connections)
        QObject::disconnect(c);
    _connections.clear();
    _radioCallback = nil;
    _dspCallback = nil;
    _meterCallback = nil;
    _stream = nullptr;
    _dsp = nullptr;
    _meter = nullptr;
}

@end

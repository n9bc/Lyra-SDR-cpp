// Lyra — Obj-C facade over the C++ radio engine for the SwiftUI Observatory UI.
//
// Holds raw (non-owning) pointers to HL2Stream, WdspEngine and MeterModel,
// subscribes to their Qt signals, and exposes the live values as read-only
// Obj-C properties plus control methods.  No Qt or C++ type appears in this
// header: it is imported from Swift, so it pulls in Foundation only.
//
// Threading: Qt signals fire on the main thread, so the property updates and
// the callback blocks run on the main thread too.  All methods must be called
// from the main thread.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class LyraEngineFacade;

typedef void (^LyraRadioCallback)(LyraEngineFacade *facade);
typedef void (^LyraDspCallback)(LyraEngineFacade *facade);
typedef void (^LyraAudioCallback)(LyraEngineFacade *facade);
typedef void (^LyraMeterCallback)(LyraEngineFacade *facade);

@interface LyraEngineFacade : NSObject

// Opaque C++ pointers (HL2Stream*, WdspEngine*, MeterModel*) cast to void* at
// the call site.  The facade does not own them; call -invalidate before they
// are destroyed.
+ (instancetype)facadeWithStream:(void *)stream
                             dsp:(void *)dsp
                           meter:(void *)meter;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

#pragma mark Radio state (HL2Stream)

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) uint32_t rx1FreqHz;
@property (nonatomic, readonly) BOOL moxActive;
@property (nonatomic, readonly) BOOL splitEnabled;
@property (nonatomic, readonly) uint32_t vfoBHz;
@property (nonatomic, readonly) BOOL txDisplayActive;
@property (nonatomic, readonly) double hl2TempC;
@property (nonatomic, readonly) double hl2SupplyV;
@property (nonatomic, readonly) double fwdPowerW;
@property (nonatomic, readonly) double revPowerW;

#pragma mark DSP state (WdspEngine)

@property (nonatomic, readonly, copy) NSString *mode;
@property (nonatomic, readonly) int bandwidth;
@property (nonatomic, readonly) BOOL nrEnabled;
@property (nonatomic, readonly) BOOL nbEnabled;
@property (nonatomic, readonly) BOOL anfEnabled;
@property (nonatomic, readonly, copy) NSString *agcMode;
@property (nonatomic, readonly) BOOL squelchEnabled;
@property (nonatomic, readonly) double passbandLowHz;
@property (nonatomic, readonly) double passbandHighHz;

#pragma mark Audio state (WdspEngine)

@property (nonatomic, readonly) double volume;
@property (nonatomic, readonly) BOOL muted;
@property (nonatomic, readonly) double afGainDb;
@property (nonatomic, readonly) double balance;

#pragma mark Meter state (MeterModel)

// level / peak / normAtS9 are normalised 0..1 along the S-meter scale, not dBm.
@property (nonatomic, readonly) double meterLevel;
@property (nonatomic, readonly) double meterPeak;
@property (nonatomic, readonly) double meterNormAtS9;
@property (nonatomic, readonly, copy) NSString *meterText;
@property (nonatomic, readonly, copy) NSString *meterDbmText;
@property (nonatomic, readonly) double liveSwr;
@property (nonatomic, readonly) double noiseFloorDbm;
@property (nonatomic, readonly) double rxSnrDb;

#pragma mark Radio actions

- (void)setRx1FreqHz:(uint32_t)hz;
- (void)setVfoBHz:(uint32_t)hz;
- (void)setMox:(BOOL)on;
- (void)setSplitEnabled:(BOOL)on;
- (void)startWithIp:(NSString *)ip;
- (void)startSavedRadio;
- (void)stop;

/// Last-connected radio IP from the rig registry / QSettings.
@property (nonatomic, readonly, copy) NSString *savedRadioIp;

#pragma mark DSP actions

- (void)setMode:(NSString *)mode;
- (void)setBandwidth:(int)hz;
- (void)setNrEnabled:(BOOL)on;
- (void)setNbEnabled:(BOOL)on;
- (void)setAnfEnabled:(BOOL)on;
- (void)setAgcMode:(NSString *)mode;

#pragma mark Audio actions

- (void)setVolume:(double)volume;
- (void)setMuted:(BOOL)on;
- (void)setAfGainDb:(double)db;

#pragma mark Spectrum

// Copies up to maxBins display-width dB values into dst; returns the count
// written (0 when no spectrum is available).
- (int)copySpectrumInto:(float *)dst maxBins:(int)maxBins;

#pragma mark Bands

// One NSDictionary per amateur band, low to high:
// @"name" (NSString), @"low" / @"high" / @"defaultHz" (NSNumber int),
// @"mode" (NSString).
- (NSArray<NSDictionary<NSString *, id> *> *)amateurBands;
// Index into -amateurBands of the band containing hz, or -1.
- (NSInteger)bandIndexForFreq:(NSInteger)hz;

#pragma mark Callbacks (invoked on the main thread; pass nil to clear)

- (void)setRadioCallback:(nullable LyraRadioCallback)callback;
- (void)setDspCallback:(nullable LyraDspCallback)callback;
- (void)setAudioCallback:(nullable LyraAudioCallback)callback;
- (void)setMeterCallback:(nullable LyraMeterCallback)callback;

#pragma mark Teardown

// Disconnects every Qt signal subscription and drops the callbacks and the
// C++ pointers.  Safe to call more than once; every method is a no-op after.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

// Lyra — Obj-C facade over the C++ radio engine for the SwiftUI Observatory UI.
//
// Holds raw (non-owning) pointers to HL2Stream, WdspEngine and MeterModel
// (plus Prefs, HL2Discovery, ProfileManager and, once attached, the hidden
// MainWindow), subscribes to their Qt signals, and exposes the live values as
// read-only Obj-C properties plus control methods.  The Console category below
// serves the native console (Observatory/Backend/EngineFacade.swift).  No Qt or
// C++ type appears in this header: it is imported from Swift, so it pulls in
// Foundation only.
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

/// Which groups of engine state changed.  The bit values match the Swift
/// `EngineChange` option set.
typedef NS_OPTIONS(NSInteger, LyraEngineChange) {
    LyraEngineChangeRadio   = 1 << 0,
    LyraEngineChangeDsp     = 1 << 1,
    LyraEngineChangeAudio   = 1 << 2,
    LyraEngineChangeMeters  = 1 << 3,
    LyraEngineChangeStats   = 1 << 4,
    LyraEngineChangeSession = 1 << 5,
    // Spots, the band plan or the band-plan preferences changed.
    LyraEngineChangeOverlays = 1 << 6,
};

typedef void (^LyraEngineChangeCallback)(LyraEngineChange change);

#pragma mark Console readings
// Plain value bags filled by the Console category's reads, one per
// `EngineState` field group.  Units and sentinels are as in EngineState.swift.

@interface LyraRadioReading : NSObject
@property (nonatomic) uint32_t rx1Hz;
@property (nonatomic) NSInteger markerOffsetHz;
@property (nonatomic) uint32_t rx2Hz;
@property (nonatomic) NSInteger markerOffsetHzRx2;
@property (nonatomic) uint32_t vfoBHz;
@property (nonatomic) BOOL subEnabled;
@property (nonatomic) BOOL splitEnabled;
@property (nonatomic) NSInteger focusedRx;
@property (nonatomic) BOOL ritEnabled;
@property (nonatomic) NSInteger ritHz;
@property (nonatomic) BOOL xitEnabled;
@property (nonatomic) NSInteger xitHz;
@property (nonatomic) BOOL ctuneEnabled;
@property (nonatomic) uint32_t ctuneCenterHz;
@property (nonatomic) NSInteger splitShiftHz;
@end

@interface LyraFilterReading : NSObject
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSString *modeRx2;
@property (nonatomic) NSInteger rxBandwidth;
@property (nonatomic) NSInteger rx2Bandwidth;
@property (nonatomic) NSInteger stepHz;
@property (nonatomic) NSInteger stepHzRx2;
@property (nonatomic) NSInteger filterLowHz;
@property (nonatomic) NSInteger txFilterLowHz;
@property (nonatomic) NSInteger txBandwidthHz;
@property (nonatomic) BOOL bwLocked;
@end

@interface LyraDspReading : NSObject
@property (nonatomic, copy) NSString *agcMode;
@property (nonatomic) double agcThreshDb;
@property (nonatomic) double agcMaxGainDb;
@property (nonatomic) BOOL nbEnabled;
@property (nonatomic) double nbStrength;
@property (nonatomic) BOOL binEnabled;
@property (nonatomic) BOOL nrEnabled;
@property (nonatomic) NSInteger nrMode;
@property (nonatomic) BOOL nnrEnabled;
@property (nonatomic) BOOL nnrAvailable;
@property (nonatomic) BOOL anfEnabled;
@property (nonatomic) BOOL lmsEnabled;
@property (nonatomic) BOOL squelchEnabled;
@property (nonatomic) BOOL apfEnabled;
@property (nonatomic) BOOL notchEnabled;
@property (nonatomic) NSInteger notchCount;
@end

@interface LyraFrontEndReading : NSObject
@property (nonatomic) NSInteger lnaDb;
@property (nonatomic) BOOL autoLna;
@property (nonatomic) BOOL adcOverload;
@property (nonatomic) NSInteger rxPort;
@end

@interface LyraAudioReading : NSObject
@property (nonatomic) double afGainDb;
@property (nonatomic) double volume;
@property (nonatomic) BOOL muted;
@property (nonatomic) double volumeRx2;
@property (nonatomic) BOOL mutedRx2;
@property (nonatomic) double balance;
@property (nonatomic) BOOL monEnabled;
@property (nonatomic) double monVolume;
@property (nonatomic, copy) NSString *outputDevice;
// WdspEngine::audioOutputDevices(), read once per facade (the engine enumerates
// them in its constructor and never refreshes). Index 0 is the HL2 jack.
@property (nonatomic, copy) NSArray<NSString *> *outputDevices;
@property (nonatomic) NSInteger outputDeviceIndex;
@end

@interface LyraMeterReading : NSObject
@property (nonatomic) double sMeterDbm;
@property (nonatomic) double sMeterDbmRx2;
@property (nonatomic) double snrDb;
@property (nonatomic) NSInteger spanHz;
@property (nonatomic) NSInteger iqRateHz;
@property (nonatomic) NSInteger sampleRateHz;
@end

// Display geometry from WdspEngine and the spectrum display preferences
// (Prefs, SpotStore).  Units and sentinels as EngineState.Display.
@interface LyraDisplayReading : NSObject
@property (nonatomic) NSInteger spanHz;
@property (nonatomic) NSInteger iqRateHz;
@property (nonatomic) double zoom;
@property (nonatomic) BOOL txOwnsAnalyzer;
@property (nonatomic) double passbandLowHz;
@property (nonatomic) double passbandHighHz;
@property (nonatomic) double passbandLowHzRx2;
@property (nonatomic) double passbandHighHzRx2;
// The radio has more than one ADC (HL2Stream::dualAdc), so the RX2
// analyzer can run.
@property (nonatomic) BOOL rx2SpectrumAvailable;
@property (nonatomic) double dbMin;
@property (nonatomic) double dbMax;
@property (nonatomic) BOOL dbAuto;
@property (nonatomic) double waterfallDbMin;
@property (nonatomic) double waterfallDbMax;
@property (nonatomic) BOOL waterfallDbAuto;
@property (nonatomic) NSInteger waterfallSpeed;
@property (nonatomic) NSInteger waterfallPalette;
// 768 bytes (256 RGB triples) for a preset palette; empty for the custom ramp.
@property (nonatomic, copy) NSData *waterfallLut;
// 0xRRGGBB of Prefs.waterfallColor, the custom ramp's base.
@property (nonatomic) uint32_t waterfallBaseRGB;
@property (nonatomic) BOOL peakEnabled;
@property (nonatomic) double peakHoldSecs;
@property (nonatomic) double peakDecayDbps;
@property (nonatomic) NSInteger smoothing;
@property (nonatomic) NSInteger scrollStepHz;
@property (nonatomic) BOOL round100;
@property (nonatomic) BOOL stickyWheel;
@property (nonatomic) BOOL bandPlanSegments;
@property (nonatomic) BOOL bandPlanLandmarks;
@property (nonatomic) BOOL bandPlanBeacons;
@property (nonatomic) BOOL showSpots;
@end

// One band-plan segment (BandPlan::segments), clipped to the window.
@interface LyraSegmentReading : NSObject
@property (nonatomic) double lowHz;
@property (nonatomic) double highHz;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL channel;
// A channel's unclipped low edge; NaN for other segments.
@property (nonatomic) double qsyHz;
@end

// One BandPlan::landmarks entry (watering hole or NCDXF beacon).
@interface LyraLandmarkReading : NSObject
@property (nonatomic) double hz;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic) BOOL beacon;
@end

// One SpotStore::spotsInSpan entry; hz is the carrier frequency.
@interface LyraSpotReading : NSObject
@property (nonatomic, copy) NSString *call;
@property (nonatomic) double hz;
@property (nonatomic) BOOL mine;
@property (nonatomic, copy) NSString *mode;
@end

@interface LyraOverlayReading : NSObject
@property (nonatomic, copy) NSArray<LyraSegmentReading *> *segments;
@property (nonatomic, copy) NSArray<LyraLandmarkReading *> *landmarks;
@property (nonatomic, copy) NSArray<LyraSpotReading *> *spots;
@end

@interface LyraTelemetryReading : NSObject
@property (nonatomic) double tempC;
@property (nonatomic) double supplyV;
@property (nonatomic) double paCurrentA;
@end

@interface LyraTransmitReading : NSObject
@property (nonatomic) BOOL moxActive;
@property (nonatomic) BOOL txDisplayActive;
@property (nonatomic) BOOL txInhibit;
@property (nonatomic) NSInteger driveRaw;
@property (nonatomic) NSInteger tuneDrivePct;
@property (nonatomic) double micGainDb;
@property (nonatomic) BOOL vox;
@property (nonatomic) BOOL attOnTx;
@property (nonatomic) BOOL swrProtect;
@property (nonatomic) BOOL psArmed;
@property (nonatomic) NSInteger psFeedback;
@property (nonatomic) double fwdPowerW;
@property (nonatomic) double swr;
@property (nonatomic) double alcDb;
@property (nonatomic) double micLevelDb;
@end

@interface LyraSessionReading : NSObject
@property (nonatomic, copy) NSString *profileName;
@property (nonatomic) BOOL profileModified;
@property (nonatomic, copy) NSString *statusMessage;
@end

@interface LyraLinkReading : NSObject
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL p2Running;
@property (nonatomic) BOOL isP2Rig;
@property (nonatomic) double datagramsPerSec;
@property (nonatomic, copy) NSString *targetIp;
@property (nonatomic, copy) NSString *savedIp;
@property (nonatomic, copy) NSString *rigLabel;
@property (nonatomic, copy, nullable) NSString *firmware;
@property (nonatomic) BOOL autoConnectOnLaunch;
@end

@interface LyraEngineFacade : NSObject

// Opaque C++ pointers (HL2Stream*, WdspEngine*, MeterModel*) cast to void* at
// the call site.  The facade does not own them; call -invalidate before they
// are destroyed.
+ (instancetype)facadeWithStream:(void *)stream
                             dsp:(void *)dsp
                           meter:(void *)meter;

// As above, plus Prefs*, HL2Discovery* and ProfileManager* for the console
// (null for the console reads and calls they serve to do nothing).
+ (instancetype)facadeWithStream:(void *)stream
                             dsp:(void *)dsp
                           meter:(void *)meter
                           prefs:(nullable void *)prefs
                       discovery:(nullable void *)discovery
                        profiles:(nullable void *)profiles;

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
// Connects through MainWindow::beginConnect (P2 routing, watchdog, guards),
// like -connectRadio, but to the given address.
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

// Cancels a pending console connect (its retry timer and discovery sweep),
// disconnects every Qt signal subscription (console ones included) and drops
// the callbacks and the C++ pointers.  Safe to call more than once; every
// method is a no-op after (reads return their defaults).  The Observatory
// calls it on QCoreApplication::aboutToQuit.
- (void)invalidate;

@end

#pragma mark - Console (LyraEngineFacadeConsole.mm)

// Serves the native console.  Main thread only.  Reads come live from the C++
// objects on every call; nothing is cached except the last status-bus text.
@interface LyraEngineFacade (Console)

// Late binding to the hidden MainWindow* (it is built after the facade):
// gives the facade's MeterModel the P2 bridge, follows the status bus, keeps
// the band memory, binds Prefs.rxBandwidth and Prefs.zoom to the engine
// (bindings that only the QML panels made, which do not load in this mode),
// and follows the host's spot store and band plan.
- (void)attachHostWindow:(void *)mainWindow;

// The one change handler (nil clears it).
- (void)setConsoleChangeCallback:(nullable LyraEngineChangeCallback)callback;

- (LyraRadioReading *)consoleRadio;
- (LyraFilterReading *)consoleFilter;
- (LyraDspReading *)consoleDsp;
- (LyraFrontEndReading *)consoleFrontEnd;
- (LyraAudioReading *)consoleAudio;
- (LyraMeterReading *)consoleMeters;
- (LyraTelemetryReading *)consoleTelemetry;
- (LyraTransmitReading *)consoleTransmit;
- (LyraSessionReading *)consoleSession;
- (LyraLinkReading *)consoleLink;
- (LyraDisplayReading *)consoleDisplay;
// Every segment, landmark (digital and beacons) and spot in the window
// centreHz +/- spanHz / 2; the console applies its display flags itself.
// Empty until the host window is attached.  Allocates: call on a change, not
// per frame.
- (LyraOverlayReading *)consoleOverlaysCentreHz:(double)centreHz spanHz:(double)spanHz
    NS_SWIFT_NAME(consoleOverlays(centreHz:spanHz:));

#pragma mark Spectrum (console)

// As -copySpectrumInto:maxBins:, for the RX2 analyzer (WdspEngine::
// copySpectrumRx2): 0 on a single-ADC radio, where it never opens.
- (int)copySpectrumRx2Into:(float *)dst maxBins:(int)maxBins;
// The main waterfall row (WdspEngine::copyWaterfallSpectrum).
- (int)copyWaterfallInto:(float *)dst maxBins:(int)maxBins;

#pragma mark Audio calls

// WdspEngine setters; each clamps and persists itself. Main thread.
- (void)setVolumeRx2:(double)volume;
- (void)setMutedRx2:(BOOL)on;
- (void)setBalance:(double)balance;
- (void)setMonEnabled:(BOOL)on;
- (void)setMonVolume:(double)volume;
// Index 0 = HL2 jack, n = PC device n-1. Briefly blocks the main thread
// while the sink restarts.
- (void)setAudioOutputDevice:(NSInteger)index;

#pragma mark Display calls

// HL2Stream::setCtuneCenterHz: moves the locked CTUN display centre.
- (void)setCtuneCenterHz:(uint32_t)hz;
// Prefs writes; the engine follows Prefs.zoom (bound in -attachHostWindow:).
- (void)writeZoomPref:(double)zoom;
- (void)writeScrollStepPref:(NSInteger)hz;
- (void)writeRound100Pref:(BOOL)on;
// Off writes only peakEnabled, keeping the hold time for the next time on.
- (void)writePeakPrefEnabled:(BOOL)enabled holdSecs:(double)secs;
- (void)writeSmoothingPref:(NSInteger)value;
- (void)writeBandPlanSegmentsPref:(BOOL)on;
// SpotStore::setShowSpots (persisted under spots/).
- (void)writeShowSpotsPref:(BOOL)on;
// Prefs::setVfoStepHz / setVfoStepHzRx2 for the receiver's current mode,
// the keys -consoleFilter reads.
- (void)writeStepPref:(NSInteger)hz rx2:(BOOL)rx2;
// SpotStore::activate: tunes to the spot (the store guards transmit).
- (void)activateSpotCall:(NSString *)call;

// Connects the active rig through MainWindow::beginConnect.  Waits for the
// radio layer (up to 20 s).  Does nothing while a session is live: a running
// P2 session, or a P1 stream with data (datagramsPerSec > 0).  Closes a P1
// stream that is running without data (a dead or stalled attempt), then finds
// a P1 radio with a P1-only discovery sweep: the HL2 with the rig's MAC, else
// the first HL2 found, else the active rig's last IP / radio/lastIp.  P2 rigs
// skip the sweep and open the saved address.
- (void)connectRadio;
// Closes a live P2 session, else the P1 stream.
- (void)disconnectRadio;

// NO when HL2Stream::txBlocksJumpFrom reports the jump blocked.
- (BOOL)requireJumpAllowedFromHz:(uint32_t)fromHz toHz:(uint32_t)toHz;
- (void)stopTxForBlockedJump;
- (void)setRx2FreqHz:(uint32_t)hz;
- (void)setSubEnabled:(BOOL)on;
- (void)setFocusedRx:(NSInteger)rx;
- (void)setRptActive:(BOOL)on;
- (void)setRitEnabled:(BOOL)on;
- (void)setXitEnabled:(BOOL)on;
- (void)setCtuneEnabled:(BOOL)on;
// Through Prefs (which fans out to the engine, TX and band memory), unlike
// -setMode: which writes WdspEngine only.
- (void)setReceiverMode:(NSString *)mode;
- (void)setReceiverModeRx2:(NSString *)mode;
- (void)setRxBandwidth:(NSInteger)hz;
- (void)setRx2Bandwidth:(NSInteger)hz;
- (void)setBwLocked:(BOOL)on;
// BandMemory::recallFreq for <name>; rx2 tunes and enables the sub receiver.
- (void)recallBand:(NSString *)name defaultHz:(uint32_t)defaultHz rx2:(BOOL)rx2;
// name is a console DSP function id: NB BIN NR NNR ANF LMS SQ APF NF.
- (void)setDspFunction:(NSString *)name enabled:(BOOL)on;

// Opens the Qt Settings dialog on the hidden MainWindow.
- (void)openSettings;
- (void)quitApplication;

@end

NS_ASSUME_NONNULL_END

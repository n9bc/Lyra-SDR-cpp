# Observatory Obj-C++ Bridge Facade

## Intent

Connect Observatory's SwiftUI `@Observable` bridges to Lyra's live C++
backend so the UI shows real radio state and controls the real radio.
The existing mock bridges (`RadioBridge`, `DspBridge`, `MeterBridge`,
`AudioBridge`) become thin Swift wrappers that call through an Obj-C++
facade layer to the real `HL2Stream`, `WdspEngine`, `MeterModel`, and
`Bands` objects.

### Why

Observatory P0 shipped a standalone SwiftUI app with hardcoded numbers.
It doesn't talk to the radio. This bridge is what makes it a working UI.

## Goals

1. **Real data flow.** Every `@Observable` property in the four bridge
   classes reflects live C++ backend state, updated via Qt signal → Obj-C++
   callback → `@MainActor` Swift mutation.

2. **Real controls.** Every action method on the bridges (setFrequency,
   toggleMox, setMode, setVolume, etc.) calls through to the C++ backend.

3. **Same binary.** Observatory compiles into the existing Lyra CMake build.
   No separate process, no IPC.

4. **Spectrum data.** The panadapter receives real FFT frames from
   `WdspEngine::copySpectrum()` via a Metal-ready callback path.

5. **Window swap.** The app opens Observatory's SwiftUI shell instead of
   `MainWindow` (QMainWindow), controlled by a launch flag or build config
   so both paths remain available during development.

## Non-goals

- Bridging every one of the ~270 Q_PROPERTYs across all classes. We bridge
  what the P0 panels actually read/write (~40 properties, ~15 actions).
- Rewriting any C++ backend code.
- Metal panadapter rendering (SpectrumPanel stays a placeholder; the bridge
  delivers the data, rendering is a separate task).
- TX panels (P1 scope).

## Anti-goals

- A generic "bridge everything" framework. The facade is hand-written,
  property-by-property, so each binding is explicit and debuggable.
- Embedding Qt widgets inside SwiftUI. The bridge is data-only.

## Constraints

- **Qt on macOS uses Cocoa.** `QApplication` IS an `NSApplication`. SwiftUI
  and Qt coexist in the same process. The Qt event loop runs; SwiftUI views
  are hosted via `NSHostingView` in an `NSWindow`.
- **Thread safety.** Qt signals fire on the main thread (all Q_PROPERTYs in
  `HL2Stream` and `WdspEngine` are main-thread). The facade forwards them
  to Swift `@MainActor` via `DispatchQueue.main.async` from Obj-C++ blocks.
  Spectrum data (`copySpectrum`) is the exception — it's called from a
  display-link timer on whatever thread CADisplayLink fires on.
- **C++ headers never reach Swift.** The Obj-C++ facade exposes only
  C-compatible or Objective-C interfaces. Swift imports via a bridging
  header or `@objc` classes.
- **macOS 14+ / Swift 6.0 / C++23 / Qt 6.11.**
- **CMake AUTOMOC** must continue to work for the existing C++ sources.

## Architecture

```
SwiftUI @Observable Bridges (Swift)
        │  calls/callbacks
        ▼
LyraEngineFacade (Obj-C++ .mm)
        │  holds raw C++ pointers
        │  QObject::connect for signals
        ▼
C++ Backend (HL2Stream, WdspEngine, MeterModel, Bands)
```

### LyraEngineFacade

A single Obj-C++ class that:
1. Receives `HL2Stream*`, `WdspEngine*`, `MeterModel*` from `main.cpp`
   (same pattern as `MainWindow` constructor).
2. Subscribes to Qt signals via `QObject::connect` with lambda captures.
3. Stores callback blocks (Obj-C blocks typed to match Swift closures)
   that the Swift bridges register.
4. When a Qt signal fires, invokes the registered callback on the main
   thread, passing the new value.
5. Exposes setter methods that call back into C++ (e.g.,
   `setRx1FreqHz:` → `stream->requestFrequency(hz)`).

### Facade header (C-compatible)

```objc
// LyraEngineFacade.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opaque handle to the C++ backend.  Created in main.cpp after the
/// C++ objects exist; passed to the SwiftUI app entry point.
@interface LyraEngineFacade : NSObject

// --- Radio (HL2Stream) ---
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

- (void)setRx1FreqHz:(uint32_t)hz;
- (void)setVfoBHz:(uint32_t)hz;
- (void)requestMox:(BOOL)on;
- (void)setSplitEnabled:(BOOL)on;
- (void)start;
- (void)stop;

// --- DSP (WdspEngine) ---
@property (nonatomic, readonly) NSString *mode;
@property (nonatomic, readonly) int bandwidth;
@property (nonatomic, readonly) BOOL nrEnabled;
@property (nonatomic, readonly) BOOL nbEnabled;
@property (nonatomic, readonly) BOOL anfEnabled;
@property (nonatomic, readonly) NSString *agcMode;
@property (nonatomic, readonly) BOOL squelchEnabled;
@property (nonatomic, readonly) double squelchThreshold;
@property (nonatomic, readonly) double passbandLowHz;
@property (nonatomic, readonly) double passbandHighHz;

- (void)setMode:(NSString *)mode;
- (void)setBandwidth:(int)hz;
- (void)setNrEnabled:(BOOL)on;
- (void)setNbEnabled:(BOOL)on;
- (void)setAnfEnabled:(BOOL)on;
- (void)setAgcMode:(NSString *)mode;

// --- Audio (WdspEngine audio section) ---
@property (nonatomic, readonly) double volume;
@property (nonatomic, readonly) BOOL muted;
@property (nonatomic, readonly) double afGainDb;
@property (nonatomic, readonly) double balance;

- (void)setVolume:(double)vol;
- (void)setMuted:(BOOL)on;
- (void)setAfGainDb:(double)db;

// --- Meters (MeterModel) ---
@property (nonatomic, readonly) double meterLevel;      // 0..1 normalized
@property (nonatomic, readonly) double meterPeak;        // 0..1 normalized
@property (nonatomic, readonly) double meterNormAtS9;    // 0..1 S9 position
@property (nonatomic, copy, readonly) NSString *meterText;    // "S9+20" etc
@property (nonatomic, copy, readonly) NSString *meterDbmText; // "-53 dBm" etc
@property (nonatomic, readonly) double liveSwr;
@property (nonatomic, readonly) double noiseFloorDbm;
@property (nonatomic, readonly) double rxSnrDb;

// --- Bands ---
- (NSArray<NSDictionary *> *)amateurBands;
- (NSInteger)bandIndexForFreq:(double)hz;

// --- Spectrum ---
/// Copies the latest spectrum frame into `dst` (up to `maxN` floats).
/// Returns the number of bins actually written.
- (int)copySpectrumInto:(float *)dst maxBins:(int)maxN;

// --- Change callbacks (registered by Swift bridges) ---
typedef void (^LyraRadioCallback)(LyraEngineFacade *facade);
typedef void (^LyraMeterCallback)(LyraEngineFacade *facade);
typedef void (^LyraDspCallback)(LyraEngineFacade *facade);

- (void)setRadioCallback:(nullable LyraRadioCallback)cb;
- (void)setMeterCallback:(nullable LyraMeterCallback)cb;
- (void)setDspCallback:(nullable LyraDspCallback)cb;

@end

NS_ASSUME_NONNULL_END
```

### Swift bridge pattern

Each `@Observable` bridge holds a reference to the facade and reads
properties from it when the callback fires:

```swift
@Observable @MainActor
final class RadioBridge {
    private let facade: LyraEngineFacade

    var isRunning: Bool = false
    var rx1FreqHz: UInt32 = 0
    var moxActive: Bool = false
    // ...

    init(facade: LyraEngineFacade) {
        self.facade = facade
        facade.setRadioCallback { [weak self] f in
            DispatchQueue.main.async {
                self?.isRunning = f.isRunning
                self?.rx1FreqHz = f.rx1FreqHz
                self?.moxActive = f.moxActive
                // ...
            }
        }
    }

    func setFrequency(_ hz: UInt32) { facade.setRx1FreqHz(hz) }
    func toggleMox() { facade.requestMox(!moxActive) }
}
```

### Window swap

In `main.cpp`, after creating the C++ objects, instead of:
```cpp
auto *win = new lyra::ui::MainWindow(discovery, stream, wdsp, ...);
```

A compile-time or runtime flag gates:
```cpp
#if LYRA_OBSERVATORY
    auto *facade = lyra_create_engine_facade(stream, wdspEngine, meterModel, bands);
    lyra_show_observatory_window(facade);
#else
    auto *win = new lyra::ui::MainWindow(discovery, stream, wdsp, ...);
#endif
```

Where `lyra_show_observatory_window` creates an `NSWindow` hosting
Observatory's SwiftUI `ContentView` via `NSHostingView`.

### CMake integration

The Observatory Swift/Obj-C++ sources compile as part of the main
`lyra` CMake target:
- Obj-C++ files (`.mm`) added to `target_sources` with AUTOMOC disabled
  for them
- Swift files compiled via `add_custom_command` calling `swiftc` with
  the bridging header, or via a CMake Swift support module
- The bridging header imports `LyraEngineFacade.h`
- Link flags: `-framework SwiftUI -framework Observation`

### Properties bridged (P0 scope)

| Bridge | Property | C++ source | Signal |
|--------|----------|------------|--------|
| Radio | isRunning | HL2Stream::isRunning() | runningChanged |
| Radio | rx1FreqHz | HL2Stream::rx1FreqHz() | rx1FreqChanged |
| Radio | moxActive | HL2Stream::moxActive() | moxActiveChanged |
| Radio | splitEnabled | HL2Stream::splitEnabled() | splitEnabledChanged |
| Radio | vfoBHz | HL2Stream::vfoBHz() | vfoBHzChanged |
| Radio | txDisplayActive | HL2Stream::txDisplayActive() | txDisplayActiveChanged |
| Radio | hl2TempC | HL2Stream::hl2TempC() | telemetryChanged |
| Radio | hl2SupplyV | HL2Stream::hl2SupplyV() | telemetryChanged |
| Radio | fwdPowerW | HL2Stream::fwdPowerW() | telemetryChanged |
| Radio | revPowerW | HL2Stream::revPowerW() | telemetryChanged |
| DSP | mode | WdspEngine::mode() | modeChanged |
| DSP | bandwidth | WdspEngine::bandwidth() | bandwidthChanged |
| DSP | nrEnabled | WdspEngine::nrEnabled() | nrEnabledChanged |
| DSP | nbEnabled | WdspEngine::nbEnabled() | nbEnabledChanged |
| DSP | anfEnabled | WdspEngine::anfEnabled() | anfEnabledChanged |
| DSP | agcMode | WdspEngine::agcMode() | agcModeChanged |
| DSP | squelchEnabled | WdspEngine::squelchEnabled() | squelchEnabledChanged |
| DSP | passbandLowHz | WdspEngine::passbandLowHz() | passbandChanged |
| DSP | passbandHighHz | WdspEngine::passbandHighHz() | passbandChanged |
| Audio | volume | WdspEngine::volume() | volumeChanged |
| Audio | muted | WdspEngine::muted() | mutedChanged |
| Audio | afGainDb | WdspEngine::afGainDb() | afGainDbChanged |
| Audio | balance | WdspEngine::balance() | balanceChanged |
| Meter | meterLevel | MeterModel::level() | updated |
| Meter | meterPeak | MeterModel::peak() | updated |
| Meter | meterNormAtS9 | MeterModel::normAtS9() | updated |
| Meter | meterText | MeterModel::text() | updated |
| Meter | meterDbmText | MeterModel::dbmText() | updated |
| Meter | liveSwr | MeterModel::liveSwr() | updated |
| Meter | noiseFloorDbm | MeterModel::noiseFloorDbm() | updated |
| Meter | rxSnrDb | MeterModel::rxSnrDb() | updated |

### Actions bridged (P0 scope)

| Bridge | Action | C++ target |
|--------|--------|-----------|
| Radio | setFrequency | HL2Stream::requestFrequency(hz) |
| Radio | setVfoBFrequency | HL2Stream::setVfoBHz(hz) |
| Radio | toggleMox | HL2Stream::requestMox(on) |
| Radio | setSplit | HL2Stream::setSplitEnabled(on) |
| Radio | start/stop | HL2Stream::open() / close() |
| DSP | setMode | WdspEngine::setMode(m) |
| DSP | setBandwidth | WdspEngine::setBandwidth(hz) |
| DSP | toggleNR | WdspEngine::setNrEnabled(on) |
| DSP | toggleNB | WdspEngine::setNbEnabled(on) |
| DSP | toggleANF | WdspEngine::setAnfEnabled(on) |
| DSP | setAgcMode | WdspEngine::setAgcMode(m) |
| Audio | setVolume | WdspEngine::setVolume(v) |
| Audio | toggleMute | WdspEngine::setMuted(on) |
| Audio | setAfGain | WdspEngine::setAfGainDb(db) |
| Bands | amateurBands | Bands::amateur() |
| Bands | indexForFreq | Bands::indexForFreq(hz) |
| Spectrum | copySpectrum | WdspEngine::copySpectrum(dst, n) |

## Approaches considered

### 1. Obj-C++ in-process facade (chosen)

Single Obj-C++ class holding C++ pointers, QObject::connect for signals,
Obj-C blocks for Swift callbacks. Same binary, same event loop.

**Why chosen:** Simplest, lowest latency, no serialization, no IPC.
Qt on macOS already IS Cocoa, so coexistence is natural.

### 2. IPC bridge (separate processes)

Observatory as a standalone SwiftUI process, C++ engine headless,
communication via Unix domain sockets or XPC.

**Why rejected:** Spectrum data at 60 fps × 4096 bins × 4 bytes = 1 MB/s
through IPC adds latency and complexity for no benefit. Two processes
to manage, two crash surfaces.

### 3. TCI protocol bridge

Use the existing TCI server (already in Lyra) as the bridge protocol.

**Why rejected:** TCI is a remote-control protocol, not a UI bridge.
It doesn't expose meter data, spectrum at sufficient rate, or most DSP
controls. Would need extending beyond recognition.

## What's left to the builder

- Exact `QObject::connect` signal names (verify against headers — the
  property table above lists expected signal names, builder confirms).
- Whether `copySpectrum` is called from a `CADisplayLink` or a `Timer`.
- Exact CMake incantations for mixed Swift/Obj-C++/C++ compilation
  (may require a separate CMake target that links to the main one).
- How the `NSWindow` hosting SwiftUI is created and managed alongside
  the Qt event loop.
- Error handling for the case where C++ objects are destroyed before
  the Swift bridges release (weak facade reference or explicit teardown).

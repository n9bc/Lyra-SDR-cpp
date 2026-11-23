import Foundation

/// One entry of the engine's amateur band table (`lyra::amateurBands()`).
struct EngineBand: Equatable, Sendable {
    var name: String
    var lowHz: UInt32
    var highHz: UInt32
    var defaultHz: UInt32
}

/// Plain values mirroring the radio engine, read in one pass on the main thread. Field meanings,
/// units and sentinels are in `.superpowers/sdd/m3-engine-api-map.md` A1-A10. Unreported
/// readings are NaN (or -1 for `swr`, or the -140 dBm S-meter floor); the mapper turns them into
/// nil. The engine keeps its last readings after the link goes down, so the mapper also drops
/// every reading unless the connection is streaming. Fields may be NaN wherever the engine can
/// return NaN; the mapper never converts a NaN to an integer.
struct EngineState: Equatable, Sendable {
    struct Radio: Equatable, Sendable {
        var rx1Hz: UInt32 = 0
        var markerOffsetHz = 0
        var rx2Hz: UInt32 = 0
        var markerOffsetHzRx2 = 0
        var vfoBHz: UInt32 = 0
        var subEnabled = false
        var splitEnabled = false
        var focusedRx = 1
        var ritEnabled = false
        var ritHz = 0
        var xitEnabled = false
        var xitHz = 0
        var ctuneEnabled = false
        var ctuneCenterHz: UInt32 = 0
        var splitShiftHz = 0
    }

    struct Filter: Equatable, Sendable {
        var mode = "USB"
        var modeRx2 = "USB"
        var rxBandwidth = 2700
        var rx2Bandwidth = 2700
        var stepHz = 1000
        var stepHzRx2 = 1000
        var filterLowHz = 100
        var txFilterLowHz = 100
        var txBandwidthHz = 2700
        var bwLocked = false
    }

    struct DSP: Equatable, Sendable {
        /// Lowercase: "off", "fast", "med", "slow". Shared by both receivers.
        var agcMode = "off"
        var agcThreshDb = 0.0
        /// NaN whenever WDSP is not running (`WdspEngine::agcMaxGainDb`).
        var agcMaxGainDb = Double.nan
        var nbEnabled = false
        /// 0...1
        var nbStrength = 0.0
        var binEnabled = false
        var nrEnabled = false
        /// 1...4
        var nrMode = 1
        var nnrEnabled = false
        var nnrAvailable = false
        var anfEnabled = false
        var lmsEnabled = false
        var squelchEnabled = false
        var apfEnabled = false
        var notchEnabled = false
        var notchCount = 0
    }

    struct FrontEnd: Equatable, Sendable {
        var lnaDb = 0
        var autoLna = false
        var adcOverload = false
        /// 0 = RF1, 2 = Alt.
        var rxPort = 0
    }

    struct Audio: Equatable, Sendable {
        var afGainDb = 0.0
        var volume = 0.0
        var muted = false
        var volumeRx2 = 0.0
        var mutedRx2 = false
        var balance = 0.0
        var monEnabled = false
        var monVolume = 0.0
        var outputDevice = ""
    }

    struct Meters: Equatable, Sendable {
        var sMeterDbm = -140.0
        var sMeterDbmRx2 = -140.0
        var snrDb = Double.nan
        var spanHz = 0
        var iqRateHz = 0
        var sampleRateHz = 0
    }

    struct Telemetry: Equatable, Sendable {
        var tempC = Double.nan
        var supplyV = Double.nan
        var paCurrentA = Double.nan
    }

    struct Transmit: Equatable, Sendable {
        var moxActive = false
        var txDisplayActive = false
        var txInhibit = false
        /// 0...255
        var driveRaw = 0
        var tuneDrivePct = 0
        var micGainDb = 0.0
        var vox = false
        var attOnTx = false
        var swrProtect = false
        var psArmed = false
        var psFeedback = 0
        var fwdPowerW = Double.nan
        /// -1 when there is no reading.
        var swr = -1.0
        var alcDb = Double.nan
        var micLevelDb = Double.nan
    }

    struct Session: Equatable, Sendable {
        var profileName = ""
        var profileModified = false
        var statusMessage = ""
    }

    struct Link: Equatable, Sendable {
        var running = false
        var p2Running = false
        /// The active rig speaks protocol 2; known while disconnected.
        var isP2Rig = false
        var datagramsPerSec = 0.0
        var targetIp = ""
        var savedIp = ""
        var rigLabel = ""
        var firmware: String?
        var autoConnectOnLaunch = false
    }

    var radio = Radio()
    var filter = Filter()
    var dsp = DSP()
    var frontEnd = FrontEnd()
    var audio = Audio()
    var meters = Meters()
    var bands: [EngineBand] = []
    var telemetry = Telemetry()
    var transmit = Transmit()
    var session = Session()
    var link = Link()

    /// A quiet, disconnected engine, for tests.
    static let idle = EngineState()
}

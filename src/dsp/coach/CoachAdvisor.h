#pragma once
// eSSB Coach advisor: turns the analyzer's curves, compression metrics and the
// splatter meter's result into an ordered list of typed findings.  Text is
// rendered elsewhere.  Qt-free; runs on the GUI thread.
//
// CURVE   the re-check curve when the re-check is Running/Stopped and
//         non-empty, else the baseline.  Speech seconds and compression
//         metrics follow the same choice.  With no curve only receive-path and
//         confidence findings can appear.
// ORDER   receive path (RxFilterTooNarrow low then high, NrOn, AnfOn) -> confidence
//         (NeedMoreSpeech, SignalTooWeak) -> Bandwidth -> tone (zone order)
//         -> compression (Pumping, NoiseBetweenWords, Squashed) -> Splatter.
//         NotVoiceMode is the only finding when present.  A confidence
//         finding suppresses bandwidth, tone and compression; Splatter is
//         always included when its result alerts.
// ZONES   mean (curve - target) over the zone's bands, using only bands that
//         lie wholly inside [rxLow * 2^(1/12), rxHigh * 2^(-1/12)] (half a
//         1/6-octave band of margin; an RX edge <= 0 or NaN is "not set" and
//         ignored on that side).  A zone with no usable bands is skipped and
//         its flag cleared.  Flags at |mean| > tolerance, clears below
//         tolerance - kHysteresisDb or when the deviation's sign flips.
// EDGES   walking outward from 1 kHz, the last band centre still >= -20 dB.
//         *BeyondRx: the edge is within one band (1/6 octave) of a set RX edge.
//         Bandwidth compares an edge to the target only when that edge is not
//         limited by the RX filter (*BeyondRx); the tier check likewise needs
//         both edges free.
// Finding::db is the signed rounded deviation (tone) or rounded margin
// (Splatter).  NaN confidence inputs are reported as NaN in value.

#include <string>
#include <utility>
#include <vector>

#include "dsp/coach/CoachAnalyzer.h"
#include "dsp/coach/CoachEnvelope.h"
#include "dsp/coach/CoachTarget.h"
#include "dsp/coach/SplatterMeter.h"

namespace lyra::dsp::coach {

struct RxConditions {
    double rxLowHz = 0.0, rxHighHz = 0.0;   // absolute audio Hz
    bool nrOn = false, anfOn = false;
    std::string agcMode;
    std::string mode;
};

struct Edges {
    double lowHz = NAN, highHz = NAN;
    bool lowBeyondRx = false, highBeyondRx = false;
    std::string tier;   // id of the built-in target with the nearest edges
};

enum class FindingKind {
    RxFilterTooNarrow, NrOn, AnfOn, NotVoiceMode, NeedMoreSpeech, SignalTooWeak,
    Bandwidth, ToneHeavy, ToneThin, NoiseBetweenWords, Pumping, Squashed, Splatter
};

// kind          value            value2
// RxFilterTooNarrow low (zone Bass): rxLowHz, target low edge
//                   high (zone Top): the RX filter width as Lyra's RX BW
//                   control shows it (rxHighHz; 2 * rxHighHz in AM/SAM/DSB),
//                   and suggestRxWidthHz() - see rxHighNeededHz()
//                   (each only when that RX edge is set)
// NeedMoreSpeech    speech sec   required sec
// SignalTooWeak     median SNR   required SNR
// Bandwidth         lowHz        highHz
// Tone*             zone mean    zone tolerance (hz = worst band centre)
// NoiseBetween...   gap-to-speech threshold in value2
// Pumping           gap rise     threshold
// Squashed          crest        threshold
// Splatter          peakDb       outDb (db = margin)
struct Finding {
    FindingKind kind{};
    ZoneId zone{};
    double hz = 0, db = 0, value = 0, value2 = 0;
};

struct CoachThresholds {
    double minSpeechSec = 8, minSnrDb = 15;
    double gapToSpeechDb = kGapToSpeechFlagDb;
    double gapRiseDb = kGapRiseFlagDb;
    double crestDb = kCrestFlagDb;
};

class CoachAdvisor {
public:
    static constexpr double kBandOctaves = 1.0 / 6.0;   // band width; edge margin is half
    static constexpr double kHysteresisDb = 1.0;
    static constexpr double kEdgeWithinDb = 20.0;

    // Band [loHz, hiHz] lies wholly inside the RX passband less half a band
    // on each side (an RX edge <= 0 or NaN is "not set").
    static bool bandUsable(double loHz, double hiHz, const RxConditions &rx);
    // USB, LSB, DSB, AM, SAM (any case).  Every other mode gets NotVoiceMode
    // only, and the engine feeds the coach no-information blocks in it.
    static bool isVoiceMode(const std::string &mode);
    // The RX high edge must lie above this for a target to be judged:
    // highEdgeHz * 2^(1/6), one 1/6-octave band of guard.  Below it the band
    // holding the target's high edge is not wholly usable (bandUsable) and a
    // measured edge there reads as limited by our RX filter (*BeyondRx).
    static double rxHighNeededHz(const Target &target);
    // Smallest RX BW preset Lyra offers in `mode` (the lists in
    // qml/FilterPresets.js) whose high edge is above neededHighHz; the width is
    // the BW control's number (2 * high edge in AM/SAM/DSB).  Past the largest
    // preset: the needed width rounded up to the next 100 Hz.
    static double suggestRxWidthHz(const std::string &mode, double neededHighHz);

    Edges edges(const CoachSnapshot &s, const RxConditions &rx) const;
    std::vector<Finding> evaluate(const CoachSnapshot &s, const SplatterResult &sp,
                                  const RxConditions &rx, const Target &target);
    // recheck - baseline, mean per zone (zones with bands only); empty unless
    // both curves exist.
    std::vector<std::pair<ZoneId, double>> zoneDelta(const CoachSnapshot &s) const;
    void reset();   // clears hysteresis state
    void setThresholds(const CoachThresholds &t) { th_ = t; }
    void setZones(std::vector<Zone> z);   // overrides the per-target defaults

private:
    CoachThresholds th_;
    std::vector<Zone> zones_ = defaultZones(6000.0);
    bool customZones_ = false;
    bool flagged_[5] = {false, false, false, false, false};
    int sign_[5] = {0, 0, 0, 0, 0};
    std::string lastTarget_;
};

}  // namespace lyra::dsp::coach

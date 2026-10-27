#include "dsp/coach/CoachAdvisor.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <iterator>

namespace lyra::dsp::coach {

namespace {

bool useRecheck(const CoachSnapshot &s)
{
    return (s.recheck == AvgState::Running || s.recheck == AvgState::Stopped)
           && !s.recheckDb.empty();
}

const std::vector<double> &currentCurve(const CoachSnapshot &s)
{
    return useRecheck(s) ? s.recheckDb : s.baselineDb;
}

bool rxEdgeSet(double hz) { return std::isfinite(hz) && hz > 0.0; }

// Within one band (1/6 octave) of a set RX edge.
bool nearRxEdge(double hz, const RxConditions &rx)
{
    auto isNear = [&](double edge) {
        return rxEdgeSet(edge) && std::fabs(std::log2(hz / edge)) <= CoachAdvisor::kBandOctaves;
    };
    return isNear(rx.rxLowHz) || isNear(rx.rxHighHz);
}

std::string upper(const std::string &m)
{
    std::string u;
    for (const unsigned char c : m) u += static_cast<char>(std::toupper(c));
    return u;
}

// Symmetric (two-sided) modes: the RX BW control's number is twice the audio
// high edge.
bool symmetricMode(const std::string &m)
{
    const std::string u = upper(m);
    return u == "DSB" || u == "AM" || u == "SAM";
}

int zoneIndex(ZoneId z) { return static_cast<int>(z); }

struct ZoneStat {
    bool any = false;
    double mean = 0.0, worstHz = 0.0;
};

// Mean of fn(k) over the bands of [lo, hi) accepted by `keep`; the worst band
// is the one with the largest |fn(k)|.
template <class Fn, class Keep>
ZoneStat zoneStat(const BandLayout &b, size_t n, const Zone &z, Fn fn, Keep keep)
{
    ZoneStat st;
    double sum = 0.0, worst = -1.0;
    int count = 0;
    for (size_t k = 0; k < n && k < b.centreHz.size(); ++k) {
        const double hz = b.centreHz[k];
        if (hz < z.loHz || hz >= z.hiHz || !keep(k)) continue;
        const double d = fn(k, hz);
        if (!std::isfinite(d)) continue;
        sum += d;
        ++count;
        if (std::fabs(d) > worst) {
            worst = std::fabs(d);
            st.worstHz = hz;
        }
    }
    if (count > 0) {
        st.any = true;
        st.mean = sum / count;
    }
    return st;
}

}  // namespace

bool CoachAdvisor::isVoiceMode(const std::string &m)
{
    const std::string u = upper(m);
    return u == "USB" || u == "LSB" || u == "DSB" || u == "AM" || u == "SAM";
}

double CoachAdvisor::rxHighNeededHz(const Target &target)
{
    return target.highEdgeHz * std::exp2(kBandOctaves);
}

double CoachAdvisor::suggestRxWidthHz(const std::string &mode, double neededHighHz)
{
    // Keep in step with bwSSB / bwDSB / bwAM in qml/FilterPresets.js.
    static const double kSsb[] = {1500, 1800, 2100, 2400, 2700, 3000, 3600, 4000, 6000, 8000, 10000};
    static const double kDsb[] = {3000, 4000, 5000, 6000, 8000, 10000};
    static const double kAm[] = {3000, 4000, 6000, 8000, 10000, 12000, 16000, 20000};
    const std::string u = upper(mode);
    const double *p = kSsb, *end = kSsb + std::size(kSsb);
    if (u == "DSB") { p = kDsb; end = kDsb + std::size(kDsb); }
    else if (u == "AM" || u == "SAM") { p = kAm; end = kAm + std::size(kAm); }
    const double needW = symmetricMode(mode) ? 2.0 * neededHighHz : neededHighHz;
    for (; p != end; ++p)
        if (*p > needW) return *p;
    return std::floor(needW / 100.0) * 100.0 + 100.0;
}

bool CoachAdvisor::bandUsable(double lo, double hi, const RxConditions &rx)
{
    const double half = std::exp2(0.5 * kBandOctaves);
    if (rxEdgeSet(rx.rxLowHz) && lo < rx.rxLowHz * half) return false;
    if (rxEdgeSet(rx.rxHighHz) && hi > rx.rxHighHz / half) return false;
    return true;
}

Edges CoachAdvisor::edges(const CoachSnapshot &s, const RxConditions &rx) const
{
    Edges e;
    const std::vector<double> &c = currentCurve(s);
    const size_t n = std::min(c.size(), s.bands.centreHz.size());
    if (n == 0) return e;

    size_t ref = 0;
    double best = 1e300;
    for (size_t k = 0; k < n; ++k) {
        const double d = std::fabs(std::log2(s.bands.centreHz[k] / 1000.0));
        if (d < best) { best = d; ref = k; }
    }
    auto within = [&](size_t k) { return std::isfinite(c[k]) && c[k] >= -kEdgeWithinDb; };
    if (!within(ref)) return e;

    size_t lo = ref, hi = ref;
    while (lo > 0 && within(lo - 1)) --lo;
    while (hi + 1 < n && within(hi + 1)) ++hi;
    e.lowHz = s.bands.centreHz[lo];
    e.highHz = s.bands.centreHz[hi];
    e.lowBeyondRx = nearRxEdge(e.lowHz, rx);
    e.highBeyondRx = nearRxEdge(e.highHz, rx);

    double bestDist = 1e300;
    for (const Target &t : builtinTargets()) {
        const double d = std::fabs(std::log2(e.lowHz / t.lowEdgeHz))
                       + std::fabs(std::log2(e.highHz / t.highEdgeHz));
        if (d < bestDist) { bestDist = d; e.tier = t.id; }
    }
    return e;
}

std::vector<Finding> CoachAdvisor::evaluate(const CoachSnapshot &s, const SplatterResult &sp,
                                            const RxConditions &rx, const Target &target)
{
    std::vector<Finding> out;

    if (!isVoiceMode(rx.mode)) {
        Finding f;
        f.kind = FindingKind::NotVoiceMode;
        out.push_back(f);
        return out;
    }

    if (target.id != lastTarget_) {
        std::fill(std::begin(flagged_), std::end(flagged_), false);
        lastTarget_ = target.id;
    }
    if (!customZones_) zones_ = defaultZones(target.highEdgeHz);

    // Receive path.
    if (rxEdgeSet(rx.rxLowHz) && rx.rxLowHz > target.lowEdgeHz) {
        Finding f;
        f.kind = FindingKind::RxFilterTooNarrow;
        f.zone = ZoneId::Bass;
        f.value = rx.rxLowHz;
        f.value2 = target.lowEdgeHz;
        out.push_back(f);
    }
    const double needHigh = rxHighNeededHz(target);
    if (rxEdgeSet(rx.rxHighHz) && !(rx.rxHighHz > needHigh)) {
        Finding f;
        f.kind = FindingKind::RxFilterTooNarrow;
        f.zone = ZoneId::Top;
        f.value = symmetricMode(rx.mode) ? 2.0 * rx.rxHighHz : rx.rxHighHz;
        f.value2 = suggestRxWidthHz(rx.mode, needHigh);
        out.push_back(f);
    }
    if (rx.nrOn) { Finding f; f.kind = FindingKind::NrOn; out.push_back(f); }
    if (rx.anfOn) { Finding f; f.kind = FindingKind::AnfOn; out.push_back(f); }

    // Confidence.
    const bool rc = useRecheck(s);
    const double speech = rc ? s.recheckSpeechSec : s.speechSec;
    bool lowConfidence = false;
    if (!(speech >= th_.minSpeechSec)) {   // also true for NaN
        Finding f;
        f.kind = FindingKind::NeedMoreSpeech;
        f.value = std::isnan(speech) ? 0.0 : speech;
        f.value2 = th_.minSpeechSec;
        out.push_back(f);
        lowConfidence = true;
    } else if (!(s.medianSnrDb >= th_.minSnrDb)) {
        Finding f;
        f.kind = FindingKind::SignalTooWeak;
        f.value = s.medianSnrDb;
        f.value2 = th_.minSnrDb;
        out.push_back(f);
        lowConfidence = true;
    }

    if (!lowConfidence) {
        const std::vector<double> &curve = currentCurve(s);
        const size_t n = std::min(curve.size(), s.bands.centreHz.size());

        if (n > 0) {
            // Bandwidth.
            const Edges e = edges(s, rx);
            if (std::isfinite(e.lowHz) && std::isfinite(e.highHz)) {
                const double oneBand = 1.0 / 6.0;   // octaves
                const bool lowOff = !e.lowBeyondRx
                    && std::fabs(std::log2(e.lowHz / target.lowEdgeHz)) > oneBand;
                const bool highOff = !e.highBeyondRx
                    && std::fabs(std::log2(e.highHz / target.highEdgeHz)) > oneBand;
                const bool tierOff = !e.lowBeyondRx && !e.highBeyondRx && e.tier != target.id;
                if (lowOff || highOff || tierOff) {
                    Finding f;
                    f.kind = FindingKind::Bandwidth;
                    f.value = e.lowHz;
                    f.value2 = e.highHz;
                    out.push_back(f);
                }
            }

            // Tone.
            for (const Zone &z : zones_) {
                const ZoneStat st = zoneStat(
                    s.bands, n, z,
                    [&](size_t k, double hz) { return curve[k] - targetDbAt(target, hz); },
                    [&](size_t k) {
                        return k < s.bands.loHz.size() && k < s.bands.hiHz.size()
                               && CoachAdvisor::bandUsable(s.bands.loHz[k], s.bands.hiHz[k], rx);
                    });
                bool &fl = flagged_[zoneIndex(z.id)];
                int &sg = sign_[zoneIndex(z.id)];
                if (!st.any) { fl = false; continue; }
                const double tol = toleranceAt(target, 0.5 * (z.loHz + z.hiHz));
                const int sgn = st.mean > 0 ? 1 : -1;
                if (fl && sgn != sg) fl = false;   // sign flip: re-qualify
                const double a = std::fabs(st.mean);
                if (a > tol) fl = true;
                else if (a < tol - kHysteresisDb) fl = false;
                if (!fl) continue;
                sg = sgn;
                Finding f;
                f.kind = st.mean > 0 ? FindingKind::ToneHeavy : FindingKind::ToneThin;
                f.zone = z.id;
                f.hz = st.worstHz;
                f.db = std::round(st.mean);
                f.value = st.mean;
                f.value2 = tol;
                out.push_back(f);
            }
        }

        // Compression; NaN means "not measured" and never flags.
        const CompressionMetrics &m = rc ? s.recheckComp : s.comp;
        if (m.pauses > 0 && std::isfinite(m.gapRiseDb) && m.gapRiseDb > th_.gapRiseDb) {
            Finding f;
            f.kind = FindingKind::Pumping;
            f.value = m.gapRiseDb;
            f.value2 = th_.gapRiseDb;
            out.push_back(f);
        }
        if (std::isfinite(m.gapToSpeechDb) && m.gapToSpeechDb < th_.gapToSpeechDb) {
            Finding f;
            f.kind = FindingKind::NoiseBetweenWords;
            f.value = m.gapToSpeechDb;
            f.value2 = th_.gapToSpeechDb;
            out.push_back(f);
        }
        if (std::isfinite(m.crestDb) && m.crestDb < th_.crestDb) {
            Finding f;
            f.kind = FindingKind::Squashed;
            f.value = m.crestDb;
            f.value2 = th_.crestDb;
            out.push_back(f);
        }
    }

    if (sp.alert) {
        Finding f;
        f.kind = FindingKind::Splatter;
        f.db = std::round(sp.marginDb);
        f.value = sp.peakDb;
        f.value2 = sp.outDb;
        out.push_back(f);
    }
    return out;
}

std::vector<std::pair<ZoneId, double>> CoachAdvisor::zoneDelta(const CoachSnapshot &s) const
{
    std::vector<std::pair<ZoneId, double>> out;
    const size_t n = std::min({s.baselineDb.size(), s.recheckDb.size(), s.bands.centreHz.size()});
    if (n == 0) return out;
    for (const Zone &z : zones_) {
        const ZoneStat st = zoneStat(
            s.bands, n, z, [&](size_t k, double) { return s.recheckDb[k] - s.baselineDb[k]; },
            [](size_t) { return true; });
        if (st.any) out.emplace_back(z.id, st.mean);
    }
    return out;
}

void CoachAdvisor::reset()
{
    std::fill(std::begin(flagged_), std::end(flagged_), false);
}

void CoachAdvisor::setZones(std::vector<Zone> z)
{
    zones_ = std::move(z);
    customZones_ = true;
    reset();
}

}  // namespace lyra::dsp::coach

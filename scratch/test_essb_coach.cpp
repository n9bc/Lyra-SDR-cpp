// Offline test for the eSSB Coach DSP (src/dsp/coach/): 1/6-octave band
// layout, target curves, tolerance, zones, mid normalisation, the target JSON
// round-trip, the analyzer's band curves and averages, and the speech gate /
// noise floor / AGC correction / compression metrics.
//   build: cmake --build build --target test_essb_coach
//   run:   build/test_essb_coach
#include "dsp/coach/CoachAdvisor.h"
#include "dsp/coach/CoachAnalyzer.h"
#include "dsp/coach/CoachEnvelope.h"
#include "dsp/coach/CoachTarget.h"
#include "dsp/coach/RxaAgcModel.h"
#include "dsp/coach/SplatterMeter.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

using namespace lyra::dsp::coach;

namespace {

int g_failures = 0;

void check(const char *name, bool ok, double got)
{
    std::printf("  %-58s got=%9.3f  %s\n", name, got, ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

const Target *find(const std::vector<Target> &v, const char *id)
{
    for (const auto &t : v) if (t.id == id) return &t;
    return nullptr;
}

bool same(const Target &a, const Target &b)
{
    if (a.id != b.id || a.name != b.name || a.lowEdgeHz != b.lowEdgeHz
        || a.highEdgeHz != b.highEdgeHz || a.tolLowDb != b.tolLowDb
        || a.tolDb != b.tolDb || a.tolSplitHz != b.tolSplitHz
        || a.builtin != b.builtin || a.points.size() != b.points.size())
        return false;
    for (size_t i = 0; i < a.points.size(); ++i)
        if (a.points[i].hz != b.points[i].hz || a.points[i].db != b.points[i].db)
            return false;
    return true;
}

// ---- analyzer test helpers -------------------------------------------------

constexpr double kFs = 48000.0;
constexpr double kPi = 3.14159265358979323846;

// Seeded Voss-McCartney pink noise, scaled to `rms`.
std::vector<double> pinkNoise(size_t n, double rms, unsigned seed)
{
    std::mt19937 rng(seed);
    std::uniform_real_distribution<double> u(-1.0, 1.0);
    constexpr int kRows = 16;
    double rows[kRows];
    double sum = 0.0;
    for (double &r : rows) { r = u(rng); sum += r; }
    std::vector<double> x(n);
    for (size_t i = 0; i < n; ++i) {
        // Row k is refreshed every 2^k samples (trailing zeros of the counter).
        const unsigned c = static_cast<unsigned>(i + 1);
        int k = 0;
        while (k < kRows - 1 && !((c >> k) & 1u)) ++k;
        sum -= rows[k];
        rows[k] = u(rng);
        sum += rows[k];
        x[i] = sum + u(rng);
    }
    double e = 0.0;
    for (double v : x) e += v * v;
    const double g = rms / std::sqrt(e / static_cast<double>(n));
    for (double &v : x) v *= g;
    return x;
}

// Speech-like bursts: 1.5 s at the stated level, 0.5 s at -60 dBFS, repeating.
void burstify(std::vector<double> &x)
{
    const size_t period = static_cast<size_t>(2.0 * kFs);
    const size_t on = static_cast<size_t>(1.5 * kFs);
    for (size_t i = 0; i < x.size(); ++i)
        if (i % period >= on) x[i] *= 1e-2;   // rms 0.1 -> 1e-3 = -60 dBFS
}

// RBJ peaking EQ, direct form I.
void peaking(std::vector<double> &x, double f0, double gainDb, double q)
{
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * f0 / kFs;
    const double al = std::sin(w0) / (2.0 * q);
    const double c = std::cos(w0);
    const double b0 = 1.0 + al * A, b1 = -2.0 * c, b2 = 1.0 - al * A;
    const double a0 = 1.0 + al / A, a1 = -2.0 * c, a2 = 1.0 - al / A;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (double &v : x) {
        const double y = (b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
        x2 = x1; x1 = v; y2 = y1; y1 = y;
        v = y;
    }
}

void feedAll(CoachAnalyzer &a, const std::vector<double> &x, int block)
{
    for (size_t i = 0; i < x.size(); i += static_cast<size_t>(block)) {
        const int n = static_cast<int>(std::min<size_t>(block, x.size() - i));
        a.feed(x.data() + i, n, 0.0);
    }
}

// Seeded white noise at `rms`.
std::vector<double> whiteNoise(size_t n, double rms, unsigned seed)
{
    std::mt19937 rng(seed);
    std::normal_distribution<double> g(0.0, rms);
    std::vector<double> x(n);
    for (double &v : x) v = g(rng);
    return x;
}

double dbToAmp(double db) { return std::pow(10.0, db / 20.0); }

// Unit-rms pink noise shaped by a per-sample level in dBFS: `onSec` bursts at
// burstDb alternating with `offSec` pauses whose level is pauseDb(t), t = time
// into the pause.  Starts with a burst.  Returns the total burst seconds.
template <class PauseDb>
double burstSignal(std::vector<double> &x, double totalSec, double onSec, double offSec,
                   double burstDb, PauseDb pauseDb, unsigned seed)
{
    x = pinkNoise(static_cast<size_t>(totalSec * kFs), 1.0, seed);
    const double period = onSec + offSec;
    size_t burstSamples = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        const double t = std::fmod(static_cast<double>(i) / kFs, period);
        if (t < onSec) { x[i] *= dbToAmp(burstDb); ++burstSamples; }
        else x[i] *= dbToAmp(pauseDb(t - onSec));
    }
    return static_cast<double>(burstSamples) / kFs;
}

// Feed in 480-sample blocks; gainDb[k] (if given) is reported with block k.
void feedBlocks(CoachAnalyzer &a, const std::vector<double> &x,
                const std::vector<double> *gainDb = nullptr)
{
    constexpr size_t kB = 480;
    for (size_t i = 0, k = 0; i < x.size(); i += kB, ++k) {
        const int n = static_cast<int>(std::min(kB, x.size() - i));
        a.feed(x.data() + i, n, gainDb ? (*gainDb)[k] : 0.0);
    }
}

CoachSnapshot runBaseline(const std::vector<double> &x,
                          const std::vector<double> *gainDb = nullptr)
{
    CoachAnalyzer a(kFs);
    a.prepare();
    a.startBaseline();
    feedBlocks(a, x, gainDb);
    CoachSnapshot s;
    a.snapshot(s);
    return s;
}

// Feed in `chunk`-sample calls; a simulated AGC holds one gain per call
// (from gainAt(time of the call's first sample)), applies it to the samples
// and reports it.
template <class GainAt>
CoachSnapshot runBaselineAgcChunks(std::vector<double> x, size_t chunk, GainAt gainAt)
{
    CoachAnalyzer a(kFs);
    a.prepare();
    a.startBaseline();
    for (size_t i = 0; i < x.size(); i += chunk) {
        const size_t n = std::min(chunk, x.size() - i);
        const double g = gainAt(static_cast<double>(i) / kFs);
        for (size_t j = i; j < i + n; ++j) x[j] *= dbToAmp(g);
        a.feed(x.data() + i, static_cast<int>(n), g);
    }
    CoachSnapshot s;
    a.snapshot(s);
    return s;
}

bool allNan(const CompressionMetrics &m)
{
    return std::isnan(m.gapToSpeechDb) && std::isnan(m.gapRiseDb) && std::isnan(m.crestDb)
           && m.pauses == 0;
}

double flatness(const CoachSnapshot &s)
{
    if (s.baselineDb.empty()) return 1e9;
    double worst = 0.0;
    for (int k = 0; k < s.bands.size(); ++k)
        if (s.bands.centreHz[k] >= 100.0 && s.bands.centreHz[k] <= 5000.0)
            worst = std::max(worst, std::fabs(s.baselineDb[k]));
    return worst;
}

int bandOf(const BandLayout &b, double hz)
{
    for (int k = 0; k < b.size(); ++k)
        if (hz >= b.loHz[k] && hz < b.hiHz[k]) return k;
    return -1;
}

}  // namespace

int main()
{
    std::printf("test_essb_coach\n");

    // bands_sixth_octave
    {
        const BandLayout b = makeBands(40.0, 12000.0);
        check("bands_sixth_octave: centre[0]==40", b.centreHz[0] == 40.0, b.centreHz[0]);
        check("bands_sixth_octave: centre[6]~80",
              std::fabs(b.centreHz[6] - 80.0) < 0.01, b.centreHz[6]);
        const double want = std::pow(2.0, 1.0 / 6.0);
        bool ratios = b.size() > 2;
        for (int k = 1; k < b.size(); ++k)
            ratios = ratios && std::fabs(b.centreHz[k] / b.centreHz[k - 1] - want) < 1e-9;
        check("bands_sixth_octave: adjacent ratio 2^(1/6)", ratios, b.size());
        check("bands_sixth_octave: last centre <= 12000",
              b.centreHz.back() <= 12000.0 * (1 + 1e-9), b.centreHz.back());
        const double e = std::pow(2.0, 1.0 / 12.0);
        check("bands_sixth_octave: edges centre*2^(+-1/12)",
              std::fabs(b.loHz[10] * e - b.centreHz[10]) < 1e-9
                  && std::fabs(b.hiHz[10] / e - b.centreHz[10]) < 1e-9,
              b.loHz[10]);
    }

    const std::vector<Target> ts = builtinTargets();
    const Target *essb = find(ts, "essb");

    check("builtins: order essb,midfi,typical,am",
          ts.size() == 4 && ts[0].id == "essb" && ts[1].id == "midfi"
              && ts[2].id == "typical" && ts[3].id == "am", ts.size());
    if (!essb) { std::printf("essb target missing\n"); return 1; }

    // target_interp_log
    {
        check("target_interp_log: essb@100 == 3", targetDbAt(*essb, 100.0) == 3.0,
              targetDbAt(*essb, 100.0));
        check("target_interp_log: essb@1000 == 0", targetDbAt(*essb, 1000.0) == 0.0,
              targetDbAt(*essb, 1000.0));
        const double v = targetDbAt(*essb, 60.0);
        check("target_interp_log: essb@60 strictly in (0,3)", v > 0.0 && v < 3.0, v);
        const double mid = targetDbAt(*essb, std::sqrt(50.0 * 70.0));
        check("target_interp_log: log-midpoint of 50..70 is 1.5",
              std::fabs(mid - 1.5) < 1e-9, mid);
        check("target_interp_log: clamped flat below/above ends",
              targetDbAt(*essb, 10.0) == 0.0 && targetDbAt(*essb, 20000.0) == 0.0,
              targetDbAt(*essb, 10.0));
    }

    // target_tolerance_split
    check("target_tolerance_split: essb@100 == 5", toleranceAt(*essb, 100.0) == 5.0,
          toleranceAt(*essb, 100.0));
    check("target_tolerance_split: essb@1000 == 3", toleranceAt(*essb, 1000.0) == 3.0,
          toleranceAt(*essb, 1000.0));

    // zones
    {
        const auto z = defaultZones(6000.0);
        const ZoneId ids[5] = {ZoneId::Bass, ZoneId::LowMid, ZoneId::Body,
                               ZoneId::Upper, ZoneId::Top};
        const double lo[5] = {60.0, 150.0, 600.0, 2000.0, 3500.0};
        const double hi[5] = {150.0, 600.0, 2000.0, 3500.0, 6000.0};
        check("zones: 5 zones", z.size() == 5, z.size());
        for (size_t k = 0; k < z.size() && k < 5; ++k) {
            char nm[64];
            std::snprintf(nm, sizeof nm, "zones: zone %zu id/lo/hi", k);
            check(nm, z[k].id == ids[k] && z[k].loHz == lo[k] && z[k].hiHz == hi[k],
                  z[k].loHz);
        }
        const auto z2 = defaultZones(9000.0);
        check("zones: Top hi follows targetHighEdgeHz",
              z2.size() == 5 && z2.back().hiHz == 9000.0, z2.back().hiHz);
    }

    // normalise_mids_zero
    {
        const BandLayout b = makeBands();
        std::vector<double> db(b.size());
        for (int k = 0; k < b.size(); ++k) db[k] = -40.0 + 7.0 * std::sin(k * 0.7);
        normalise(db, b);
        double sum = 0.0; int n = 0;
        for (int k = 0; k < b.size(); ++k)
            if (b.centreHz[k] >= 500.0 && b.centreHz[k] <= 2000.0) { sum += db[k]; ++n; }
        const double mean = n ? sum / n : 1e9;
        check("normalise_mids_zero: mean of 500-2000 Hz bands == 0",
              n > 0 && std::fabs(mean) < 1e-9, mean);
    }

    // target_json_roundtrip
    for (const auto &t : ts) {
        Target back;
        const bool ok = targetFromJson(targetToJson(t), back) && same(t, back);
        check(("target_json_roundtrip: " + t.id).c_str(), ok, t.points.size());
    }
    {
        Target custom = *essb;
        custom.id = "my \"custom\"\\1"; custom.name = "Mine\n(\xC2\xB1" "3 dB)";
        custom.builtin = false; custom.points = {{55.5, -1.25}, {1234.5, 2.5}};
        Target back;
        check("target_json_roundtrip: custom with escapes",
              targetFromJson(targetToJson(custom), back) && same(custom, back), 0);
        Target junk;
        check("target_json_reject: garbage fails",
              !targetFromJson("not json", junk) && !targetFromJson("", junk), 0);
    }

    // analyzer_tone_lands_in_band
    {
        CoachAnalyzer a(kFs);
        a.prepare();
        std::vector<double> x(static_cast<size_t>(2 * kFs));
        for (size_t i = 0; i < x.size(); ++i)
            x[i] = 0.3 * std::sin(2.0 * kPi * 1000.0 * static_cast<double>(i) / kFs);
        feedAll(a, x, 512);
        CoachSnapshot s;
        const bool got = a.snapshot(s);
        int best = -1;
        for (int k = 0; k < static_cast<int>(s.liveDb.size()); ++k)
            if (best < 0 || s.liveDb[k] > s.liveDb[best]) best = k;
        check("analyzer_tone_lands_in_band: snapshot + live present",
              got && s.liveDb.size() == static_cast<size_t>(s.bands.size()), s.liveDb.size());
        check("analyzer_tone_lands_in_band: peak band holds 1 kHz",
              best >= 0 && best == bandOf(s.bands, 1000.0), best);
    }

    // analyzer_pink_flat / analyzer_shaped_80hz
    for (int shaped = 0; shaped < 2; ++shaped) {
        CoachAnalyzer a(kFs);
        a.prepare();
        std::vector<double> x = pinkNoise(static_cast<size_t>(20 * kFs), 0.1, 12345u);
        if (shaped) peaking(x, 80.0, 6.0, 1.0);
        burstify(x);
        a.startBaseline();
        feedAll(a, x, 480);
        CoachSnapshot s;
        a.snapshot(s);
        double worst = 0.0;
        for (int k = 0; k < s.bands.size() && k < static_cast<int>(s.baselineDb.size()); ++k)
            if (s.bands.centreHz[k] >= 100.0 && s.bands.centreHz[k] <= 5000.0)
                worst = std::max(worst, std::fabs(s.baselineDb[k]));
        if (!shaped) {
            check("analyzer_pink_flat: baseline present, running",
                  !s.baselineDb.empty() && s.baseline == AvgState::Running, s.baselineDb.size());
            check("analyzer_pink_flat: |baselineDb| < 1.5 over 100 Hz-5 kHz",
                  !s.baselineDb.empty() && worst < 1.5, worst);
        } else {
            const int b80 = bandOf(s.bands, 80.0);
            const double v = (b80 >= 0 && b80 < static_cast<int>(s.baselineDb.size()))
                                 ? s.baselineDb[b80] : -999.0;
            check("analyzer_shaped_80hz: baselineDb at 80 Hz band = 6 +- 1.5",
                  std::fabs(v - 6.0) < 1.5, v);
        }
    }

    // feed_large_block_chunks
    {
        CoachAnalyzer big(kFs), small(kFs);
        big.prepare();
        small.prepare();
        const std::vector<double> x = pinkNoise(10000, 0.1, 777u);
        big.feed(x.data(), 10000, 0.0);
        feedAll(small, x, 100);
        CoachSnapshot sb, ss;
        big.snapshot(sb);
        small.snapshot(ss);
        double maxd = 1e9;
        if (!sb.liveDb.empty() && sb.liveDb.size() == ss.liveDb.size()) {
            maxd = 0.0;
            for (size_t k = 0; k < sb.liveDb.size(); ++k)
                maxd = std::max(maxd, std::fabs(sb.liveDb[k] - ss.liveDb[k]));
        }
        check("feed_large_block_chunks: 1x10000 vs 100x100 within 0.1 dB", maxd < 0.1, maxd);
    }

    // ---- Task 3: speech gate, noise floor, AGC correction, compression ----

    // gate_silence_no_speech
    {
        const CoachSnapshot s = runBaseline(whiteNoise(static_cast<size_t>(30 * kFs),
                                                       dbToAmp(-60.0), 31u));
        check("gate_silence_no_speech: speechSec < 0.5", s.speechSec < 0.5, s.speechSec);
        check("gate_silence_no_speech: baseline curve empty", s.baselineDb.empty(),
              s.baselineDb.size());
    }

    // gate_bursts_excluded
    {
        std::vector<double> x;
        const double burstSec = burstSignal(x, 30.0, 1.5, 1.0, -20.0,
                                            [](double) { return -60.0; }, 4242u);
        const CoachSnapshot s = runBaseline(x);
        check("gate_bursts_excluded: speechSec within 15 % of burst time",
              std::fabs(s.speechSec - burstSec) <= 0.15 * burstSec, s.speechSec);
        check("gate_bursts_excluded: |baselineDb| < 2 over 100 Hz-5 kHz",
              flatness(s) < 2.0, flatness(s));
        check("gate_bursts_excluded: gap-to-speech not flagged (40 dB apart)",
              s.comp.gapToSpeechDb >= kGapToSpeechFlagDb, s.comp.gapToSpeechDb);
    }

    // hiss_no_highs
    {
        const CoachSnapshot s = runBaseline(whiteNoise(static_cast<size_t>(30 * kFs),
                                                       dbToAmp(-50.0), 77u));
        check("hiss_no_highs: !(medianSnrDb >= 15)", !(s.medianSnrDb >= 15.0), s.medianSnrDb);
    }

    // pumping_detected / pumping_steady_none
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0,
                    [](double t) { return -60.0 + 10.0 * std::min(t / 0.8, 1.0); }, 99u);
        const CoachSnapshot p = runBaseline(x);
        check("pumping_detected: gapRiseDb > 6", p.comp.gapRiseDb > 6.0, p.comp.gapRiseDb);
        check("pumping_detected: pauses counted", p.comp.pauses > 0, p.comp.pauses);

        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 99u);
        const CoachSnapshot q = runBaseline(x);
        check("pumping_steady_none: gapRiseDb < 2", q.comp.gapRiseDb < 2.0, q.comp.gapRiseDb);
        check("pumping_steady_none: pauses counted", q.comp.pauses > 0, q.comp.pauses);
    }

    // agc_corrected_no_pumping: steady bursts/pauses through a simulated AGC
    // that drops 15 dB on each burst and recovers over 600 ms of the pause.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 555u);
        const size_t nBlocks = (x.size() + 479) / 480;
        std::vector<double> gain(nBlocks);
        for (size_t k = 0; k < nBlocks; ++k) {
            const double t = std::fmod(static_cast<double>(k * 480) / kFs, 2.5);
            gain[k] = t < 1.5 ? -15.0 : -15.0 + 15.0 * std::min((t - 1.5) / 0.6, 1.0);
        }
        for (size_t i = 0; i < x.size(); ++i) x[i] *= dbToAmp(gain[i / 480]);
        const CoachSnapshot s = runBaseline(x, &gain);
        check("agc_corrected_no_pumping: gapRiseDb < 2", s.comp.gapRiseDb < 2.0,
              s.comp.gapRiseDb);
        check("agc_corrected_no_pumping: pauses counted", s.comp.pauses > 0, s.comp.pauses);
        check("agc_corrected_no_pumping: gap-to-speech not flagged",
              s.comp.gapToSpeechDb >= kGapToSpeechFlagDb, s.comp.gapToSpeechDb);
    }

    // crest_dynamic_vs_flat: bursts whose level jumps every 50 ms across
    // 0..-24 dB read as dynamic; flat-level bursts read as squashed.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 321u);
        const CoachSnapshot flat = runBaseline(x);
        std::mt19937 rng(9u);
        std::uniform_real_distribution<double> u(-24.0, 0.0);
        const size_t seg = static_cast<size_t>(0.05 * kFs);
        for (size_t i = 0; i < x.size(); i += seg) {
            const double g = dbToAmp(u(rng));
            for (size_t j = i; j < std::min(i + seg, x.size()); ++j)
                if (std::fmod(static_cast<double>(j) / kFs, 2.5) < 1.5) x[j] *= g;
        }
        const CoachSnapshot dyn = runBaseline(x);
        check("crest_dynamic_vs_flat: flat bursts crest < 8", flat.comp.crestDb < kCrestFlagDb,
              flat.comp.crestDb);
        check("crest_dynamic_vs_flat: dynamic bursts crest > 8", dyn.comp.crestDb > kCrestFlagDb,
              dyn.comp.crestDb);
    }

    // noinfo_span_mid_baseline: 6 s of loud "own transmit" audio (a -6 dBFS
    // 1 kHz tone over -10 dBFS white noise) spliced into the middle of a
    // baseline, fed with NaN gain the way WdspEngine marks TX, leaves the
    // curve and compression metrics where the same baseline without the span
    // puts them.  The control feeds the span with a finite gain.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0,
                    [](double t) { return -60.0 + 10.0 * std::min(t / 0.8, 1.0); }, 2718u);
        // Mid-burst and 480-aligned, placed so the FFT frame (hop 2048) on
        // each side of the span is ~75-90 % speech: it would pass the 70 %
        // speech rule and carry the TX audio if it were kept.
        const size_t at = 1578 * 480;   // 15.78 s
        const size_t spanN = static_cast<size_t>(6.0 * kFs);
        std::vector<double> tx = whiteNoise(spanN, dbToAmp(-10.0), 31u);
        for (size_t i = 0; i < spanN; ++i)
            tx[i] += dbToAmp(-6.0) * std::sin(2.0 * kPi * 1000.0 * static_cast<double>(i) / kFs);
        std::vector<double> y(x.begin(), x.begin() + static_cast<long>(at));
        y.insert(y.end(), tx.begin(), tx.end());
        y.insert(y.end(), x.begin() + static_cast<long>(at), x.end());
        const size_t nBlocks = (y.size() + 479) / 480;
        std::vector<double> nanGain(nBlocks, 0.0), zeroGain(nBlocks, 0.0);
        for (size_t k = at / 480; k < (at + spanN) / 480; ++k) nanGain[k] = NAN;

        const CoachSnapshot ref = runBaseline(x);
        const CoachSnapshot gated = runBaseline(y, &nanGain);
        const CoachSnapshot ungated = runBaseline(y, &zeroGain);
        auto curveDiff = [&](const CoachSnapshot &a, const CoachSnapshot &b) {
            if (a.baselineDb.size() != b.baselineDb.size() || a.baselineDb.empty()) return 1e9;
            double worst = 0.0;
            for (int k = 0; k < a.bands.size(); ++k)
                if (a.bands.centreHz[k] >= 100.0 && a.bands.centreHz[k] <= 5000.0)
                    worst = std::max(worst, std::fabs(a.baselineDb[k] - b.baselineDb[k]));
            return worst;
        };
        check("noinfo_span_mid_baseline: precondition pumping measured",
              ref.comp.gapRiseDb > 6.0 && ref.comp.pauses > 0, ref.comp.gapRiseDb);
        check("noinfo_span_mid_baseline: curve within 1 dB of no-span baseline",
              curveDiff(ref, gated) < 1.0, curveDiff(ref, gated));
        check("noinfo_span_mid_baseline: speechSec within 0.5 s",
              std::fabs(gated.speechSec - ref.speechSec) < 0.5, gated.speechSec - ref.speechSec);
        check("noinfo_span_mid_baseline: gapToSpeech within 1 dB",
              std::fabs(gated.comp.gapToSpeechDb - ref.comp.gapToSpeechDb) < 1.0,
              gated.comp.gapToSpeechDb - ref.comp.gapToSpeechDb);
        check("noinfo_span_mid_baseline: gapRise within 1 dB",
              std::fabs(gated.comp.gapRiseDb - ref.comp.gapRiseDb) < 1.0,
              gated.comp.gapRiseDb - ref.comp.gapRiseDb);
        check("noinfo_span_mid_baseline: crest within 1 dB",
              std::fabs(gated.comp.crestDb - ref.comp.crestDb) < 1.0,
              gated.comp.crestDb - ref.comp.crestDb);
        check("noinfo_span_mid_baseline: pauses within 1",
              std::abs(gated.comp.pauses - ref.comp.pauses) <= 1, gated.comp.pauses - ref.comp.pauses);
        check("noinfo_span_mid_baseline: control (finite gain) moves the curve > 3 dB",
              curveDiff(ref, ungated) > 3.0, curveDiff(ref, ungated));

        // noinfo_blips_in_speech: 20 ms no-information blips inside words.
        // An FFT frame holding one is ~77 % speech, so only the rule that a
        // frame touching a no-information block is dropped keeps the blip's
        // tone out of the curve.
        std::vector<double> z = x;
        std::vector<double> blipGain((z.size() + 479) / 480, 0.0);
        for (size_t k = 0; k < blipGain.size(); k += 30) {          // every 0.3 s
            const double t = std::fmod(static_cast<double>(k * 480) / kFs, 2.5);
            if (t < 0.2 || t > 1.2) continue;                      // inside a burst only
            for (size_t j = k * 480; j < std::min((k + 2) * 480, z.size()); ++j)
                z[j] = dbToAmp(-6.0) * std::sin(2.0 * kPi * 1000.0 * static_cast<double>(j) / kFs);
            blipGain[k] = blipGain[k + 1] = NAN;
        }
        const CoachSnapshot blips = runBaseline(z, &blipGain);
        check("noinfo_blips_in_speech: curve within 1 dB of the clean baseline",
              curveDiff(ref, blips) < 1.0, curveDiff(ref, blips));
    }

    // reset_clears_all
    {
        CoachAnalyzer a(kFs);
        a.prepare();
        std::vector<double> x;
        burstSignal(x, 12.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 8u);
        a.startBaseline();
        a.startRecheck();
        feedBlocks(a, x);
        CoachSnapshot before;
        a.snapshot(before);
        check("reset_clears_all: precondition baseline+recheck+metrics present",
              !before.baselineDb.empty() && !before.recheckDb.empty() && before.speechSec > 0
                  && !std::isnan(before.comp.gapToSpeechDb) && !std::isnan(before.medianSnrDb),
              before.speechSec);
        a.reset();
        a.feed(x.data(), 0, 0.0);
        CoachSnapshot s;
        a.snapshot(s);
        check("reset_clears_all: curves empty",
              s.liveDb.empty() && s.baselineDb.empty() && s.recheckDb.empty()
                  && s.bandSnrDb.empty(), s.baselineDb.size());
        check("reset_clears_all: speechSec == 0 (base and recheck)",
              s.speechSec == 0.0 && s.recheckSpeechSec == 0.0, s.speechSec);
        check("reset_clears_all: metrics all NaN",
              allNan(s.comp) && allNan(s.recheckComp) && std::isnan(s.medianSnrDb),
              s.medianSnrDb);
        check("reset_clears_all: states idle",
              s.baseline == AvgState::Idle && s.recheck == AvgState::Idle, 0);
    }

    // control_sequence: start -> feed -> stop (held) -> start (cleared) ->
    // reset (empty) -> freeze (live held); plus reset-wins ordering.
    {
        CoachAnalyzer a(kFs);
        a.prepare();
        std::vector<double> x, y;
        burstSignal(x, 10.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 1u);
        y = x;
        peaking(y, 1000.0, 12.0, 1.0);   // a clearly different spectrum
        CoachSnapshot s1, s2, s3, s4, s5, s6;
        a.startBaseline();
        feedBlocks(a, x);
        a.snapshot(s1);
        check("control_sequence: running with a curve",
              s1.baseline == AvgState::Running && !s1.baselineDb.empty(), s1.speechSec);
        a.stopBaseline();
        feedBlocks(a, y);
        a.snapshot(s2);
        check("control_sequence: stop holds curve and speechSec",
              s2.baseline == AvgState::Stopped && s2.baselineDb == s1.baselineDb
                  && s2.speechSec == s1.speechSec, s2.speechSec);
        a.startBaseline();
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s3);
        check("control_sequence: start again clears",
              s3.baseline == AvgState::Running && s3.baselineDb.empty() && s3.speechSec == 0.0
                  && allNan(s3.comp), s3.baselineDb.size());
        feedBlocks(a, x);
        a.reset();
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s4);
        check("control_sequence: reset empties",
              s4.baseline == AvgState::Idle && s4.baselineDb.empty() && s4.liveDb.empty()
                  && s4.speechSec == 0.0, s4.baselineDb.size());
        feedBlocks(a, x);
        a.freeze(true);
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s5);
        feedBlocks(a, y);
        a.snapshot(s6);
        check("control_sequence: freeze holds live trace",
              s5.frozen && s6.frozen && !s5.liveDb.empty() && s6.liveDb == s5.liveDb, 0);
        a.freeze(false);

        CoachAnalyzer b(kFs);
        b.prepare();
        b.startBaseline();
        b.reset();
        feedBlocks(b, x);
        CoachSnapshot r;
        b.snapshot(r);
        check("control_sequence: startBaseline(); reset(); -> idle",
              r.baseline == AvgState::Idle && r.baselineDb.empty(), r.speechSec);
        b.reset();
        b.startBaseline();
        feedBlocks(b, x);
        b.snapshot(r);
        check("control_sequence: reset(); startBaseline(); -> running",
              r.baseline == AvgState::Running && !r.baselineDb.empty(), r.speechSec);
    }

    // recheck_lap: a re-check that ends (stopRecheck, or a startRecheck that
    // overtakes a running one) is kept as the lap, tagged with the id its
    // startRecheck() returned.  stop+start posted back to back coalesce into
    // one start (newest wins), yet the ended pass still lands in the lap.
    {
        CoachAnalyzer a(kFs);
        a.prepare();
        std::vector<double> x, y;
        burstSignal(x, 10.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 1u);
        y = x;
        peaking(y, 1000.0, 12.0, 1.0);
        CoachSnapshot s0, s1, s2, s3, s4, s5;
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s0);
        check("recheck_lap: none before any re-check", s0.lapId == 0 && s0.lapDb.empty(), 0);
        const std::uint64_t id1 = a.startRecheck();
        feedBlocks(a, x);
        a.snapshot(s1);
        a.stopRecheck();
        const std::uint64_t id2 = a.startRecheck();   // same poll interval: coalesces
        feedBlocks(a, y);
        a.snapshot(s2);
        check("recheck_lap: ids nonzero and increasing", id1 > 0 && id2 > id1, double(id2));
        check("recheck_lap: coalesced stop+start -> lap is the ended pass",
              s2.lapId == id1 && !s2.lapDb.empty() && s2.lapDb == s1.recheckDb
                  && s2.lapSpeechSec == s1.recheckSpeechSec, s2.lapSpeechSec);
        check("recheck_lap: lap compression carried",
              s2.lapComp.pauses == s1.recheckComp.pauses && s2.lapComp.pauses > 0, s2.lapComp.pauses);
        check("recheck_lap: new pass running on its own audio",
              s2.recheck == AvgState::Running && !s2.recheckDb.empty() && s2.recheckDb != s1.recheckDb,
              s2.recheckSpeechSec);
        a.stopRecheck();
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s3);
        check("recheck_lap: plain stop -> Stopped and lap tagged id2",
              s3.recheck == AvgState::Stopped && s3.lapId == id2 && s3.lapDb == s2.recheckDb, 0);
        const std::uint64_t id3 = a.startRecheck();
        feedBlocks(a, x);
        a.snapshot(s4);
        check("recheck_lap: start after a stop keeps the stopped lap",
              id3 > id2 && s4.lapId == id2 && s4.lapDb == s3.lapDb, double(s4.lapId));
        a.reset();
        a.feed(x.data(), 0, 0.0);
        a.snapshot(s5);
        check("recheck_lap: reset clears the lap, running pass discarded",
              s5.lapId == 0 && s5.lapDb.empty() && s5.recheck == AvgState::Idle, double(s5.lapId));
    }

    // envelope_direct: CoachEnvelope on its own tracks the floor and gates.
    {
        CoachEnvelope e(kFs);
        e.prepare();
        const std::vector<double> n = whiteNoise(static_cast<size_t>(3 * kFs), dbToAmp(-60.0), 5u);
        bool any = false;
        for (size_t i = 0; i < n.size(); i += 480)
            any = e.push(n.data() + i, 480, 0.0) || any;
        // White noise limited to 100-5000 Hz sits 10*log10(4900/24000) below
        // its broadband level.
        const double want = -60.0 + 10.0 * std::log10(4900.0 / 24000.0);
        check("envelope_direct: floor within 2 dB of the band-limited noise",
              std::fabs(e.noiseFloorDb() - want) < 2.0, e.noiseFloorDb());
        check("envelope_direct: steady noise never gates as speech", !any, any);
        const std::vector<double> loud = whiteNoise(4800, dbToAmp(-20.0), 6u);
        bool sp = false;
        for (size_t i = 0; i < loud.size(); i += 480) sp = e.push(loud.data() + i, 480, 0.0);
        check("envelope_direct: +40 dB block is speech", sp, sp);
        e.reset();
        check("envelope_direct: reset clears floor and metrics",
              std::isnan(e.noiseFloorDb()) && allNan(e.metrics()), e.noiseFloorDb());
    }

    // ---- Task 3 fix round 1 ----

    // pumping_strong: +15 / +20 dB pause ramps over 800 ms and 300 ms must
    // read as pumping, not as speech.
    for (double riseDb : {15.0, 20.0}) {
        for (double rampSec : {0.8, 0.3}) {
            std::vector<double> x;
            const double burstSec = burstSignal(
                x, 30.0, 1.5, 1.0, -20.0,
                [=](double t) { return -60.0 + riseDb * std::min(t / rampSec, 1.0); }, 99u);
            const CoachSnapshot s = runBaseline(x);
            char nm[96];
            std::snprintf(nm, sizeof nm, "pumping_strong +%.0f dB/%.0f ms: gapRiseDb > 6",
                          riseDb, rampSec * 1000.0);
            check(nm, s.comp.gapRiseDb > 6.0, s.comp.gapRiseDb);
            std::snprintf(nm, sizeof nm, "pumping_strong +%.0f dB/%.0f ms: pauses > 0",
                          riseDb, rampSec * 1000.0);
            check(nm, s.comp.pauses > 0, s.comp.pauses);
            std::snprintf(nm, sizeof nm, "pumping_strong +%.0f dB/%.0f ms: speechSec within 15 %%",
                          riseDb, rampSec * 1000.0);
            check(nm, std::fabs(s.speechSec - burstSec) <= 0.15 * burstSec, s.speechSec);
        }
    }

    // cold_start_snr: audio starts on a burst; the opening burst must not be
    // filed as noise.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 2024u);
        const CoachSnapshot s = runBaseline(x);
        check("cold_start_snr: medianSnrDb = 40 +- 3", std::fabs(s.medianSnrDb - 40.0) <= 3.0,
              s.medianSnrDb);
    }

    // reset_mid_burst_snr: reset + start 0.75 s into a burst.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 2025u);
        const size_t cut = static_cast<size_t>(10.75 * kFs);
        CoachAnalyzer a(kFs);
        a.prepare();
        a.startBaseline();
        const std::vector<double> head(x.begin(), x.begin() + static_cast<long>(cut));
        const std::vector<double> tail(x.begin() + static_cast<long>(cut), x.end());
        feedBlocks(a, head);
        a.reset();
        a.startBaseline();
        feedBlocks(a, tail);
        CoachSnapshot s;
        a.snapshot(s);
        check("reset_mid_burst_snr: medianSnrDb = 40 +- 3", std::fabs(s.medianSnrDb - 40.0) <= 3.0,
              s.medianSnrDb);
    }

    // flat_long_segments: 4 s of flat-level speech between 1 s gaps must not
    // drag the floor up into the speech.
    {
        std::vector<double> x;
        const double burstSec = burstSignal(x, 30.0, 4.0, 1.0, -20.0,
                                            [](double) { return -60.0; }, 4u);
        const CoachSnapshot s = runBaseline(x);
        check("flat_long_segments: medianSnrDb = 40 +- 3", std::fabs(s.medianSnrDb - 40.0) <= 3.0,
              s.medianSnrDb);
        check("flat_long_segments: gap-to-speech not flagged",
              s.comp.gapToSpeechDb >= kGapToSpeechFlagDb, s.comp.gapToSpeechDb);
        check("flat_long_segments: speechSec within 15 % of burst time",
              std::fabs(s.speechSec - burstSec) <= 0.15 * burstSec, s.speechSec);
    }

    // agc_chunked_feeds: the agc_corrected_no_pumping AGC, but one gain per
    // 256- or 1000-sample feed() call, so 10 ms blocks straddle two gains.
    for (size_t chunk : {size_t{256}, size_t{1000}}) {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 555u);
        const CoachSnapshot s = runBaselineAgcChunks(x, chunk, [](double t) {
            const double u = std::fmod(t, 2.5);
            return u < 1.5 ? -15.0 : -15.0 + 15.0 * std::min((u - 1.5) / 0.6, 1.0);
        });
        char nm[96];
        std::snprintf(nm, sizeof nm, "agc_chunked_feeds %zu: gapRiseDb < 2", chunk);
        check(nm, s.comp.gapRiseDb < 2.0, s.comp.gapRiseDb);
        std::snprintf(nm, sizeof nm, "agc_chunked_feeds %zu: pauses counted", chunk);
        check(nm, s.comp.pauses > 0, s.comp.pauses);
        std::snprintf(nm, sizeof nm, "agc_chunked_feeds %zu: gap-to-speech not flagged", chunk);
        check(nm, s.comp.gapToSpeechDb >= kGapToSpeechFlagDb, s.comp.gapToSpeechDb);
    }

    // envelope_gain_per_sample: one 10 ms block fed as two halves with
    // different AGC gains reads as the uncorrected level.
    {
        CoachEnvelope ref(kFs), cut(kFs);
        ref.prepare();
        cut.prepare();
        std::vector<double> n = whiteNoise(48000, dbToAmp(-30.0), 12u);
        for (size_t i = 0; i < n.size(); i += 480) ref.push(n.data() + i, 480, 0.0);
        for (size_t i = 0; i < n.size(); i += 480) {
            for (size_t j = i + 240; j < i + 480; ++j) n[j] *= dbToAmp(-20.0);
            cut.push(n.data() + i, 240, 0.0);
            cut.push(n.data() + i + 240, 240, -20.0);
        }
        const double d = cut.block(cut.blocksDone() - 1).levelDb
                         - ref.block(ref.blocksDone() - 1).levelDb;
        check("envelope_gain_per_sample: straddling block within 0.5 dB", std::fabs(d) < 0.5, d);
    }

    // ---- Task 3 fix round 2: digital silence carries no information ----

    // silence_block_mid_run: a 10 / 20 / 100 ms all-zero run 0.5 s into a
    // pause (a single block mid-burst is filled by filter ringing and reads
    // ~-31 dB, so it is no test).  Baseline started just after the zeros;
    // the floor must be back at the gap level 2.6 s later.
    for (size_t nz : {size_t{480}, size_t{960}, size_t{4800}}) {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 31337u);
        const size_t z = static_cast<size_t>(12.0 * kFs);
        std::fill(x.begin() + static_cast<long>(z), x.begin() + static_cast<long>(z + nz), 0.0);
        const std::vector<double> head(x.begin(), x.begin() + static_cast<long>(z + nz));
        const std::vector<double> tail(x.begin() + static_cast<long>(z + nz), x.end());
        double burstSec = 0.0;
        for (size_t k = z + nz; k < x.size(); ++k)
            if (std::fmod(static_cast<double>(k) / kFs, 2.5) < 1.5) burstSec += 1.0 / kFs;
        CoachAnalyzer a(kFs);
        a.prepare();
        feedBlocks(a, head);
        a.startBaseline();
        feedBlocks(a, tail);
        CoachSnapshot s;
        a.snapshot(s);
        char nm[96];
        std::snprintf(nm, sizeof nm, "silence_block_mid_run %zu ms: medianSnrDb = 40 +- 3", nz / 48);
        check(nm, std::fabs(s.medianSnrDb - 40.0) <= 3.0, s.medianSnrDb);
        std::snprintf(nm, sizeof nm, "silence_block_mid_run %zu ms: speechSec within 15 %%", nz / 48);
        check(nm, std::fabs(s.speechSec - burstSec) <= 0.15 * burstSec, s.speechSec);

        CoachEnvelope e(kFs);
        e.prepare();
        double gapSum = 0.0;
        int gapN = 0;
        for (size_t k = 0; k + 480 <= static_cast<size_t>(14.6 * kFs); k += 480) {
            e.push(x.data() + k, 480, 0.0);
            const double t = static_cast<double>(k) / kFs;
            if (t >= 11.6 && t < 11.95) { gapSum += e.block(e.blocksDone() - 1).levelDb; ++gapN; }
        }
        const double gapDb = gapSum / gapN;
        std::snprintf(nm, sizeof nm, "silence_block_mid_run %zu ms: floor back at gap level", nz / 48);
        check(nm, std::fabs(e.noiseFloorDb() - gapDb) < 3.0, e.noiseFloorDb());
        std::snprintf(nm, sizeof nm, "silence_block_mid_run %zu ms: gap block is noise again", nz / 48);
        check(nm, e.block(e.blocksDone() - 1).noise, 0);
    }

    // silence_prefix: 2 s of digital zero before the burst signal.
    {
        std::vector<double> x;
        const double burstSec = burstSignal(x, 30.0, 1.5, 1.0, -20.0,
                                            [](double) { return -60.0; }, 4711u);
        x.insert(x.begin(), static_cast<size_t>(2.0 * kFs), 0.0);
        const CoachSnapshot s = runBaseline(x);
        check("silence_prefix: medianSnrDb = 40 +- 3", std::fabs(s.medianSnrDb - 40.0) <= 3.0,
              s.medianSnrDb);
        check("silence_prefix: speechSec within 15 % of burst time",
              std::fabs(s.speechSec - burstSec) <= 0.15 * burstSec, s.speechSec);
    }

    // ---- Task 6 fix round 1: unknown (NaN) AGC gain = no information ----

    // envelope_nan_gain_noinfo: 256-sample pushes; those starting in
    // [1.0, 1.2) s carry NaN.  Exactly the 10 ms blocks that hold a NaN-gain
    // sample are noInfo (including the straddling ones); the rest are not.
    {
        const std::vector<double> n = whiteNoise(static_cast<size_t>(2.4 * kFs), dbToAmp(-30.0), 99u);
        const auto isNan = [](size_t i) {
            const double t = static_cast<double>(i) / kFs;
            return t >= 1.0 && t < 1.2;
        };
        size_t nanLo = n.size(), nanHi = 0;
        for (size_t i = 0; i < n.size(); i += 256)
            if (isNan(i)) { nanLo = std::min(nanLo, i); nanHi = std::max(nanHi, std::min(i + 256, n.size())); }
        CoachEnvelope f(kFs);
        f.prepare();
        long long wrong = 0, nanBlocks = 0;
        for (size_t i = 0; i < n.size(); i += 256) {
            const size_t len = std::min<size_t>(256, n.size() - i);
            const long long before = f.blocksDone();
            f.push(n.data() + i, static_cast<int>(len), isNan(i) ? NAN : 0.0);
            for (long long b = before; b < f.blocksDone(); ++b) {
                const size_t s0 = static_cast<size_t>(b) * 480, s1 = s0 + 480;
                const bool expect = s0 < nanHi && s1 > nanLo;
                if (f.block(b).noInfo != expect) ++wrong;
                if (expect) ++nanBlocks;
            }
        }
        check("envelope_nan_gain_noinfo: noInfo exactly on NaN-gain blocks", wrong == 0,
              static_cast<double>(wrong));
        check("envelope_nan_gain_noinfo: NaN run spans 20-22 blocks", nanBlocks >= 20 && nanBlocks <= 22,
              static_cast<double>(nanBlocks));
    }

    // agc_nan_withholds_compression: the pumping AGC applied to the audio but
    // its gain reported as NaN throughout -> no compression metrics at all.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 555u);
        CoachAnalyzer a(kFs);
        a.prepare();
        a.startBaseline();
        for (size_t i = 0; i < x.size(); i += 256) {
            const size_t n = std::min<size_t>(256, x.size() - i);
            const double u = std::fmod(static_cast<double>(i) / kFs, 2.5);
            const double g = u < 1.5 ? -15.0 : -15.0 + 15.0 * std::min((u - 1.5) / 0.6, 1.0);
            for (size_t j = i; j < i + n; ++j) x[j] *= dbToAmp(g);
            a.feed(x.data() + i, static_cast<int>(n), NAN);
        }
        CoachSnapshot s;
        a.snapshot(s);
        check("agc_nan_withholds_compression: metrics all NaN", allNan(s.comp), s.comp.gapRiseDb);
    }

    // agc_nan_resync_then_corrected: as agc_chunked_feeds 256, but the first
    // two 4096-frame DSP blocks report NaN (the engine's resync) -> the
    // corrected metrics still read clean.
    {
        std::vector<double> x;
        burstSignal(x, 30.0, 1.5, 1.0, -20.0, [](double) { return -60.0; }, 555u);
        const CoachSnapshot s = runBaselineAgcChunks(x, 256, [](double t) {
            const double u = std::fmod(t, 2.5);
            return u < 1.5 ? -15.0 : -15.0 + 15.0 * std::min((u - 1.5) / 0.6, 1.0);
        });
        CoachAnalyzer a(kFs);
        a.prepare();
        a.startBaseline();
        for (size_t i = 0; i < x.size(); i += 256) {
            const size_t n = std::min<size_t>(256, x.size() - i);
            const double u = std::fmod(static_cast<double>(i) / kFs, 2.5);
            const double g = u < 1.5 ? -15.0 : -15.0 + 15.0 * std::min((u - 1.5) / 0.6, 1.0);
            for (size_t j = i; j < i + n; ++j) x[j] *= dbToAmp(g);
            a.feed(x.data() + i, static_cast<int>(n), i < 2 * 4096 ? NAN : g);
        }
        CoachSnapshot r;
        a.snapshot(r);
        check("agc_nan_resync_then_corrected: gapRiseDb < 2", r.comp.gapRiseDb < 2.0, r.comp.gapRiseDb);
        check("agc_nan_resync_then_corrected: pauses counted", r.comp.pauses > 0, r.comp.pauses);
        check("agc_nan_resync_then_corrected: gap-to-speech not flagged",
              r.comp.gapToSpeechDb >= kGapToSpeechFlagDb, r.comp.gapToSpeechDb);
        check("agc_nan_resync_then_corrected: close to the all-known run (gapRise within 1 dB)",
              std::fabs(r.comp.gapRiseDb - s.comp.gapRiseDb) < 1.0, r.comp.gapRiseDb - s.comp.gapRiseDb);
    }

    // ---- Task 6 fix round 2: RXA post-AGC latency + applied AGC gain ----
    {
        RxaState s;                       // WDSP defaults
        s.mode = kRxaUsb;
        check("rxa_latency: plain USB == 0", rxaPostAgcLatencySamples(s) == 0.0,
              rxaPostAgcLatencySamples(s));
        RxaState e = s;                   // Lyra: EMNR on at position 1 (bp1 follows)
        e.emnrRun = true; e.emnrPosition = 1; e.bp1Position = 1;
        check("rxa_latency: EMNR pos 1 = 3072 + 2047.5", rxaPostAgcLatencySamples(e) == 5119.5,
              rxaPostAgcLatencySamples(e));
        RxaState a = s;                   // ANF (pre-AGC) but bp1 moved after the AGC
        a.anfRun = true; a.bp1Position = 1;
        check("rxa_latency: ANF pos 0 + bp1 pos 1 = 2047.5", rxaPostAgcLatencySamples(a) == 2047.5,
              rxaPostAgcLatencySamples(a));
        RxaState am = s;                  // AM with bp1 still before the AGC
        am.mode = kRxaAm;
        check("rxa_latency: AM, bp1 pos 0 == 0", rxaPostAgcLatencySamples(am) == 0.0,
              rxaPostAgcLatencySamples(am));
        am.bp1Position = 1;
        check("rxa_latency: AM, bp1 pos 1 == 2047.5", rxaPostAgcLatencySamples(am) == 2047.5,
              rxaPostAgcLatencySamples(am));
        RxaState mp = e; mp.bp1MinPhase = true;
        check("rxa_latency: min-phase bp1 -> NaN", std::isnan(rxaPostAgcLatencySamples(mp)), 0);
        RxaState nn = s; nn.nnrRun = true;
        check("rxa_latency: NNR -> NaN", std::isnan(rxaPostAgcLatencySamples(nn)), 0);
        RxaState sp = s; sp.speakRun = true;
        check("rxa_latency: APF bi-quad -> NaN", std::isnan(rxaPostAgcLatencySamples(sp)), 0);
        RxaState rs = s; rs.outRate = 24000;
        check("rxa_latency: output resampler -> NaN", std::isnan(rxaPostAgcLatencySamples(rs)), 0);
        RxaState lp = s; lp.anrRun = true; lp.anrPosition = 1;
        check("rxa_latency: ANR after the AGC -> NaN", std::isnan(rxaPostAgcLatencySamples(lp)), 0);
    }
    {
        RxaState s;
        s.mode = kRxaUsb;
        s.varGain = std::pow(10.0, 35.0 / 200.0);   // Lyra kAgcSlope 35
        s.maxGainDb = 70.0;
        const double T = (1.0 - std::exp(-4.0)) * 0.9999;
        // At min_volts the AGC applies exactly max_gain (weak signal).
        const double minMeter = 20.0 * std::log10(1.0 / (s.varGain * std::pow(10.0, 70.0 / 20.0)));
        check("rxa_gain: at min_volts applied == max_gain",
              std::fabs(rxaAgcAppliedGainDb(minMeter, s) - 70.0) < 1e-9, rxaAgcAppliedGainDb(minMeter, s));
        // At volts == max_input the slope term vanishes: mult = T / 1.
        const double topMeter = 20.0 * std::log10(1.0 / T);
        check("rxa_gain: at max_input applied == 20log10(out_target)",
              std::fabs(rxaAgcAppliedGainDb(topMeter, s) - 20.0 * std::log10(T)) < 1e-9,
              rxaAgcAppliedGainDb(topMeter, s));
        // Meter rises (stronger signal) -> applied gain falls, monotonically.
        bool mono = true;
        for (double m = minMeter; m < topMeter; m += 1.0)
            if (rxaAgcAppliedGainDb(m + 1.0, s) >= rxaAgcAppliedGainDb(m, s)) mono = false;
        check("rxa_gain: applied gain falls as the meter rises", mono, 0);
        // No slope (var_gain 1): the applied gain is exactly -meter.
        RxaState f = s; f.varGain = 1.0;
        const double m0 = -40.0;
        check("rxa_gain: var_gain 1 -> applied = -meter",
              std::fabs(rxaAgcAppliedGainDb(m0, f) + m0) < 1e-9, rxaAgcAppliedGainDb(m0, f));
        RxaState fx = s; fx.agcMode = 0; fx.fixedGainDb = 20.0;
        check("rxa_gain: FIXD -> fixed gain, meter ignored", rxaAgcAppliedGainDb(NAN, fx) == 20.0,
              rxaAgcAppliedGainDb(NAN, fx));
        RxaState fm = s; fm.mode = kRxaFm;
        check("rxa_gain: FM (AGC not run) -> 0 dB", rxaAgcAppliedGainDb(-30.0, fm) == 0.0, 0);
        check("rxa_gain: NaN meter -> NaN", std::isnan(rxaAgcAppliedGainDb(NAN, s)), 0);
    }

    // ---- splatter meter (IQ) ----
    // In-channel tone at 1 kHz, out tone at 7.5 kHz (USB) or the mirror
    // (LSB), `outRelDb` below it; 192 kHz IQ fed in odd-sized chunks.
    const auto splatter = [](bool usb, double outRelDb, int rate, double secs, double noiseSigma = 0.0) {
        SplatterMeter m;
        m.prepare(rate);
        m.setChannel(0.0, usb, 6000.0);
        const double sgn = usb ? 1.0 : -1.0, ao = std::pow(10.0, -outRelDb / 20.0);
        std::mt19937 rng(99u);
        std::normal_distribution<double> gauss(0.0, noiseSigma > 0.0 ? noiseSigma : 1.0);
        const long n = static_cast<long>(secs * rate);
        std::vector<double> x;
        x.reserve(2 * 997);
        for (long i = 0; i < n; i += 997) {
            x.clear();
            for (long k = i; k < std::min(n, i + 997); ++k) {
                const double t = static_cast<double>(k) / rate;
                const double a = 0.5 * std::cos(2 * kPi * sgn * 1000.0 * t)
                               + 0.5 * ao * std::cos(2 * kPi * sgn * 7500.0 * t);
                const double b = 0.5 * std::sin(2 * kPi * sgn * 1000.0 * t)
                               + 0.5 * ao * std::sin(2 * kPi * sgn * 7500.0 * t);
                x.push_back(a + (noiseSigma > 0.0 ? gauss(rng) : 0.0));
                x.push_back(b + (noiseSigma > 0.0 ? gauss(rng) : 0.0));
            }
            m.feed(x.data(), static_cast<int>(x.size() / 2));
        }
        SplatterResult r;
        m.snapshot(r);
        return r;
    };
    {
        const SplatterResult r = splatter(true, 30.0, 192000, 4.0);
        check("splatter_alert_at_30: alert", r.valid && r.alert, r.alert);
        check("splatter_alert_at_30: marginDb = 30 +- 2", std::fabs(r.marginDb - 30.0) <= 2.0,
              r.marginDb);
        const SplatterResult q = splatter(true, 40.0, 192000, 4.0);
        check("splatter_quiet_at_40: no alert", q.valid && !q.alert, q.alert);
        check("splatter_quiet_at_40: marginDb = 40 +- 2", std::fabs(q.marginDb - 40.0) <= 2.0,
              q.marginDb);
        const SplatterResult l = splatter(false, 30.0, 192000, 4.0);
        check("splatter_lsb_side: alert", l.valid && l.alert, l.alert);
        check("splatter_lsb_side: marginDb = 30 +- 2", std::fabs(l.marginDb - 30.0) <= 2.0,
              l.marginDb);
        const SplatterResult e = splatter(true, 30.0, 12000, 4.0);
        check("splatter_invalid_out_of_span: not valid", !e.valid && !e.alert, e.valid);
        // Noise 50 dB below the peak band (192 kHz: sigma ~ 0.051) must not mask the alert.
        const SplatterResult nz = splatter(true, 30.0, 192000, 4.0, 0.051);
        check("splatter_alert_with_noise_50: alert", nz.valid && nz.alert, nz.alert);
        check("splatter_alert_with_noise_50: marginDb = 30 +- 2", std::fabs(nz.marginDb - 30.0) <= 2.0,
              nz.marginDb);
        // Silence and noise-only input are never a splatter alarm.
        SplatterMeter z;
        z.prepare(192000);
        z.setChannel(0.0, true, 6000.0);
        const std::vector<double> zeros(2 * 4096, 0.0);
        SplatterResult zr;
        for (int i = 0; i < 200; ++i) z.feed(zeros.data(), 4096);
        z.snapshot(zr);
        check("splatter_silence: not valid, no alert", !zr.valid && !zr.alert, zr.valid);
        SplatterMeter wn;
        wn.prepare(192000);
        wn.setChannel(0.0, true, 6000.0);
        {
            std::mt19937 rng(5u);
            std::normal_distribution<double> g(0.0, 0.1);
            std::vector<double> x(2 * 4096);
            SplatterResult wr;
            for (int i = 0; i < 200; ++i) {
                for (double &v : x) v = g(rng);
                wn.feed(x.data(), 4096);
            }
            wn.snapshot(wr);
            check("splatter_white_noise: no alert", !wr.alert, wr.alert);
            check("splatter_white_noise: not valid (no signal)", !wr.valid, wr.peakDb - wr.noiseDb);
        }
        // Tone ~20 dB above white noise, nothing outside: out window is just noise.
        {
            SplatterMeter m;
            m.prepare(24000);
            m.setChannel(0.0, true, 6000.0);
            std::mt19937 rng(6u);
            std::normal_distribution<double> g(0.0, 0.35);
            std::vector<double> x(2 * 1000);
            for (long i = 0; i < 24000L * 5; i += 1000) {
                for (int k = 0; k < 1000; ++k) {
                    const double t = static_cast<double>(i + k) / 24000.0;
                    x[2 * k] = 0.4 * std::cos(2 * kPi * 1000.0 * t) + g(rng);
                    x[2 * k + 1] = 0.4 * std::sin(2 * kPi * 1000.0 * t) + g(rng);
                }
                m.feed(x.data(), 1000);
            }
            SplatterResult r;
            m.snapshot(r);
            check("splatter_tone_over_noise: valid", r.valid, r.peakDb - r.noiseDb);
            check("splatter_tone_over_noise: margin < 35 but no alert", r.marginDb < 35.0 && !r.alert,
                  r.marginDb);
        }
        // Retune: loud splattering station -> restart() -> clean station.
        {
            SplatterMeter m;
            m.prepare(192000);
            m.setChannel(0.0, true, 6000.0);
            std::mt19937 rng(8u);
            std::normal_distribution<double> g(0.0, 0.01);
            SplatterResult r;
            const auto run = [&](double secs, double outAmp, double tone) {
                std::vector<double> x(2 * 1000);
                const long n = static_cast<long>(secs * 192000);
                for (long i = 0; i < n; i += 1000) {
                    for (int k = 0; k < 1000; ++k) {
                        const double t = static_cast<double>(i + k) / 192000.0;
                        x[2 * k] = tone * std::cos(2 * kPi * 1000.0 * t)
                                   + outAmp * std::cos(2 * kPi * 7500.0 * t) + g(rng);
                        x[2 * k + 1] = tone * std::sin(2 * kPi * 1000.0 * t)
                                       + outAmp * std::sin(2 * kPi * 7500.0 * t) + g(rng);
                    }
                    m.feed(x.data(), 1000);
                    m.snapshot(r);
                }
            };
            run(4.0, 0.5 * std::pow(10.0, -30.0 / 20.0), 0.5);
            check("retune: station A alerts", r.valid && r.alert, r.alert);
            m.restart();
            bool anyValid = false;
            for (int i = 0; i < 29; ++i) {
                run(0.1, 0.0, 0.5);
                anyValid = anyValid || r.valid;
            }
            check("retune: invalid for the first 2.9 s after restart()", !anyValid && !r.alert, anyValid);
            run(1.5, 0.0, 0.5);
            check("retune: clean station valid after 3 s, no alert", r.valid && !r.alert, r.marginDb);
            // A channel change re-arms on its own.
            m.setChannel(2000.0, true, 6000.0);
            run(0.2, 0.0, 0.5);
            check("channel change re-arms validity", !r.valid, r.valid);
        }
        const SplatterResult s = splatter(true, 30.0, 192000, 2.0);
        check("splatter_invalid_before_3s: not valid", !s.valid, s.valid);
        // Rate change by request: valid result at the new rate, no re-prepare.
        {
            SplatterMeter m;
            m.prepare(192000);
            m.setChannel(0.0, true, 6000.0);
            m.setRate(96000);
            const double ao = std::pow(10.0, -30.0 / 20.0);
            std::vector<double> x;
            const long n = 4L * 96000;
            for (long i = 0; i < n; i += 997) {
                x.clear();
                for (long k = i; k < std::min(n, i + 997); ++k) {
                    const double t = static_cast<double>(k) / 96000;
                    x.push_back(0.5 * std::cos(2 * kPi * 1000.0 * t) + 0.5 * ao * std::cos(2 * kPi * 7500.0 * t));
                    x.push_back(0.5 * std::sin(2 * kPi * 1000.0 * t) + 0.5 * ao * std::sin(2 * kPi * 7500.0 * t));
                }
                m.feed(x.data(), static_cast<int>(x.size() / 2));
            }
            SplatterResult r;
            m.snapshot(r);
            check("splatter_rate_request: valid, margin 30 +- 2 at 96k",
                  r.valid && std::fabs(r.marginDb - 30.0) <= 2.0, r.marginDb);
        }
        const SplatterResult w = splatter(true, 30.0, 96000, 4.0);
        check("splatter_other_rate_96k: marginDb = 30 +- 2", w.valid && std::fabs(w.marginDb - 30.0) <= 2.0,
              w.marginDb);
    }


    // ---- advisor ----------------------------------------------------------
    {
        const Target essb = *find(builtinTargets(), "essb");
        const BandLayout bl = makeBands();

        // Healthy snapshot: curve = target inside the target passband, -40 outside.
        auto snap = [&](double speech, double snr) {
            CoachSnapshot s;
            s.bands = bl;
            s.baselineDb.resize(bl.size());
            for (int k = 0; k < bl.size(); ++k) {
                const double hz = bl.centreHz[k];
                s.baselineDb[k] = (hz >= 50.0 && hz <= 6000.0) ? targetDbAt(essb, hz) : -40.0;
            }
            s.baseline = AvgState::Stopped;
            s.speechSec = speech;
            s.medianSnrDb = snr;
            return s;
        };
        auto addZone = [&](CoachSnapshot &s, double lo, double hi, double db) {
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] >= lo && bl.centreHz[k] < hi) s.baselineDb[k] += db;
        };
        RxConditions rx;
        rx.rxLowHz = 0.0; rx.rxHighHz = 12000.0; rx.mode = "USB";
        const SplatterResult noSp;
        auto count = [](const std::vector<Finding> &v, FindingKind k) {
            int n = 0;
            for (const auto &f : v) if (f.kind == k) ++n;
            return n;
        };
        auto tones = [&](const std::vector<Finding> &v) {
            return count(v, FindingKind::ToneHeavy) + count(v, FindingKind::ToneThin);
        };

        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            check("advisor_flat_none: no findings at all", a.evaluate(s, noSp, rx, essb).empty(),
                  static_cast<double>(a.evaluate(s, noSp, rx, essb).size()));
        }
        {
            // Flat 0 dB except +6 over the bass zone: 6 - target bump (3) is in tolerance.
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] >= 50 && bl.centreHz[k] < 1000) s.baselineDb[k] = 0.0;
            addZone(s, 60, 150, 6.0);
            check("advisor_heavy_80: +6 dB is within tolerance", tones(a.evaluate(s, noSp, rx, essb)) == 0,
                  tones(a.evaluate(s, noSp, rx, essb)));
            CoachAdvisor b;
            CoachSnapshot s9 = snap(20, 25);
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] >= 50 && bl.centreHz[k] < 1000) s9.baselineDb[k] = 0.0;
            addZone(s9, 60, 150, 9.0);
            const auto f = b.evaluate(s9, noSp, rx, essb);
            const bool ok = tones(f) == 1 && f[0].kind == FindingKind::ToneHeavy
                            && f[0].zone == ZoneId::Bass && f[0].db == 6.0
                            && f[0].hz >= 60 && f[0].hz <= 150;
            check("advisor_heavy_80: +9 dB gives one ToneHeavy Bass db=6", ok, f.empty() ? -1 : f[0].db);
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] > 3500) s.baselineDb[k] = (bl.centreHz[k] > 4100) ? -40.0 : 0.0;
            RxConditions nr = rx;
            nr.rxHighHz = 4000.0;
            const auto f = a.evaluate(s, noSp, nr, essb);
            bool topFree = true;
            for (const auto &x : f)
                if (x.kind == FindingKind::ToneHeavy || x.kind == FindingKind::ToneThin) topFree = false;
            check("advisor_narrow_rx_filter: RxFilterTooNarrow first",
                  !f.empty() && f[0].kind == FindingKind::RxFilterTooNarrow, f.empty() ? -1 : f[0].value);
            check("advisor_narrow_rx_filter: no tone findings, no Bandwidth",
                  topFree && count(f, FindingKind::Bandwidth) == 0, f.size());
            check("advisor_narrow_rx_filter: highBeyondRx", a.edges(s, nr).highBeyondRx, a.edges(s, nr).highHz);
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(5, 25);
            addZone(s, 600, 2000, 12.0);
            const auto f = a.evaluate(s, noSp, rx, essb);
            check("advisor_low_confidence: NeedMoreSpeech 5/8, nothing else",
                  f.size() == 1 && f[0].kind == FindingKind::NeedMoreSpeech && f[0].value == 5.0
                      && f[0].value2 == 8.0, f.size());
            CoachSnapshot w = snap(20, 5);
            const auto g = a.evaluate(w, noSp, rx, essb);
            check("advisor_low_snr: SignalTooWeak", g.size() == 1 && g[0].kind == FindingKind::SignalTooWeak,
                  g.size());
            CoachSnapshot nn = snap(NAN, NAN);
            const auto h = a.evaluate(nn, noSp, rx, essb);
            check("advisor_nan_confidence: NeedMoreSpeech", h.size() == 1 && h[0].kind == FindingKind::NeedMoreSpeech,
                  h.size());
            CoachSnapshot ns = snap(20, NAN);
            const auto i = a.evaluate(ns, noSp, rx, essb);
            check("advisor_nan_snr: SignalTooWeak", i.size() == 1 && i[0].kind == FindingKind::SignalTooWeak,
                  i.size());
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            RxConditions m = rx;
            m.mode = "CWU"; m.nrOn = true;
            SplatterResult sp; sp.valid = sp.alert = true; sp.marginDb = 20;
            const auto f = a.evaluate(s, sp, m, essb);
            check("advisor_non_ssb_mode: single NotVoiceMode", f.size() == 1 && f[0].kind == FindingKind::NotVoiceMode,
                  f.size());
        }
        {
            CoachAdvisor a;
            auto at = [&](double off) {
                CoachSnapshot s = snap(20, 25);
                for (int k = 0; k < bl.size(); ++k)
                    if (bl.centreHz[k] >= 150 && bl.centreHz[k] < 600) s.baselineDb[k] += off;
                return tones(a.evaluate(s, noSp, rx, essb));
            };
            const int hi = at(3.5), mid = at(2.5), lo = at(1.5);
            check("advisor_hysteresis: tol+0.5 flags", hi == 1, hi);
            check("advisor_hysteresis: tol-0.5 stays flagged", mid == 1, mid);
            check("advisor_hysteresis: tol-1.5 clears", lo == 0, lo);
            at(3.5);
            a.reset();
            check("advisor_hysteresis: reset clears state", at(2.5) == 0, 0);
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            s.comp.pauses = 4; s.comp.gapRiseDb = 8; s.comp.gapToSpeechDb = 18; s.comp.crestDb = 6;
            const auto f = a.evaluate(s, noSp, rx, essb);
            check("advisor_compression: Pumping, NoiseBetweenWords, Squashed in order",
                  f.size() == 3 && f[0].kind == FindingKind::Pumping
                      && f[1].kind == FindingKind::NoiseBetweenWords && f[2].kind == FindingKind::Squashed,
                  f.size());
            CoachSnapshot nanS = snap(20, 25);   // metrics default NaN: not measured
            check("advisor_compression: NaN never flags", a.evaluate(nanS, noSp, rx, essb).empty(), 0);
            CoachSnapshot rcS = snap(20, 25);
            rcS.recheck = AvgState::Running; rcS.recheckDb = rcS.baselineDb; rcS.recheckSpeechSec = 20;
            rcS.recheckComp.pauses = 2; rcS.recheckComp.crestDb = 5;
            const auto r = a.evaluate(rcS, noSp, rx, essb);
            check("advisor_compression: uses re-check metrics when current",
                  r.size() == 1 && r[0].kind == FindingKind::Squashed, r.size());
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            for (int k = 0; k < bl.size(); ++k) {
                const double hz = bl.centreHz[k];
                if (hz < 110.0 || hz > 4100.0) s.baselineDb[k] = -40.0;
                else if (hz > 3500 || hz < 150) s.baselineDb[k] = targetDbAt(essb, hz);
            }
            const Edges e = a.edges(s, rx);
            const auto f = a.evaluate(s, noSp, rx, essb);
            bool bw = false;
            for (const auto &x : f) bw = bw || x.kind == FindingKind::Bandwidth;
            check("advisor_bandwidth_midfi: tier midfi", e.tier == "midfi", e.lowHz);
            check("advisor_bandwidth_midfi: Bandwidth finding", bw, e.highHz);
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            s.recheck = AvgState::Stopped;
            s.recheckDb = s.baselineDb;
            addZone(s, 600, 2000, 2.0);
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] >= 2000 && bl.centreHz[k] < 3500) s.recheckDb[k] -= 3.0;
            const auto d = a.zoneDelta(s);
            double body = NAN, upper = NAN;
            for (const auto &p : d) {
                if (p.first == ZoneId::Body) body = p.second;
                if (p.first == ZoneId::Upper) upper = p.second;
            }
            check("advisor_zone_delta: recheck - baseline per zone",
                  std::fabs(body + 2.0) < 1e-9 && std::fabs(upper + 3.0) < 1e-9, body);
        }
        {
            // Realistic RX edges (fix round 1).
            auto heavy = [&](double db) {
                CoachSnapshot s = snap(20, 25);
                for (int k = 0; k < bl.size(); ++k)
                    if (bl.centreHz[k] >= 50 && bl.centreHz[k] < 1000) s.baselineDb[k] = 0.0;
                addZone(s, 60, 150, db);
                return s;
            };
            RxConditions r = rx;
            r.rxLowHz = 50.0; r.rxHighHz = 10000.0;
            CoachAdvisor a;
            const auto f = a.evaluate(heavy(9.0), noSp, r, essb);
            check("advisor_rx50_10k: ToneHeavy Bass db=6, no RxFilterTooNarrow",
                  tones(f) == 1 && count(f, FindingKind::RxFilterTooNarrow) == 0
                      && count(f, FindingKind::ToneHeavy) == 1
                      && f.back().zone == ZoneId::Bass && f.back().db == 6.0, f.size());
            // rxLow = 100: low-side RxFilterTooNarrow (Bass) first; bass bands whose
            // lower edge is below 100*2^(1/12) are excluded, the ones above remain
            // (centres ~113-143 Hz), so Bass still produces ToneHeavy db=6.
            RxConditions r100 = r;
            r100.rxLowHz = 100.0;
            CoachAdvisor b;
            const auto g = b.evaluate(heavy(9.0), noSp, r100, essb);
            check("advisor_rx100: RxFilterTooNarrow(Bass) first",
                  !g.empty() && g[0].kind == FindingKind::RxFilterTooNarrow && g[0].zone == ZoneId::Bass
                      && g[0].value == 100.0 && g[0].value2 == 50.0, g.size());
            bool bass6 = false;
            for (const auto &x : g)
                bass6 = bass6 || (x.kind == FindingKind::ToneHeavy && x.zone == ZoneId::Bass && x.db == 6.0
                                  && x.hz > 100.0 * std::exp2(1.0 / 12.0));
            check("advisor_rx100: Bass still flagged from bands above 100*2^(1/12)", bass6, g.size());
            RxConditions rnone = r;
            rnone.rxHighHz = 0.0;
            CoachAdvisor c;
            check("advisor_rx_high_unset: no RxFilterTooNarrow",
                  count(c.evaluate(snap(20, 25), noSp, rnone, essb), FindingKind::RxFilterTooNarrow) == 0, 0);
            // High side: zone Top, value2 = the suggested RX BW (8 kHz for eSSB
            // in USB); low before high.
            RxConditions both = r;
            both.rxLowHz = 100.0; both.rxHighHz = 4000.0;
            const auto h = c.evaluate(snap(20, 25), noSp, both, essb);
            check("advisor_rx_both_narrow: low then high",
                  h.size() >= 2 && h[0].zone == ZoneId::Bass && h[1].kind == FindingKind::RxFilterTooNarrow
                      && h[1].zone == ZoneId::Top && h[1].value2 == 8000.0, h.size());
            // Suggested width: smallest RX BW preset whose high edge clears
            // highEdge * 2^(1/6), in the mode's own preset list.
            check("advisor_rx_need_high: eSSB needs 6000*2^(1/6)",
                  std::fabs(CoachAdvisor::rxHighNeededHz(essb) - 6000.0 * std::exp2(1.0 / 6.0)) < 1e-9,
                  CoachAdvisor::rxHighNeededHz(essb));
            RxConditions wide7 = both;
            wide7.rxHighHz = 7000.0;   // above 6735 Hz: no high-side finding
            int topNarrow = 0;
            for (const auto &x : c.evaluate(snap(20, 25), noSp, wide7, essb))
                if (x.kind == FindingKind::RxFilterTooNarrow && x.zone == ZoneId::Top) ++topNarrow;
            check("advisor_rx_7k_ok_for_essb: no Top RxFilterTooNarrow", topNarrow == 0, topNarrow);
            const Target typical = *find(builtinTargets(), "typical");
            RxConditions t24 = rx;
            t24.rxLowHz = 100.0; t24.rxHighHz = 2400.0;
            const auto ty = c.evaluate(snap(20, 25), noSp, t24, typical);
            double tyW = NAN;
            for (const auto &x : ty)
                if (x.kind == FindingKind::RxFilterTooNarrow && x.zone == ZoneId::Top) tyW = x.value2;
            check("advisor_rx_typical: 2.7 kHz target suggests 3.6 kHz (not 4.7)", tyW == 3600.0, tyW);
            RxConditions am = rx;
            am.mode = "AM"; am.rxLowHz = 0.0; am.rxHighHz = 3000.0;   // AM 6 kHz filter
            const auto af = c.evaluate(snap(20, 25), noSp, am, essb);
            double amV = NAN, amW = NAN;
            for (const auto &x : af)
                if (x.kind == FindingKind::RxFilterTooNarrow && x.zone == ZoneId::Top) {
                    amV = x.value;
                    amW = x.value2;
                }
            check("advisor_rx_am: value is the 6 kHz filter width", amV == 6000.0, amV);
            check("advisor_rx_am: suggests the 16 kHz AM preset", amW == 16000.0, amW);
            check("advisor_rx_past_presets: AM target in USB rounds up to 10.2 kHz",
                  CoachAdvisor::suggestRxWidthHz("USB", CoachAdvisor::rxHighNeededHz(
                                                            *find(builtinTargets(), "am"))) == 10200.0,
                  CoachAdvisor::suggestRxWidthHz("USB", CoachAdvisor::rxHighNeededHz(
                                                            *find(builtinTargets(), "am"))));
            check("advisor_voice_modes", CoachAdvisor::isVoiceMode("usb") && CoachAdvisor::isVoiceMode("SAM")
                                             && !CoachAdvisor::isVoiceMode("CWU")
                                             && !CoachAdvisor::isVoiceMode("DIGU"), 0);
            // lowBeyondRx: curve rolls off below 95 Hz, RX low edge 100 Hz (within one band).
            CoachSnapshot e = snap(20, 25);
            for (int k = 0; k < bl.size(); ++k)
                if (bl.centreHz[k] < 95.0) e.baselineDb[k] = -40.0;
            check("advisor_edges: lowBeyondRx within one band of rxLow", c.edges(e, r100).lowBeyondRx,
                  c.edges(e, r100).lowHz);
            check("advisor_edges: not beyondRx when far", !c.edges(e, r).lowBeyondRx, c.edges(e, r).lowHz);
            // Hysteresis: a skipped zone clears its flag; a sign flip re-qualifies.
            CoachAdvisor d;
            RxConditions wide = r;
            auto lowMid = [&](double off, const RxConditions &rc) {
                CoachSnapshot s = snap(20, 25);
                for (int k = 0; k < bl.size(); ++k)
                    if (bl.centreHz[k] >= 150 && bl.centreHz[k] < 600) s.baselineDb[k] += off;
                return tones(d.evaluate(s, noSp, rc, essb));
            };
            lowMid(3.5, wide);
            RxConditions skip = wide;
            skip.rxLowHz = 700.0;   // LowMid has no usable bands
            lowMid(0.0, skip);
            check("advisor_hysteresis: skipped zone clears flag", lowMid(2.5, wide) == 0, 0);
            lowMid(3.5, wide);
            check("advisor_hysteresis: sign flip within hysteresis band clears", lowMid(-2.5, wide) == 0, 0);
        }
        {
            CoachAdvisor a;
            CoachSnapshot s = snap(20, 25);
            s.baselineDb.clear();
            RxConditions n = rx;
            n.anfOn = true;
            const auto f = a.evaluate(s, noSp, n, essb);
            check("advisor_no_curve: only receive-path finding", f.size() == 1 && f[0].kind == FindingKind::AnfOn,
                  f.size());
            SplatterResult sp; sp.valid = sp.alert = true; sp.marginDb = 20.4; sp.peakDb = -10; sp.outDb = -30.4;
            const auto g = a.evaluate(snap(2, 25), sp, rx, essb);
            check("advisor_splatter: always included on alert, last",
                  g.size() == 2 && g[1].kind == FindingKind::Splatter && g[1].db == 20.0, g.size());
        }
    }

    std::printf("%s (%d failure%s)\n", g_failures ? "FAILED" : "ALL OK",
                g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}

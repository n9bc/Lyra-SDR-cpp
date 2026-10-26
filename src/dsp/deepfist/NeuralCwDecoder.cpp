// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md

#include "dsp/deepfist/NeuralCwDecoder.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <utility>

#include "dsp/deepfist/DeepFistCtc.h"

namespace lyra::dsp {

namespace {
constexpr int    kSr        = 3200;
constexpr int    kWindow    = 6 * kSr;      // 19200 samples (6 s), zero-padded
constexpr double kWindowS   = 6.0;
constexpr int    kTickMs    = 400;          // re-decode ~2.5x/s (tci_decode tick)
constexpr double kGuardBase = 1.3;          // commit delay at normal speeds
constexpr double kGuardSlow = 2.4;          // max guard at very slow speeds (<=15 WPM)
constexpr int    kMinSamp   = kSr;          // need >=1 s buffered before decoding
constexpr float  kKeyingMin = 12.0f;        // min keying ratio (p90/p10) to decode
                                            // (DeepFist squelch.py, validated on Lyra
                                            // captures: dead air ~4, keyed CW 12-600+)
                                            // — gates dead air / steady carriers so we
                                            // don't hallucinate characters on no signal
constexpr double kMatchTolS = 0.2;          // max shift of one char between windows
                                            // (measured <=0.06 s once settled; an "EE"
                                            // pair at 20 WPM is 0.24 s apart)

constexpr double kSpaceSlackS = 0.05;        // envelope delay at a gap's edges

// One decoded character: estimated audio time (s) and token id.
struct TimedChar {
    double t;
    int    id;
};

// Successive windows re-decode the same audio, and a char's estimated time
// moves a little each time.  Committing by time alone (everything older than
// a boundary) therefore emits a char twice when it moves back across the
// boundary, or never when it moves forward across it.  Instead, line the new
// decode up with the chars already committed and return only the new ones.
//
// `committed` — chars already emitted (time-ordered, recent ones only).
// `decoded`   — this window's chars (time-ordered).
// `settleTo`  — only chars at or before this time are eligible.
// `floorT`    — the newest committed char / silence boundary; a char that
//               lines up with nothing is new only if it is after this.
std::vector<TimedChar> newChars(const std::vector<TimedChar>& committed,
                                const std::vector<TimedChar>& decoded,
                                double settleTo, double floorT) {
    // 1. Anchor: match decoded chars to committed ones by identity and time,
    //    in order.  The last match marks where already-committed text ends.
    size_t j = 0;                       // next committed char to consider
    int lastMatch = -1;                 // index in `decoded` of the last match
    for (size_t i = 0; i < decoded.size() && decoded[i].t <= settleTo; ++i) {
        for (size_t m = j; m < committed.size(); ++m) {
            if (committed[m].t > decoded[i].t + kMatchTolS) break;
            if (committed[m].id == decoded[i].id &&
                committed[m].t >= decoded[i].t - kMatchTolS) {
                j = m + 1;
                lastMatch = static_cast<int>(i);
                break;
            }
        }
    }

    // 2. After the anchor: a char that sits where an unconfirmed committed
    //    char sits is the model revising that char (e.g. "B" -> "C") — it
    //    can't be un-emitted, so skip it rather than add a second char.
    //    Anything else after the anchor and after floorT is new.  A decoded
    //    char before the anchor that matched nothing is an insertion into
    //    text already shown; also skipped.
    std::vector<TimedChar> out;
    for (size_t i = static_cast<size_t>(lastMatch + 1);
         i < decoded.size() && decoded[i].t <= settleTo; ++i) {
        bool revised = false;
        for (size_t m = j; m < committed.size(); ++m) {
            if (committed[m].t > decoded[i].t + kMatchTolS) break;
            if (committed[m].t >= decoded[i].t - kMatchTolS) {
                j = m + 1;
                revised = true;
                break;
            }
        }
        if (!revised && decoded[i].t > floorT) {
            out.push_back(decoded[i]);
            floorT = decoded[i].t;
        }
    }
    return out;
}

// A key-down mark or key-up gap in the window, in audio time (s).
struct KeyRun {
    double start;
    double end;
};

// Split a window's keying envelope (one value per sample, window starting at
// audio time t0) into complete key-down marks and key-up gaps: threshold
// halfway between the 10th and 90th percentile levels.  Runs cut off by
// either window edge are left out — their length is unknown.
void keyRuns(const std::vector<float>& env, double t0,
             std::vector<KeyRun>& marks, std::vector<KeyRun>& gaps) {
    marks.clear();
    gaps.clear();
    const size_t n = env.size();
    if (n < 16) return;
    std::vector<float> s(env);
    std::nth_element(s.begin(), s.begin() + n / 10, s.end());
    const float lo = s[n / 10];
    std::nth_element(s.begin(), s.begin() + (n - 1 - n / 10), s.end());
    const float hi = s[n - 1 - n / 10];
    const float thr = 0.5f * (lo + hi);
    bool on = env[0] > thr;
    size_t runStart = 0;
    bool bounded = false;               // first run touches the window edge
    for (size_t k = 1; k < n; ++k) {
        const bool o = env[k] > thr;
        if (o == on) continue;
        if (bounded) {
            const KeyRun r{t0 + static_cast<double>(runStart) / kSr,
                           t0 + static_cast<double>(k) / kSr};
            (on ? marks : gaps).push_back(r);
        }
        bounded = true;
        runStart = k;
        on = o;
    }
}

// This sender's own spacing, learned from the gaps already settled.  DeepFist
// reads a long gap between letters as a word space, so a loose or hand-sent
// fist ("U S E D", "B R A IN") comes out split into letters.  Classing a gap
// as a word space against the sender's own letter gaps, not standard 3/7-dit
// timing, lets the decoder drop those spaces.
class SenderSpacing {
public:
    void clear() { marks_.clear(); gaps_.clear(); lastMarkEnd_ = lastGapEnd_ = -1.0; }

    // Learn from the window's runs that have settled and weren't seen before.
    void learn(const std::vector<KeyRun>& marks, const std::vector<KeyRun>& gaps,
               double settleTo) {
        add(marks, settleTo, lastMarkEnd_, marks_);
        add(gaps, settleTo, lastGapEnd_, gaps_);
    }

    // Shortest gap (s) that counts as a word space; 0 = not enough keying
    // seen yet to judge.
    double wordGapS() const {
        // Marks under 25 ms (faster than ~48 WPM) are envelope blips.
        std::vector<double> m;
        for (double d : marks_) if (d > 0.025) m.push_back(d);
        if (m.size() < 6) return 0.0;
        std::nth_element(m.begin(), m.begin() + m.size() / 4, m.end());
        const double dit = m[m.size() / 4];          // short elements

        // Gaps between letters or words (inside a letter is ~1 dit); longer
        // than 20 dits is a pause between overs, not a word space.
        std::vector<double> g;
        for (double d : gaps_)
            if (d >= 2.0 * dit && d <= 20.0 * dit) g.push_back(std::log(d / dit));
        const double standard = 5.0 * dit;           // halfway between 3 and 7 dits
        if (g.size() < 5) return standard;

        // Split letter gaps from word gaps on log length at the point that
        // best separates the two groups (Otsu), then put the threshold
        // halfway (geometric) between the two group means.
        std::sort(g.begin(), g.end());
        const size_t n = g.size();
        double total = 0;
        for (double x : g) total += x;
        double best = -1, c1 = 0, c2 = 0, left = 0;
        for (size_t k = 1; k < n; ++k) {           // groups g[0..k) | g[k..n)
            left += g[k - 1];
            const double m1 = left / k, m2 = (total - left) / (n - k);
            const double between = double(k) * double(n - k) * (m2 - m1) * (m2 - m1);
            if (between > best) { best = between; c1 = m1; c2 = m2; }
        }
        if (c2 - c1 < std::log(1.5)) return standard;   // no clear word gaps yet
        const double thr = std::exp(0.5 * (c1 + c2)) * dit;
        return std::clamp(thr, 4.5 * dit, 12.0 * dit);
    }

private:
    static void add(const std::vector<KeyRun>& runs, double settleTo, double& lastEnd,
                    std::deque<double>& out) {
        for (const KeyRun& r : runs) {
            if (r.end > settleTo || r.end <= lastEnd) continue;
            out.push_back(r.end - r.start);
            lastEnd = r.end;
            if (out.size() > kKeep) out.pop_front();
        }
    }
    static constexpr size_t kKeep = 60;   // ~15-20 s of keying
    std::deque<double> marks_, gaps_;
    double lastMarkEnd_ = -1.0, lastGapEnd_ = -1.0;
};

// Whether a space the model emitted at time `t` is a real word space: the
// key-up gap it falls in must be at least `wordGapS`.  DeepFist puts its
// space ~0.1 s into the gap; `slack` allows for envelope delay at the edges.
// No gap found, or no judgement yet (wordGapS 0) -> trust the model.
bool isWordSpace(double t, const std::vector<KeyRun>& gaps, double wordGapS,
                 double slack) {
    if (wordGapS <= 0.0) return true;
    for (const KeyRun& g : gaps)
        if (t >= g.start - slack && t <= g.end + slack)
            return g.end - g.start >= wordGapS;
    return true;
}
}  // namespace

NeuralCwDecoder::NeuralCwDecoder() {
    ring_.assign(kWindow, 0.0f);
    // Initial blank penalty from LYRA_CW_BLANKPEN (default 0); the panel can
    // override it live via setBlankPenalty().
    if (const char* e = std::getenv("LYRA_CW_BLANKPEN"))
        blankPen_.store(std::strtof(e, nullptr), std::memory_order_relaxed);
}

NeuralCwDecoder::~NeuralCwDecoder() {
    stopWorker();
}

bool NeuralCwDecoder::loadModel(const std::string& modelDir,
                                const std::vector<std::string>& extraScpCalls,
                                const NeuralModelProfile& profile) {
    const bool ok = model_.load(modelDir, profile);
    if (ok) {
        // Optional callsign DB for the lattice rescorer; a no-op if absent.
        scp_.loadFile(modelDir + "/MASTER.SCP");
        scp_.addCalls(extraScpCalls);      // Phase 3: locally-confirmed calls
        startWorker();
    }
    return ok;
}

void NeuralCwDecoder::setSampleRate(double hz) {
    decim_.setInRate(hz);
    reset();
}

void NeuralCwDecoder::reset() {
    std::lock_guard<std::mutex> lk(mx_);
    decim_.reset();
    std::fill(ring_.begin(), ring_.end(), 0.0f);
    total3200_  = 0;
    committedT_ = 0.0;
    ++gen_;                     // discard any in-flight worker result
}

void NeuralCwDecoder::process(const float* mono, int nframes) {
    if (!model_.ready() || !mono || nframes <= 0) return;

    tmp_.clear();
    decim_.process(mono, nframes, tmp_);        // -> 3200 Hz
    if (tmp_.empty()) return;

    std::lock_guard<std::mutex> lk(mx_);
    const size_t p = tmp_.size();
    if (p >= ring_.size()) {
        std::copy(tmp_.end() - ring_.size(), tmp_.end(), ring_.begin());
    } else {
        std::move(ring_.begin() + p, ring_.end(), ring_.begin());
        std::copy(tmp_.begin(), tmp_.end(), ring_.end() - p);
    }
    total3200_ += static_cast<long long>(p);
    // The worker polls on its own tick; no need to wake it per audio block.
}

void NeuralCwDecoder::startWorker() {
    if (running_.exchange(true)) return;        // already running
    worker_ = std::thread([this] { workerLoop(); });
}

void NeuralCwDecoder::stopWorker() {
    if (!running_.exchange(false)) return;
    cv_.notify_all();
    if (worker_.joinable()) worker_.join();
}

void NeuralCwDecoder::workerLoop() {
    std::vector<float> window(kWindow);
    std::vector<float> logits;
    long long lastTotal = -1;           // skip decoding when no new audio arrived
    // Recently committed chars, for lining up the next window (see newChars),
    // and every char the last gated-in decode saw (flushed when the gate
    // closes — see below).  Both belong to reset generation `histGen`.
    std::vector<TimedChar> committed;
    std::vector<TimedChar> lastDecode;
    unsigned histGen = 0;

    // Append `fresh` to the transcript text and the committed history, and
    // raise committedT_ to the newest.  Caller holds mx_.
    // Word-space filter (see SenderSpacing), for models whose profile asks
    // for it; LYRA_CW_SPACEFILTER=0 turns it off.
    const bool spaceFilter = [this] {
        const char* e = std::getenv("LYRA_CW_SPACEFILTER");
        return model_.profile().wordSpaceFilter && !(e && e[0] == '0');
    }();
    SenderSpacing spacing;
    std::vector<KeyRun> marks, gaps;    // this tick's window
    double wordGapS = 0.0;

    // Append `fresh` to the transcript text and the committed history, and
    // raise committedT_ to the newest.  A space that falls in a letter-length
    // gap stays in the history (so the next window still lines up) but is
    // left out of the text.  Caller holds mx_.
    auto commit = [&](const std::vector<TimedChar>& fresh, std::string& text) {
        const auto& toks = model_.tokens();
        for (const TimedChar& c : fresh) {
            const std::string& tok = toks[static_cast<size_t>(c.id)];
            committed.push_back(c);
            committedT_ = std::max(committedT_, c.t);
            if (spaceFilter && tok == " " &&
                !isWordSpace(c.t, gaps, wordGapS, kSpaceSlackS))
                continue;
            text += tok;
        }
    };

    while (running_.load()) {
        double audioEnd = 0.0;
        unsigned gen = 0;
        {
            std::unique_lock<std::mutex> lk(mx_);
            cv_.wait_for(lk, std::chrono::milliseconds(kTickMs),
                         [this] { return !running_.load(); });
            if (!running_.load()) break;
            // Idle unless we have >=1 s buffered AND new audio since last decode
            // (when Neural isn't the active engine, no audio is fed -> no work).
            if (total3200_ < kMinSamp || total3200_ == lastTotal) continue;
            lastTotal = total3200_;
            std::copy(ring_.begin(), ring_.end(), window.begin());
            audioEnd = static_cast<double>(total3200_) / kSr;
            gen      = gen_;
        }
        if (gen != histGen) {           // reset() since the last tick
            committed.clear();
            lastDecode.clear();
            spacing.clear();
            histGen = gen;
        }

        const double winStart = audioEnd - kWindowS;
        // Chars older than the window can't be re-decoded; forget them.
        committed.erase(committed.begin(),
                        std::find_if(committed.begin(), committed.end(),
                                     [&](const TimedChar& c) {
                                         return c.t >= winStart - kMatchTolS;
                                     }));

        // Keying gate: only decode when the window actually contains keyed CW.
        // A steady carrier / birdie / the CW-AGC artifact tone clears any level
        // test but has a flat envelope, so the model would hallucinate on it.
        // No keying -> run no inference, just advance the commit boundary so
        // silence doesn't back up.  (Mirrors diddle's presence gate; DeepFist
        // HANDOFF §18.23 "no signal energy -> no characters".)
        //
        // The gate closes ~1.4 s after the last keyed element, which can be
        // before that element's char has aged past the guard — DeepCW places its
        // CTC spikes ~0.35 s later than DeepFist and lost the final char of a
        // transmission that way.  So first commit what the last KEYED window
        // already decoded but hadn't settled: it passed the gate, so this is
        // not the dead-air hallucination the gate exists to stop.
        const float keyRatio = model_.keyingRatio(window.data(), kWindow);
        if (onKeying) onKeying(keyRatio);
        if (spaceFilter) {
            keyRuns(model_.keyingEnvelope(window.data(), kWindow), winStart, marks, gaps);
            spacing.learn(marks, gaps, audioEnd - kGuardBase);
            wordGapS = spacing.wordGapS();
        }
        if (keyRatio < kKeyingMin) {
            std::string flush;
            {
                std::lock_guard<std::mutex> lk(mx_);
                if (gen != gen_) continue;
                commit(newChars(committed, lastDecode, audioEnd, committedT_), flush);
                committedT_ = std::max(committedT_, audioEnd - kGuardBase);
            }
            lastDecode.clear();
            if (!flush.empty() && onText) onText(flush);
            // Emit ONE space at the start of a pause so text across the gap
            // doesn't run together (mirrors tci_decode's idle-gap space).
            if (!idleGap_) { idleGap_ = true; if (onText) onText(" "); }
            continue;
        }
        idleGap_ = false;   // keyed signal present again

        // Estimated RX speed (WPM) from the keying envelope; emit on change.
        const int wpm = model_.keyingWpm(window.data(), kWindow);
        if (onWpm) {
            const int d = wpm > lastWpm_ ? wpm - lastWpm_ : lastWpm_ - wpm;
            if (wpm > 0 && d >= 2) { lastWpm_ = wpm; onWpm(wpm); }
        }

        // Speed-adaptive guard: wider at slow speeds so the last element settles
        const double guardS = (wpm >= 20) ? kGuardBase
                            : (wpm > 0)   ? std::min(kGuardSlow, kGuardBase * 20.0 / wpm)
                            :               kGuardBase;
        const double settleTo = audioEnd - guardS;

        int T = 0, C = 0;
        if (!model_.infer(window.data(), kWindow, logits, T, C)) continue;
        const CtcFrames fr = greedyCtcFrames(logits.data(), T, C,
                                             blankPen_.load(std::memory_order_relaxed));

        // CTC-lattice callsign rescoring for this window (worker thread, no lock).
        std::vector<CallRescore> calls;
        if (scp_.ready() && onCalls)
            calls = rescoreCalls(logits.data(), T, C, fr.ids, model_.tokens(), scp_);
        const int    denom    = std::max(1, fr.T);
        const int    nTok     = static_cast<int>(model_.tokens().size());

        lastDecode.clear();
        for (size_t i = 0; i < fr.ids.size(); ++i) {
            const int id = fr.ids[i];
            if (id <= 0 || id >= nTok) continue;
            lastDecode.push_back(
                {winStart + (static_cast<double>(fr.frames[i]) / denom) * kWindowS, id});
        }

        // Commit this window's settled chars that aren't already committed.
        // committedT_ is NOT advanced to settleTo here: a char just short of
        // settleTo may show up a little earlier next window and must still
        // count as new.
        std::string emit;
        {
            std::lock_guard<std::mutex> lk(mx_);
            if (gen != gen_) continue;          // reset() happened mid-decode
            commit(newChars(committed, lastDecode, settleTo, committedT_), emit);
        }
        if (!emit.empty() && onText) onText(emit);

        if (onCalls && !calls.empty()) {
            std::vector<CallRescore> confident;
            for (const CallRescore& c : calls)
                if (c.confident) confident.push_back(c);
            if (!confident.empty()) onCalls(confident);
        }
    }
}

}  // namespace lyra::dsp

// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md

#include "dsp/deepfist/NeuralCwDecoder.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
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
    auto commit = [&](const std::vector<TimedChar>& fresh, std::string& text) {
        const auto& toks = model_.tokens();
        for (const TimedChar& c : fresh) {
            text += toks[static_cast<size_t>(c.id)];
            committed.push_back(c);
            committedT_ = std::max(committedT_, c.t);
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

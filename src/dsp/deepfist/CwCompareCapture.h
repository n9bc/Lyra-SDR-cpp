// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md
//
// Compare-mode training capture: records 3200 Hz audio alongside the text from
// all three CW decoders (Classic, DeepFist, DeepCW) so the corpus can be used
// to retrain DeepFist on real signals with DeepCW as teacher labels.
//
// Capture is opt-in: set LYRA_CW_COMPARE_CAPTURE=<dir> to enable.  Segments
// are emitted every ~30 s of keyed audio, or when a silence gap is detected.
// Each segment is a WAV + JSON sidecar written to <dir>/.
//
// Threading: feedAudio() is called from the audio thread, feedText() from
// decoder worker threads.  pump() runs on the engine's worker (~1 Hz).
#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

namespace lyra::dsp {

class CwCompareCapture {
public:
    explicit CwCompareCapture(const std::string& outDir, int sampleRate = 3200);

    // Audio-thread feed: decimated 3200 Hz mono.
    void feedAudio(const float* samples, int n);

    // Decoder text feeds (any thread).  source: 0=Classic, 1=DeepFist, 3=DeepCW.
    void feedText(int source, const std::string& text);

    // Keying ratio from DeepFist (gates capture — only record keyed audio).
    void feedKeying(float ratio);

    int segmentsWritten() const { return written_.load(std::memory_order_relaxed); }

private:
    void pumpLocked();   // called from feedAudio with mx_ held
    void flushSegment();

    const std::string dir_;
    const int         sr_;

    mutable std::mutex mx_;
    std::vector<float> ring_;
    size_t             head_   = 0;
    long long          total_  = 0;

    std::string        text_[3];       // [0]=Classic, [1]=DeepFist, [2]=DeepCW
    float              lastRatio_ = 0;
    bool               keyed_     = false;
    long long          keyedStart_ = 0; // total_ when keying started
    long long          lastFlush_  = 0; // total_ at last segment flush

    static constexpr int    kRingSeconds = 60;
    static constexpr int    kSegSeconds  = 30;
    static constexpr float  kKeyingMin   = 12.0f;

    long long          lastPump_   = 0; // total_ at last self-pump
    std::atomic<int>   written_{0};
    int                seq_ = 0;
};

}  // namespace lyra::dsp

// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md
//
// Lyra — DeepFist neural CW decoder: front-end conditioner.
//
// Faithful C++ mirror of the verified live Rust conditioner
// (diddle cw_neural.rs::Conditioner).  The exp14+ DeepFist models are trained
// on CONDITIONED single-signal audio, so inference must condition too
// (train == inference).  Runs on the 3200 Hz window BEFORE the spectrogram:
//
//   1. AGC          — normalise to unit RMS (kills live-audio level swings)
//   2. tone AFC     — find the dominant CW tone in 400-1200 Hz (4096-pt FFT)
//   3. downconvert  — shift the tone to baseband, two cascaded 1-pole LPFs
//                     (a ~90 Hz matched-ish bandpass around the tone)
//   4. recenter     — shift back up to a fixed 600 Hz pitch
//   5. peak-norm    — scale to peak 1
//
// This isolates ONE signal (rejecting QRM upstream) and hands the model the
// fixed-pitch, level-normalised input it was trained on.  Uses incremental
// phasor rotation (not per-sample trig) to match the Rust numerics.
#pragma once

#include <complex>
#include <vector>

namespace lyra::dsp {

class DeepFistConditioner {
public:
    static constexpr int    kSr        = 3200;
    static constexpr int    kToneNfft  = 4096;
    static constexpr float  kOutPitch  = 600.0f;
    static constexpr float  kCondBwHz  = 90.0f;
    static constexpr float  kBandLoHz  = 400.0f;
    static constexpr float  kBandHiHz  = 1200.0f;

    // Where to look for the tone.  Default (centerHz <= 0) = the trained
    // behaviour: strongest tone anywhere in 400-1200 Hz, last 4096 samples.
    // centerHz > 0 pins the search to centerHz +/- halfSpanHz (the operator's
    // CW pitch), so a louder neighbour outside that window is never locked.
    // wholeWindow averages the spectrum over the full window instead of only
    // the newest 4096 samples, so a pause in the last 1.28 s can't move the
    // lock off the station being decoded.
    struct ToneSearch {
        float centerHz    = 0.0f;
        float halfSpanHz  = 0.0f;
        bool  wholeWindow = false;
    };

    DeepFistConditioner();

    // Dominant CW tone (Hz) in 400-1200 Hz, from the last 4096 samples.
    // Hann-windowed, smoothed across calls via an EMA (alpha ~0.3); the
    // ToneSearch overload narrows where it looks (see ToneSearch).
    float detectTone(const float* audio, int n);
    float detectTone(const float* audio, int n, const ToneSearch& s);

    // Impulse noise blanker, run on the 3200 Hz window BEFORE condition() —
    // port of DeepFist tools/despike.py.  A sample whose |x| exceeds k x the
    // median |x| of the surrounding 8 ms is a crash / key click (brief,
    // broadband), not tone (sustained: during key-down the local median is
    // already the tone level), so it and 0.5 ms either side are zeroed.
    // Neutral on clean audio.  Returns audio of the same length and scale.
    std::vector<float> despike(const float* audio, int n) const;

    // Isolate + normalise one CW signal (auto tone lock).  Returns audio of the
    // same length at kSr, peak ~1.  For n < 4096 returns the input unchanged.
    std::vector<float> condition(const float* audio, int n);
    std::vector<float> conditionAt(const float* audio, int n, float toneHz) const;

    // Keying-activity metric = p90/p10 of the isolated tone's envelope (the
    // Lyra-validated DeepFist squelch, tools/squelch.py keying_ratio, computed
    // here from the single locked tone rather than a full STFT).  Real keyed CW
    // swings key-down↔gaps → ratio tens-hundreds; a steady carrier / birdie /
    // CW-AGC artifact tone has a flat envelope → ratio ~4-5.  Scale-free (no
    // AGC).  Gates the decoder off dead air.  Returns 0 for n < 4096.
    float keyingRatio(const float* audio, int n, float toneHz) const;

    // Estimate CW speed (WPM) from the keying envelope of the tone: threshold
    // the baseband envelope (hysteresis about the key-up/key-down midpoint),
    // measure the complete "on" elements, split them into dits and dahs and
    // WPM = 1200 / dot_ms (PARIS).  Returns 0 when there isn't enough keying
    // to judge.  Approximate — for the panel readout and the settle guard.
    float estimateWpm(const float* audio, int n, float toneHz) const;

    // The isolated tone's baseband envelope, one value per input sample (same
    // DSP as keyingRatio).  Lets the streamer measure the actual key-up gaps.
    std::vector<float> keyingEnvelope(const float* audio, int n, float toneHz) const;

    // The tone the last detectTone() locked to (kOutPitch before the first).
    float lockedTone() const { return toneEma_ > 0.0f ? toneEma_ : kOutPitch; }

private:
    void fft(std::vector<std::complex<double>>& a) const;   // radix-2, size kToneNfft

    std::vector<int>                  rev_;      // bit-reversal permutation (4096)
    std::vector<std::complex<double>> tw_;       // twiddles (2048)
    std::vector<double>               toneHann_; // Hann window for tone FFT (4096)
    float                             toneEma_ = 0.0f; // smoothed tone (Hz), 0 = unset
};

}  // namespace lyra::dsp

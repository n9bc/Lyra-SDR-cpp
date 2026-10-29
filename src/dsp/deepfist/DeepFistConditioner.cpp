// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md

#include "dsp/deepfist/DeepFistConditioner.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace lyra::dsp {

namespace {
constexpr double kPi = 3.14159265358979323846;
}  // namespace

DeepFistConditioner::DeepFistConditioner() {
    // bit-reversal permutation for N = 4096 (12 bits)
    rev_.resize(kToneNfft);
    for (int i = 0; i < kToneNfft; ++i) {
        int r = 0, x = i;
        for (int b = 0; b < 12; ++b) { r = (r << 1) | (x & 1); x >>= 1; }
        rev_[i] = r;
    }
    tw_.resize(kToneNfft / 2);
    for (int k = 0; k < kToneNfft / 2; ++k)
        tw_[k] = std::complex<double>(std::cos(-2.0 * kPi * k / kToneNfft),
                                      std::sin(-2.0 * kPi * k / kToneNfft));
    // Hann window for tone-detection FFT (reduces sidelobe leakage vs rectangular)
    toneHann_.resize(kToneNfft);
    for (int i = 0; i < kToneNfft; ++i)
        toneHann_[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / kToneNfft);
}

void DeepFistConditioner::fft(std::vector<std::complex<double>>& a) const {
    for (int i = 0; i < kToneNfft; ++i) {
        int j = rev_[i];
        if (j > i) std::swap(a[i], a[j]);
    }
    for (int len = 2; len <= kToneNfft; len <<= 1) {
        const int half = len >> 1;
        const int step = kToneNfft / len;
        for (int base = 0; base < kToneNfft; base += len) {
            for (int k = 0; k < half; ++k) {
                std::complex<double> w = tw_[k * step];
                std::complex<double> u = a[base + k];
                std::complex<double> v = a[base + k + half] * w;
                a[base + k]        = u + v;
                a[base + k + half] = u - v;
            }
        }
    }
}

float DeepFistConditioner::detectTone(const float* audio, int n) {
    if (!audio || n < 8) return toneEma_ > 0 ? toneEma_ : kOutPitch;
    const int m   = std::min(kToneNfft, n);
    const int off = n - m;

    std::vector<std::complex<double>> buf(kToneNfft, {0.0, 0.0});
    for (int i = 0; i < m; ++i)
        buf[i] = std::complex<double>(audio[off + i] * toneHann_[i], 0.0);
    fft(buf);

    const double binHz = static_cast<double>(kSr) / kToneNfft;
    int lo = std::max(1, static_cast<int>(std::floor(kBandLoHz / binHz)));
    int hi = std::min(kToneNfft / 2, static_cast<int>(std::ceil(kBandHiHz / binHz)));
    int    best = lo;
    double bv   = -1.0;
    for (int b = lo; b < hi; ++b) {
        const double mag = std::abs(buf[b]);
        if (mag > bv) { bv = mag; best = b; }
    }
    const float raw = static_cast<float>(best * binHz);

    constexpr float kToneAlpha = 0.3f;
    if (toneEma_ <= 0.0f)
        toneEma_ = raw;
    else
        toneEma_ += kToneAlpha * (raw - toneEma_);
    return toneEma_;
}

std::vector<float> DeepFistConditioner::condition(const float* audio, int n) {
    return conditionAt(audio, n, detectTone(audio, n));
}

std::vector<float> DeepFistConditioner::conditionAt(const float* audio, int n,
                                                    float tone) const {
    if (!audio || n <= 0) return {};
    std::vector<float> out(static_cast<size_t>(n));
    if (n < kToneNfft) {                          // too short — pass through
        for (int k = 0; k < n; ++k) out[k] = audio[k];
        return out;
    }

    const float sr = static_cast<float>(kSr);
    const float pi = static_cast<float>(kPi);

    // 1. AGC — unit RMS
    float ss = 0.0f;
    for (int k = 0; k < n; ++k) ss += audio[k] * audio[k];
    const float rms = std::sqrt(ss / n) + 1e-9f;

    // 2/3. downconvert to baseband + two cascaded 1-pole LPFs (incremental phasors)
    const float alpha = 1.0f - std::exp(-2.0f * pi * (kCondBwHz * 0.5f) / sr);
    const float ds = std::sin(-2.0f * pi * tone / sr);
    const float dc = std::cos(-2.0f * pi * tone / sr);
    const float us = std::sin(2.0f * pi * kOutPitch / sr);
    const float uc = std::cos(2.0f * pi * kOutPitch / sr);
    float pr = 1.0f, pj = 0.0f;                   // downconvert phasor
    float ur = 1.0f, uj = 0.0f;                   // upconvert phasor
    float bI = 0.0f, bQ = 0.0f, cI = 0.0f, cQ = 0.0f;

    for (int k = 0; k < n; ++k) {
        const float s  = audio[k] / rms;
        const float di = s * pr, dq = s * pj;     // baseband I/Q
        bI += alpha * (di - bI);
        bQ += alpha * (dq - bQ);
        cI += alpha * (bI - cI);
        cQ += alpha * (bQ - cQ);
        out[k] = cI * ur - cQ * uj;                // recenter at kOutPitch, real part
        const float npr = pr * dc - pj * ds, npj = pr * ds + pj * dc;
        pr = npr; pj = npj;
        const float nur = ur * uc - uj * us, nuj = ur * us + uj * uc;
        ur = nur; uj = nuj;
    }

    // 5. peak-normalise (peak = max|out| + 1e-9, matching the Rust reference)
    float maxAbs = 0.0f;
    for (float v : out) maxAbs = std::max(maxAbs, std::fabs(v));
    const float peak = maxAbs + 1e-9f;
    for (float& v : out) v /= peak;
    return out;
}

float DeepFistConditioner::keyingRatio(const float* audio, int n, float tone) const {
    if (!audio || n < kToneNfft) return 0.0f;
    const float sr = static_cast<float>(kSr);
    const float pi = static_cast<float>(kPi);
    // Downconvert `tone` to baseband + two cascaded 1-pole LPFs (same DSP as
    // conditionAt, but keep the baseband magnitude — the keying envelope — and
    // no AGC, since the ratio below is scale-free).
    const float alpha = 1.0f - std::exp(-2.0f * pi * (kCondBwHz * 0.5f) / sr);
    const float ds = std::sin(-2.0f * pi * tone / sr);
    const float dc = std::cos(-2.0f * pi * tone / sr);
    float pr = 1.0f, pj = 0.0f;
    float bI = 0.0f, bQ = 0.0f, cI = 0.0f, cQ = 0.0f;

    std::vector<float> env(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        const float s = audio[k];
        const float di = s * pr, dq = s * pj;
        bI += alpha * (di - bI);
        bQ += alpha * (dq - bQ);
        cI += alpha * (bI - cI);
        cQ += alpha * (bQ - cQ);
        env[static_cast<size_t>(k)] = std::sqrt(cI * cI + cQ * cQ);
        const float npr = pr * dc - pj * ds, npj = pr * ds + pj * dc;
        pr = npr; pj = npj;
    }
    // Robust on/off levels: 90th / 10th percentiles so clicks/dropouts don't
    // skew.  ratio = p90/p10 (matches tools/squelch.py keying_ratio).
    std::sort(env.begin(), env.end());
    const float off = env[static_cast<size_t>(n / 10)];          // ~key-up gaps
    const float on  = env[static_cast<size_t>(n - 1 - n / 10)];  // ~key-down
    return on / (off + 1e-3f);
}

std::vector<float> DeepFistConditioner::keyingEnvelope(const float* audio, int n,
                                                      float tone) const {
    std::vector<float> env;
    if (!audio || n <= 0) return env;
    const float sr = static_cast<float>(kSr);
    const float pi = static_cast<float>(kPi);
    const float alpha = 1.0f - std::exp(-2.0f * pi * (kCondBwHz * 0.5f) / sr);
    const float ds = std::sin(-2.0f * pi * tone / sr);
    const float dc = std::cos(-2.0f * pi * tone / sr);
    float pr = 1.0f, pj = 0.0f, bI = 0.0f, bQ = 0.0f, cI = 0.0f, cQ = 0.0f;
    env.resize(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        const float s = audio[k];
        const float di = s * pr, dq = s * pj;
        bI += alpha * (di - bI); bQ += alpha * (dq - bQ);
        cI += alpha * (bI - cI); cQ += alpha * (bQ - cQ);
        env[static_cast<size_t>(k)] = std::sqrt(cI * cI + cQ * cQ);
        const float npr = pr * dc - pj * ds, npj = pr * ds + pj * dc;
        pr = npr; pj = npj;
    }
    return env;
}

float DeepFistConditioner::estimateWpm(const float* audio, int n, float tone) const {
    if (!audio || n < kToneNfft) return 0.0f;
    const float sr = static_cast<float>(kSr);
    const std::vector<float> env = keyingEnvelope(audio, n, tone);

    // On/off threshold halfway between the key-up and key-down levels (10th /
    // 90th percentiles, as keyingRatio), with hysteresis so noise riding on
    // the envelope can't chatter one element into several.  A half-peak
    // threshold let a single noise spike or a fading peak lift the bar until
    // real elements broke into slivers — the readout then pinned at 60 WPM.
    std::vector<float> s(env);
    std::nth_element(s.begin(), s.begin() + n / 10, s.end());
    const float lo = s[static_cast<size_t>(n / 10)];
    std::nth_element(s.begin(), s.begin() + (n - 1 - n / 10), s.end());
    const float hi = s[static_cast<size_t>(n - 1 - n / 10)];
    if (hi <= lo) return 0.0f;
    const float mid = 0.5f * (lo + hi), hyst = 0.15f * (hi - lo);

    // Alternating run lengths (samples); runs[0] is a mark when startOn.
    std::vector<int> runs;
    bool on = env[0] > mid;
    const bool startOn = on;
    int run = 0;
    for (int k = 0; k < n; ++k) {
        const float e = env[static_cast<size_t>(k)];
        const bool o = on ? (e > mid - hyst) : (e > mid + hyst);
        if (o != on) { runs.push_back(run); run = 0; on = o; }
        ++run;
    }
    runs.push_back(run);

    // Bridge dropouts inside an element (gaps under 10 ms), then keep the
    // complete marks (not touching either window edge) of 15 ms or more —
    // shorter is a blip (a 60 WPM dit is 20 ms) — each with the gap after it
    // (0 when that gap runs into the window end).
    const int bridge = static_cast<int>(0.010f * sr), blip = static_cast<int>(0.015f * sr);
    struct Elem { int mark, gap; };
    std::vector<Elem> elems;
    int cur = 0;
    bool curEdge = startOn;            // the first mark touches the window start
    for (size_t i = 0; i < runs.size(); ++i) {
        const bool isMark = (i % 2 == 0) == startOn;
        if (isMark) { cur += runs[i]; continue; }
        const bool edgeGap = (i == 0) || (i + 1 == runs.size());
        if (!edgeGap && runs[i] < bridge && cur > 0) { cur += runs[i]; continue; }
        if (cur > 0 && !curEdge && cur >= blip) elems.push_back({cur, edgeGap ? 0 : runs[i]});
        cur = 0;
        curEdge = false;
    }
    // A mark still open here touches the window end — length unknown, skip.
    if (elems.size() < 6) return 0.0f;

    // Dits vs dahs: split log mark lengths at the point that best separates
    // two groups (Otsu).  A clear split (dahs ~3x dits) gives the dit from
    // both groups (dah/3 counts too); no clear split = one element type, read
    // as dits (EEE, 5NN — far commoner than all-dah runs).
    std::vector<double> lg;
    for (const Elem& e : elems) lg.push_back(std::log(static_cast<double>(e.mark)));
    std::sort(lg.begin(), lg.end());
    const size_t cnt = lg.size();
    double total = 0.0;
    for (double x : lg) total += x;
    double best = -1.0, left = 0.0;
    size_t split = 1;
    for (size_t k = 1; k < cnt; ++k) {
        left += lg[k - 1];
        const double m1 = left / k, m2 = (total - left) / (cnt - k);
        const double between = double(k) * double(cnt - k) * (m2 - m1) * (m2 - m1);
        if (between > best) { best = between; split = k; }
    }
    const double g1 = std::exp(std::accumulate(lg.begin(), lg.begin() + split, 0.0) / split);
    const double g2 = std::exp(std::accumulate(lg.begin() + split, lg.end(), 0.0) / (cnt - split));
    double dit = (g2 / g1 >= 2.0 && g2 / g1 <= 4.5)
        ? (g1 * split + (g2 / 3.0) * (cnt - split)) / cnt
        : std::exp(lg[cnt / 2]);

    // Refine on mark + in-letter gap: a fade or a weak signal shortens the
    // marks above threshold and lengthens the gaps by the same amount, but
    // their sum stays 2 dits (dit) or 4 (dah).
    std::vector<double> fromPeriod;
    for (const Elem& e : elems) {
        if (e.gap <= 0 || e.gap > 2.0 * dit) continue;      // letter/word gap
        const double p = e.mark + e.gap;
        const double units = (p < 3.0 * dit) ? 2.0 : 4.0;
        if (p > 1.4 * dit && p < 5.5 * dit) fromPeriod.push_back(p / units);
    }
    if (fromPeriod.size() >= 4) {
        std::nth_element(fromPeriod.begin(), fromPeriod.begin() + fromPeriod.size() / 2,
                         fromPeriod.end());
        dit = fromPeriod[fromPeriod.size() / 2];
    }
    const float dotMs = static_cast<float>(dit) * 1000.0f / sr;
    const float wpm = 1200.0f / dotMs;                // PARIS: dot(ms) = 1200/wpm
    return std::clamp(wpm, 5.0f, 60.0f);
}

}  // namespace lyra::dsp

// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md

#include "dsp/deepfist/CwCompareCapture.h"
#include "dsp/deepfist/CwHarvestIo.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

namespace lyra::dsp {

CwCompareCapture::CwCompareCapture(const std::string& outDir, int sampleRate)
    : dir_(outDir), sr_(sampleRate),
      ring_(static_cast<size_t>(sampleRate) * kRingSeconds, 0.0f) {}

void CwCompareCapture::feedAudio(const float* samples, int n) {
    if (!samples || n <= 0) return;
    std::lock_guard<std::mutex> lk(mx_);
    const size_t cap = ring_.size();
    for (int i = std::max(0, n - static_cast<int>(cap)); i < n; ++i) {
        ring_[head_] = samples[i];
        head_ = (head_ + 1) % cap;
    }
    total_ += n;
    // Self-pump every ~1 s worth of audio
    if (total_ - lastPump_ >= sr_) {
        lastPump_ = total_;
        pumpLocked();
    }
}

void CwCompareCapture::feedText(int source, const std::string& text) {
    int idx = -1;
    if (source == 0) idx = 0;       // Classic
    else if (source == 1) idx = 1;  // DeepFist
    else if (source == 3) idx = 2;  // DeepCW
    if (idx < 0) return;
    std::lock_guard<std::mutex> lk(mx_);
    text_[idx] += text;
}

void CwCompareCapture::feedKeying(float ratio) {
    std::lock_guard<std::mutex> lk(mx_);
    lastRatio_ = ratio;
    const bool wasKeyed = keyed_;
    keyed_ = (ratio >= kKeyingMin);
    if (keyed_ && !wasKeyed) {
        keyedStart_ = total_;
    }
}

void CwCompareCapture::pumpLocked() {
    if (!keyed_) {
        // Silence gap: flush if we have accumulated keyed audio with text
        bool anyText = false;
        for (int i = 0; i < 3; ++i) if (!text_[i].empty()) { anyText = true; break; }
        if (total_ > lastFlush_ && anyText) {
            flushSegment();
        }
        return;
    }

    // Flush every kSegSeconds of keyed audio
    const long long keyedSamples = total_ - std::max(keyedStart_, lastFlush_);
    if (keyedSamples >= static_cast<long long>(sr_) * kSegSeconds) {
        flushSegment();
    }
}

void CwCompareCapture::flushSegment() {
    // Grab the last kSegSeconds of audio from the ring
    const int grabSamples = sr_ * kSegSeconds;
    const long long have = std::min<long long>(total_, static_cast<long long>(ring_.size()));
    const long long take = std::min<long long>(have, grabSamples);

    std::vector<float> audio(static_cast<size_t>(grabSamples), 0.0f);
    for (long long i = 0; i < take; ++i) {
        const size_t src = (head_ + ring_.size() - static_cast<size_t>(take - i)) % ring_.size();
        audio[audio.size() - static_cast<size_t>(take - i)] = ring_[src];
    }

    // Check we have something worth writing (at least one decoder produced text)
    bool anyText = false;
    for (int i = 0; i < 3; ++i) {
        if (!text_[i].empty()) { anyText = true; break; }
    }
    if (!anyText) {
        lastFlush_ = total_;
        return;
    }

    // Timestamp for filenames
    auto now = std::chrono::system_clock::now();
    auto epoch = std::chrono::duration_cast<std::chrono::seconds>(
                     now.time_since_epoch()).count();

    char stem[128];
    std::snprintf(stem, sizeof stem, "cmp_%lld_%04d", static_cast<long long>(epoch), seq_++);

    const std::string wavPath = dir_ + "/" + stem + ".wav";
    const std::string jsonPath = dir_ + "/" + stem + ".json";

    float peak = 0.0f;
    writeWav16(wavPath, audio, sr_, &peak);

    static const char* names[] = {"classic", "deepfist", "deepcw"};
    std::string json = "{\n";
    json += "  \"sample_rate\": " + std::to_string(sr_) + ",\n";
    json += "  \"duration_s\": " + std::to_string(kSegSeconds) + ",\n";
    json += "  \"peak\": " + std::to_string(peak) + ",\n";
    json += "  \"keying_ratio\": " + std::to_string(lastRatio_) + ",\n";
    json += "  \"decoders\": {\n";
    for (int i = 0; i < 3; ++i) {
        json += "    \"";
        json += names[i];
        json += "\": \"";
        json += jsonEscape(text_[i]);
        json += "\"";
        json += (i < 2 ? ",\n" : "\n");
    }
    json += "  }\n}\n";
    writeTextFile(jsonPath, json);

    // Reset text accumulators
    for (int i = 0; i < 3; ++i) text_[i].clear();
    lastFlush_ = total_;
    written_.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace lyra::dsp

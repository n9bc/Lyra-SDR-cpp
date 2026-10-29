// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md
//
// Word-space timeline shared between two neural CW decoders on the same audio.
// DeepCW spaces words far better than DeepFist on real fists, while DeepFist
// gets more letters right.  In DeepFist mode DeepCW runs unseen alongside and
// publishes every char it commits here (audio time + token); DeepFist keeps its
// own letters and asks, for the stretch between two of them, whether DeepCW put
// a space there.
//
// Both decoders are reset together and fed the same samples, so their audio
// clocks match; but DeepCW places its CTC spikes later than DeepFist (~0.35 s),
// so the consumer passes a lag it measures by pairing letters both decoded.
//
// Threading: one publisher worker, one consumer worker; everything under mx_.
#pragma once

#include <algorithm>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace lyra::dsp {

class CwSpaceTimeline {
public:
    struct Char {
        double      t;
        std::string tok;   // " " for a space
    };

    void reset() {
        std::lock_guard<std::mutex> lk(mx_);
        chars_.clear();
        settled_ = -1.0;
    }

    // Publisher: a committed char (non-decreasing t).
    void publish(double t, const std::string& tok) {
        std::lock_guard<std::mutex> lk(mx_);
        chars_.push_back({t, tok});
        while (chars_.size() > kKeep) chars_.pop_front();
    }

    // Publisher: no char at or before `t` will be published any more.
    void setSettled(double t) {
        std::lock_guard<std::mutex> lk(mx_);
        settled_ = std::max(settled_, t);
    }

    double settled() const {
        std::lock_guard<std::mutex> lk(mx_);
        return settled_;
    }

    // Whether the publisher put a space in (from, to] of its own audio time.
    bool spaceIn(double from, double to) const {
        std::lock_guard<std::mutex> lk(mx_);
        for (const Char& c : chars_)
            if (c.tok == " " && c.t > from && c.t <= to) return true;
        return false;
    }

    // Publisher letters (not spaces) in [from, to], for lag measurement.
    std::vector<Char> lettersIn(double from, double to) const {
        std::lock_guard<std::mutex> lk(mx_);
        std::vector<Char> out;
        for (const Char& c : chars_)
            if (c.tok != " " && c.t >= from && c.t <= to) out.push_back(c);
        return out;
    }

private:
    static constexpr size_t kKeep = 400;   // well over a 6 s window of chars
    mutable std::mutex mx_;
    std::deque<Char>   chars_;
    double             settled_ = -1.0;
};

}  // namespace lyra::dsp

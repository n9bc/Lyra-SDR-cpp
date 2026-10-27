// Lyra-cpp — eSSB practice loop: decides whether a loop pass was played
// entirely on one A/B side with no flip or edit.  Only clean passes update
// the coach graph.  Pure logic (no Qt); GUI-thread only.

#pragma once

#include "tx/RackAbSwitch.h"

namespace lyra::tx {

class PracticePassTracker {
public:
    using Side = RackAbSwitch::Side;
    struct Result { bool clean; Side side; };

    void reset() { clean_ = true; side_ = Side::B; }
    void onPassStart(Side s) { side_ = s; clean_ = true; }
    void onFlip() { clean_ = false; }
    void onEdit() { clean_ = false; }
    Result onPassEnd() const { return {clean_, side_}; }

private:
    bool clean_ = true;
    Side side_ = Side::B;
};

// Save step 1 (PracticeLoop::save): Save writes B, so on A go back to B the
// way a flip does (re-applies the operator's B exactly) and discard the pass
// in progress like a flip.  No-op on B or when idle.  After this the caller
// saves the live rack and makes it the new A (RackAbSwitch::setA).
inline void returnToBForSave(RackAbSwitch &ab, PracticePassTracker &tracker) {
    if (!ab.active() || ab.side() != RackAbSwitch::Side::A) return;
    ab.flip();
    tracker.onFlip();
}

} // namespace lyra::tx

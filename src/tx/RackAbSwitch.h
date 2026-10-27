// Lyra-cpp — eSSB practice loop: A/B switch over the native TX rack.
//
// A is the active profile's saved rack, B is the operator's live edits.
// The switch swaps exactly four model states (eq, speech, combinator, plate)
// through injected capture/apply functions, so it needs only Qt Core and can
// be tested without the models.  GUI-thread only — no atomics.
//
// Applying a state makes the models emit change signals; those are wired to
// noteEdit(), which ignores them while an apply is in flight (applying_).

#pragma once

#include <QJsonObject>

#include <functional>

namespace lyra::tx {

struct RackState {
    QJsonObject eq, speech, combinator, plate;
    bool operator==(const RackState &o) const {
        return eq == o.eq && speech == o.speech
            && combinator == o.combinator && plate == o.plate;
    }
};

class RackAbSwitch {
public:
    enum class Side { A, B };

    RackAbSwitch(std::function<RackState()> capture,
                 std::function<void(const RackState &)> apply);

    // Start a session: A = saved rack, side B (live edits).  Changes nothing live.
    void begin(const RackState &savedA);
    // B -> A: snapshot live into B, apply A.  A -> B: apply B.  No-op when idle.
    void flip();
    // The operator saved: the live rack becomes the new A; side B.
    void setA(const RackState &s);
    // Leave the session; if on A, put the operator's B back live.  Idle after.
    void end();
    // Leave the session WITHOUT applying anything: the live rack stays as it
    // is (a profile load replaced it, and B must not be put back over it).
    void abandon();
    // A model changed.  Ignored (false) during apply or when idle.  On A the
    // edit makes the live rack the new B (side B).  Returns true if counted.
    bool noteEdit();

    Side side() const { return side_; }
    bool active() const { return active_; }

private:
    void applyGuarded(const RackState &s);

    std::function<RackState()> capture_;
    std::function<void(const RackState &)> apply_;
    RackState a_, b_;
    Side side_ = Side::B;
    bool active_ = false;
    bool applying_ = false;
};

} // namespace lyra::tx

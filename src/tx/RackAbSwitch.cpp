#include "tx/RackAbSwitch.h"

#include <utility>

namespace lyra::tx {

RackAbSwitch::RackAbSwitch(std::function<RackState()> capture,
                           std::function<void(const RackState &)> apply)
    : capture_(std::move(capture)), apply_(std::move(apply)) {}

void RackAbSwitch::applyGuarded(const RackState &s) {
    applying_ = true;
    apply_(s);
    applying_ = false;
}

void RackAbSwitch::begin(const RackState &savedA) {
    a_ = savedA;
    side_ = Side::B;
    active_ = true;
}

void RackAbSwitch::flip() {
    if (!active_) return;
    if (side_ == Side::B) {
        b_ = capture_();
        applyGuarded(a_);
        side_ = Side::A;
    } else {
        applyGuarded(b_);
        side_ = Side::B;
    }
}

void RackAbSwitch::setA(const RackState &s) {
    a_ = s;
    side_ = Side::B;
}

void RackAbSwitch::end() {
    if (!active_) return;
    if (side_ == Side::A) applyGuarded(b_);
    side_ = Side::B;
    active_ = false;
}

void RackAbSwitch::abandon() {
    side_ = Side::B;
    active_ = false;
}

bool RackAbSwitch::noteEdit() {
    if (applying_ || !active_) return false;
    if (side_ == Side::A) {
        b_ = capture_();
        side_ = Side::B;
    }
    return true;
}

} // namespace lyra::tx

// Lyra — ProfileBindings: the seam between ProfileManager and the live
// Prefs / HL2Stream / WdspEngine objects.
//
// ProfileManager is deliberately decoupled from those heavy objects (a
// real HL2Stream needs WSA/sockets, WdspEngine needs wdsp.dll) — so the
// field plumbing lives in main.cpp (where all three are in scope) as
// two plain functions, and the manager just calls capture()/apply().
// Unit tests inject fakes over local state (the PTT-FSM §15.25 "inject
// fakes, no heavy deps" testability pattern).

#pragma once

#include <functional>
#include "profile/Profile.h"

namespace lyra::profile {

struct ProfileBindings {
    // Read the current live operator state into a Profile (name left
    // blank — the manager fills it).
    std::function<Profile()> capture;

    // Push every Stage-0 field through its setter, in the §-design apply
    // order (mode -> BW/lock/filterLow -> micSource -> gains/agc/...).
    std::function<void(const Profile &)> apply;

    // True while the wire MOX bit is set — the manager must NOT apply a
    // profile (source/BW switch) mid-transmit (the §15.25 discipline).
    std::function<bool()> isTxActive = [] { return false; };

    // True while the live mode keeps its own filter bandwidth (CW).  The
    // profiles are voice/digital chains; their 4 kHz must not land on the
    // CW filter, and the CW width must not dirty or overwrite the profile.
    std::function<bool()> keepsOwnBandwidth = [] { return false; };
};

}  // namespace lyra::profile

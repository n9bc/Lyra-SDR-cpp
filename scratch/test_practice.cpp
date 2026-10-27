// Lyra-cpp — unit test for the eSSB practice loop's A/B rack switch and
// clean-pass tracker (RackAbSwitch, PracticePassTracker), and the monitor
// routing decision (dsp/MonitorRouting.h).
//
// Qt Core only (QJsonObject).  Build + run:
//   cmake --build build --target test_practice && ./build/test_practice

#include "dsp/MonitorRouting.h"
#include "dsp/MonitorRing.h"
#include <vector>
#include "tx/PracticePassTracker.h"
#include "tx/RackAbSwitch.h"

#include <QJsonObject>
#include <cstdio>
#include <functional>

using lyra::dsp::routeMonitor;
using lyra::tx::PracticePassTracker;
using lyra::tx::RackAbSwitch;
using lyra::tx::RackState;
using Side = RackAbSwitch::Side;

static int g_fail = 0;
#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) { std::printf("  FAIL: %s\n", msg); ++g_fail; }            \
        else         { std::printf("  ok  : %s\n", msg); }                      \
    } while (0)

static RackState mk(int tag) {
    RackState s;
    s.eq["t"] = tag;
    s.speech["t"] = tag + 1;
    s.combinator["t"] = tag + 2;
    s.plate["t"] = tag + 3;
    return s;
}

struct Fixture {
    RackState live;
    int applies = 0;
    std::function<void()> onApply;
    RackAbSwitch sw;
    Fixture()
        : sw([this] { return live; },
             [this](const RackState &s) {
                 ++applies;
                 live = s;
                 if (onApply) onApply();
             }) {}
};

int main() {
    std::printf("== RackAbSwitch / PracticePassTracker ==\n");
    const RackState A = mk(10), B1 = mk(20), B2 = mk(30);

    {   // begin_changes_nothing
        Fixture f; f.live = B1;
        f.sw.begin(A);
        CHECK(f.applies == 0, "begin: apply count 0");
        CHECK(f.sw.side() == Side::B, "begin: side B");
        CHECK(f.sw.active(), "begin: active");
        CHECK(f.live == B1, "begin: live untouched");
    }
    {   // flip_round_trip_restores_b
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();
        CHECK(f.live == A && f.sw.side() == Side::A, "flip: live == A, side A");
        f.sw.flip();
        CHECK(f.live == B1 && f.sw.side() == Side::B, "flip back: live == B1 exactly");
    }
    {   // apply_does_not_count_as_edit
        Fixture f; f.live = B1;
        f.sw.begin(A);
        bool ret = true;
        f.onApply = [&] { ret = f.sw.noteEdit(); };
        f.sw.flip();
        CHECK(!ret, "noteEdit inside apply returns false");
        CHECK(f.sw.side() == Side::A, "side unchanged after in-apply noteEdit");
        f.onApply = nullptr;
        f.sw.flip();
        CHECK(f.live == B1, "b_ unchanged by in-apply noteEdit");
    }
    {   // edit_on_a_becomes_b
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();
        f.live = B2;                       // operator edits while on A
        CHECK(f.sw.noteEdit(), "noteEdit on A returns true");
        CHECK(f.sw.side() == Side::B, "edit on A -> side B");
        f.sw.flip();
        CHECK(f.live == A, "flip to A restores A");
        f.sw.flip();
        CHECK(f.live == B2, "flip to B restores edited state");
        CHECK(f.sw.noteEdit(), "noteEdit on B returns true");
    }
    {   // idle noteEdit ignored
        Fixture f; f.live = B1;
        CHECK(!f.sw.noteEdit(), "noteEdit when idle returns false");
        CHECK(!f.sw.active(), "idle: not active");
    }
    {   // end_on_a_restores_b
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();
        f.sw.end();
        CHECK(f.live == B1, "end on A restores B");
        CHECK(!f.sw.active(), "idle after end");
        const int n = f.applies;
        f.sw.begin(A); f.sw.end();
        CHECK(f.applies == n, "end on B applies nothing");
    }
    {   // abandon_on_a_keeps_loaded_profile (M3): a profile load whose four
        // blobs equal A emits no rack signal, so B is still the stale edit;
        // abandon() must leave the loaded rack live, not put B back.
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();                       // on A, B1 parked
        const RackState loaded = A;        // new profile, same four blobs as A
        f.live = loaded;                   // the load applied it (no signal)
        const int n = f.applies;
        f.sw.abandon();
        CHECK(f.applies == n, "abandon applies nothing");
        CHECK(f.live == loaded, "abandon on A keeps the loaded profile live");
        CHECK(!f.sw.active() && f.sw.side() == Side::B, "abandon -> idle, side B");
        f.sw.end();
        CHECK(f.applies == n, "end after abandon applies nothing");
    }
    {   // abandon_on_b_keeps_live
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.live = B2;                       // the load put B2 live
        f.sw.abandon();
        CHECK(f.applies == 0 && f.live == B2, "abandon on B keeps live, no apply");
    }
    {   // external_save_on_a_refreshes_a (M2): saveActive from another panel
        // while on A saves the live A; setA(stored) then end() applies nothing,
        // so the saved profile stays live.
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();                       // on A
        const RackState stored = f.live;   // what saveActive() wrote
        f.sw.setA(stored);
        CHECK(f.sw.side() == Side::B, "external save: side B");
        const int n = f.applies;
        f.sw.end();
        CHECK(f.applies == n && f.live == stored, "external save then end: saved rack stays live");
    }
    {   // setA_after_save
        Fixture f; f.live = B1;
        f.sw.begin(A);
        f.sw.flip();
        f.sw.setA(B1);
        CHECK(f.sw.side() == Side::B, "setA sets side B");
        f.sw.flip();
        CHECK(f.live == B1, "setA then flip -> live == B1");
    }
    {   // save_on_a_writes_b: the save sequence on A ends with live == B1, A == B1
        Fixture f; f.live = B1;
        PracticePassTracker t;
        f.sw.begin(A);
        f.sw.flip();                       // on A, operator's B1 parked
        t.onPassStart(Side::A);
        CHECK(f.live == A && f.sw.side() == Side::A, "save_on_a: precondition on A");
        returnToBForSave(f.sw, t);
        CHECK(f.live == B1, "save_on_a: B1 re-applied before save");
        CHECK(f.sw.side() == Side::B, "save_on_a: side B");
        CHECK(!t.onPassEnd().clean, "save_on_a: pass in progress discarded");
        const RackState saved = f.live;    // what saveActive() would capture
        CHECK(saved == B1, "save_on_a: saved rack == B1");
        f.sw.setA(saved);
        f.sw.flip();
        CHECK(f.live == B1, "save_on_a: A == B1 after setA");
    }
    {   // save_on_b_no_flip: on B the save step changes nothing and keeps the pass
        Fixture f; f.live = B1;
        PracticePassTracker t;
        f.sw.begin(A);
        t.onPassStart(Side::B);
        const int n = f.applies;
        returnToBForSave(f.sw, t);
        CHECK(f.applies == n && f.live == B1, "save_on_b: no apply, live == B1");
        CHECK(t.onPassEnd().clean, "save_on_b: pass stays clean");
    }
    {   // tracker
        PracticePassTracker t;
        t.onPassStart(Side::B);
        auto r = t.onPassEnd();
        CHECK(r.clean && r.side == Side::B, "pass_clean_whole_side");
        t.onPassStart(Side::A);
        r = t.onPassEnd();
        CHECK(r.clean && r.side == Side::A, "clean pass on A");
        t.onPassStart(Side::B); t.onFlip();
        CHECK(!t.onPassEnd().clean, "flip_mid_pass_discards");
        t.onPassStart(Side::B); t.onEdit();
        CHECK(!t.onPassEnd().clean, "edit_mid_pass_discards");
        t.onPassStart(Side::B);
        CHECK(t.onPassEnd().clean, "onPassStart re-marks clean");
        t.onPassStart(Side::B); t.onEdit(); t.reset();
        t.onPassStart(Side::B);
        CHECK(t.onPassEnd().clean, "reset then fresh pass is clean");
    }

    std::printf("== MonitorRouting ==\n");
    {   // routing_mon_off_idle
        constexpr auto r = routeMonitor(false, false, false);
        CHECK(!r.fillTap && !r.local && !r.remote, "routing_mon_off_idle: all false");
    }
    {   // routing_mox_monitor
        constexpr auto r = routeMonitor(true, true, false);
        CHECK(r.fillTap && r.local && r.remote, "routing_mox_monitor: fillTap, local, remote");
    }
    {   // routing_practice_local_only
        constexpr auto r1 = routeMonitor(false, false, true);
        CHECK(r1.fillTap && r1.local && !r1.remote,
              "routing_practice_local_only (MON off): fillTap, local, not remote");
        constexpr auto r2 = routeMonitor(true, false, true);
        CHECK(r2.fillTap && r2.local && !r2.remote,
              "routing_practice_local_only (MON on): fillTap, local, not remote");
    }
    {   // routing_mon_on_rx
        constexpr auto r = routeMonitor(true, false, false);
        CHECK(r.fillTap && !r.local && !r.remote, "routing_mon_on_rx: fillTap only");
    }

    // ── practice jitter buffer (MonitorRing::popPrimed) ──
    {   // primed_waits_for_cushion / primed_steady / primed_underrun_reprimes
        lyra::dsp::MonitorRing ring(16384);
        std::vector<double> in(4096, 0.5), out(256, 9.0);
        bool primed = false;
        ring.push(in.data(), 1000);
        std::size_t got = ring.popPrimed(out.data(), 256, 2400, primed);
        CHECK(got == 0 && !primed && ring.available() == 1000 && out[0] == 9.0,
              "primed_waits_for_cushion: below prime -> nothing popped, ring untouched");
        ring.push(in.data(), 1400);   // 2400 now
        got = ring.popPrimed(out.data(), 256, 2400, primed);
        CHECK(got == 256 && primed && ring.available() == 2144,
              "primed_waits_for_cushion: at prime -> full block, primed");
        got = ring.popPrimed(out.data(), 256, 2400, primed);
        CHECK(got == 256 && primed, "primed_steady: keeps popping below prime once primed");
        while (ring.available() >= 256) ring.popPrimed(out.data(), 256, 2400, primed);
        const std::size_t left = ring.available();
        got = ring.popPrimed(out.data(), 256, 2400, primed);
        CHECK(got == left && !primed, "primed_underrun_reprimes: partial block delivered, unprimed");
        ring.push(in.data(), 500);
        got = ring.popPrimed(out.data(), 256, 2400, primed);
        CHECK(got == 0 && !primed, "primed_underrun_reprimes: waits for the cushion again");
    }

    std::printf("%s (%d FAIL)\n", g_fail ? "FAILED" : "ALL OK", g_fail);
    return g_fail ? 1 : 0;
}

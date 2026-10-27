// Lyra-cpp — unit test for the voice-keyer injector core (#89 Stage A).
// ClipRecorderPlayer: fill-block streaming, gain, OTA keying, keyup-on-end,
// silence drain, stop() abort, own-key discipline, Review (no-MOX).
//
// Qt-free / DSP-free by design.  Build + run:
//   cmake --build build --target test_clip_player
//   build/test_clip_player.exe

#include "tx/ClipRecorderPlayer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <vector>

using lyra::tx::ClipRecorderPlayer;

static int g_fail = 0;
#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) { std::printf("  FAIL: %s\n", msg); ++g_fail; }            \
        else         { std::printf("  ok  : %s\n", msg); }                      \
    } while (0)

static std::shared_ptr<std::vector<float>> ramp(int n) {
    auto v = std::make_shared<std::vector<float>>(n);
    for (int i = 0; i < n; ++i) (*v)[i] = 0.01f * static_cast<float>(i + 1);  // 0.01,0.02,...
    return v;
}

int main() {
    std::printf("== ClipRecorderPlayer (voice-keyer injector core) ==\n");

    // ── 1. OTA playback: gain, sample order, Q=0, keydown-once ──
    {
        ClipRecorderPlayer p;
        std::vector<bool> keys;
        p.setKeyFn([&](bool on) { keys.push_back(on); });
        auto clip = ramp(25);
        ClipRecorderPlayer::PlayOptions o; o.ota = true; o.gainLin = 2.0;
        CHECK(p.play(clip, o), "play(OTA) accepted");
        CHECK(keys.size() == 1 && keys[0] == true, "keydown asserted once at play");
        CHECK(p.keyed() && p.playing(), "keyed + playing after play");

        double buf[2 * 10];
        bool r1 = p.fillBlock(10, buf);
        CHECK(r1, "block1 active");
        CHECK(std::fabs(buf[0] - 0.02) < 1e-6 && buf[1] == 0.0, "sample0 = clip0*gain, Q=0");
        CHECK(std::fabs(buf[2 * 9] - 0.20) < 1e-6, "sample9 = clip9*gain");

        bool r2 = p.fillBlock(10, buf);                 // pos 10..19
        CHECK(r2 && std::fabs(buf[0] - 0.22) < 1e-6, "block2 continues");

        bool r3 = p.fillBlock(10, buf);                 // pos 20..24 then exhaust
        CHECK(r3, "block3 (exhaust) still active (draining)");
        CHECK(std::fabs(buf[2 * 4] - 0.50) < 1e-6, "last real sample (clip24*gain)");
        CHECK(buf[2 * 5] == 0.0 && buf[2 * 9] == 0.0, "block3 remainder silenced");
        CHECK(keys.size() == 2 && keys[1] == false, "keyup requested once at clip end");
        CHECK(!p.keyed(), "no longer holds key after keyup");

        // Drain the post-clip silence tail to Idle (correctly-sized buffer).
        std::vector<double> big(2 * ClipRecorderPlayer::kDrainTailSamples, -1.0);
        while (p.playing()) p.fillBlock(ClipRecorderPlayer::kDrainTailSamples, big.data());
        CHECK(!p.playing(), "idle after drain completes");
        CHECK(keys.size() == 2, "no extra key events during/after drain");
    }

    // ── 2. stop() aborts + releases the key ──
    {
        ClipRecorderPlayer p;
        std::vector<bool> keys;
        p.setKeyFn([&](bool on) { keys.push_back(on); });
        ClipRecorderPlayer::PlayOptions o; o.ota = true;
        p.play(ramp(1000), o);
        double buf[2 * 10];
        p.fillBlock(10, buf);
        p.stop();
        CHECK(!p.playing(), "stop() → idle");
        CHECK(keys.size() == 2 && keys[1] == false, "stop() released our key");
        p.stop();  // idempotent
        CHECK(keys.size() == 2, "second stop() is a no-op");
    }

    // ── 3. Own-key discipline: blocked → play refused, no key ──
    {
        ClipRecorderPlayer p;
        std::vector<bool> keys;
        bool blocked = true;
        p.setKeyFn([&](bool on) { keys.push_back(on); });
        p.setBlockedFn([&]() { return blocked; });
        ClipRecorderPlayer::PlayOptions o; o.ota = true;
        CHECK(!p.play(ramp(50), o), "play refused while a manual key owns TX");
        CHECK(keys.empty(), "no key asserted when blocked");

        // Now allow, play, then block mid-clip → fillBlock aborts w/o keyup.
        blocked = false;
        CHECK(p.play(ramp(1000), o), "play accepted once unblocked");
        double buf[2 * 10];
        p.fillBlock(10, buf);
        blocked = true;                                  // manual key grabs TX mid-clip
        bool r = p.fillBlock(10, buf);
        CHECK(!r && !p.playing(), "fillBlock aborts when a higher-priority source grabs the key");
        CHECK(keys.size() == 1 && keys[0] == true, "abort did NOT toggle the key (manual source owns it)");
    }

    // ── 4. Review (no OTA): fills audio but never keys ──
    {
        ClipRecorderPlayer p;
        std::vector<bool> keys;
        p.setKeyFn([&](bool on) { keys.push_back(on); });
        ClipRecorderPlayer::PlayOptions o; o.ota = false; o.gainLin = 1.0;
        CHECK(p.play(ramp(20), o), "play(Review) accepted");
        CHECK(keys.empty() && !p.keyed(), "Review never asserts the key");
        double buf[2 * 10];
        bool r = p.fillBlock(10, buf);
        CHECK(r && std::fabs(buf[0] - 0.01) < 1e-6, "Review still fills clip audio (for monitor)");
        p.stop();
        CHECK(keys.empty(), "stop() after Review keys nothing (nothing to release)");
    }

    // ── 5. Guards: double-play + null/empty clip ──
    {
        ClipRecorderPlayer p;
        ClipRecorderPlayer::PlayOptions o; o.ota = false;
        CHECK(!p.play(nullptr, o), "null clip refused");
        CHECK(!p.play(std::make_shared<std::vector<float>>(), o), "empty clip refused");
        CHECK(p.play(ramp(1000), o), "first play accepted");
        CHECK(!p.play(ramp(10), o), "second play refused while playing");
        p.stop();
    }

    // ── 6. Loop (eSSB practice): seamless wrap, no key, pass counter ──
    {
        ClipRecorderPlayer p;
        int keyCalls = 0;
        p.setKeyFn([&](bool) { ++keyCalls; });
        ClipRecorderPlayer::PlayOptions o; o.ota = false; o.loop = true;
        CHECK(p.play(ramp(10), o), "loop play accepted");
        CHECK(p.clipSamples() == 10, "clipSamples() reports clip length");
        CHECK(p.passCount() == 0, "passCount 0 at play()");
        std::vector<double> buf(2 * 25, 9.0);
        CHECK(p.fillBlock(25, buf.data()), "loop block active");
        bool seq = true;
        for (int i = 0; i < 25; ++i)
            if (std::fabs(buf[2 * i] - 0.01 * ((i % 10) + 1)) > 1e-6 || buf[2 * i + 1] != 0.0) seq = false;
        CHECK(seq, "loop wraps with no gap (ramp[0..9] x2 + ramp[0..4])");
        CHECK(p.passCount() == 2, "passCount == 2 after two wraps");
        CHECK(p.active() && p.playing(), "still active after wraps");
        CHECK(keyCalls == 0, "loop made no KeyFn call");
        p.stop();
        CHECK(p.clipSamples() == 0, "clipSamples() 0 when idle");
    }

    // ── 7. Loop + OTA is refused (never loop onto the air) ──
    {
        ClipRecorderPlayer p;
        ClipRecorderPlayer::PlayOptions o; o.ota = true; o.loop = true;
        CHECK(!p.play(ramp(10), o), "play(ota+loop) refused");
        CHECK(!p.playing(), "not playing after refused ota+loop");
    }

    // ── 8. RefuseFn: stop + revert to live mic, buffer untouched ──
    {
        ClipRecorderPlayer p;
        int keyCalls = 0, refuseCalls = 0;
        p.setKeyFn([&](bool) { ++keyCalls; });
        p.setRefuseFn([&] { return ++refuseCalls >= 2; });
        ClipRecorderPlayer::PlayOptions o; o.ota = false; o.loop = true;
        CHECK(p.play(ramp(10), o), "refuse test: play accepted");
        std::vector<double> buf(2 * 8, 9.0);
        CHECK(p.fillBlock(8, buf.data()) && std::fabs(buf[0] - 0.01) < 1e-6, "1st block carries clip samples");
        std::fill(buf.begin(), buf.end(), 9.0);
        CHECK(!p.fillBlock(8, buf.data()), "2nd block refused -> returns false");
        bool untouched = true;
        for (double v : buf) if (v != 9.0) untouched = false;
        CHECK(untouched, "refused block leaves buffer untouched (live mic flows)");
        CHECK(!p.active() && !p.playing(), "refuse -> idle");
        CHECK(keyCalls == 0, "refuse made no KeyFn call");
    }

    // ── 8b. Refuse with an outside owner: the player only drops its ref ──
    // (eSSB practice: PracticeLoop holds the clip, so the cm-thread refuse
    // path never frees it.)  The refuse fn's side effect (the Plate flush
    // request) runs once per refused block.
    {
        ClipRecorderPlayer p;
        int flushes = 0;
        bool refuse = false;
        p.setRefuseFn([&] { if (!refuse) return false; ++flushes; return true; });
        auto hold = ramp(10);
        const float *data = hold->data();
        ClipRecorderPlayer::PlayOptions o; o.ota = false; o.loop = true;
        CHECK(p.play(hold, o), "hold test: play accepted");
        CHECK(hold.use_count() == 2, "player shares the held clip");
        std::vector<double> buf(2 * 4, 9.0);
        CHECK(p.fillBlock(4, buf.data()), "hold test: 1st block plays");
        refuse = true;
        CHECK(!p.fillBlock(4, buf.data()), "hold test: refused block");
        CHECK(flushes == 1, "refusal ran the flush side effect once");
        CHECK(hold.use_count() == 1, "refuse dropped only the player's reference");
        CHECK(hold->data() == data && hold->size() == 10 && std::fabs((*hold)[9] - 0.10f) < 1e-6f,
              "held clip still intact after refuse");
        CHECK(p.passCount() == 0 && p.clipSamples() == 0, "refuse -> idle, no clip, no pass");
        CHECK(!p.fillBlock(4, buf.data()) && flushes == 1, "idle: refuse fn not consulted again");
    }

    // ── 9. RefuseFn is ignored for OTA (own BlockedFn discipline) ──
    {
        ClipRecorderPlayer p;
        std::vector<bool> keys;
        p.setKeyFn([&](bool on) { keys.push_back(on); });
        p.setRefuseFn([] { return true; });
        ClipRecorderPlayer::PlayOptions o; o.ota = true;
        CHECK(p.play(ramp(50), o), "OTA play accepted with refuse fn set");
        std::vector<double> buf(2 * 8, 9.0);
        CHECK(p.fillBlock(8, buf.data()) && std::fabs(buf[0] - 0.01) < 1e-6, "OTA ignores refuse fn");
        CHECK(p.active() && keys.size() == 1, "OTA still active, key untouched");
        p.stop();
    }

    std::printf(g_fail ? "\nRESULT: %d CHECK(S) FAILED\n" : "\nRESULT: ALL CHECKS PASSED\n", g_fail);
    return g_fail ? 1 : 0;
}

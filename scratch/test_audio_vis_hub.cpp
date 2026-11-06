// Offline test for lyra::dsp::vis::AudioVisHub / DemoSignal
// (src/dsp/AudioVisHub.h) — the audio visualizer's lock-free sample rings,
// GUI-thread FFT analysis and demo signal.
//   build: cmake --build build --target test_audio_vis_hub
//   run:   build/test_audio_vis_hub
#include "dsp/AudioVisHub.h"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

using namespace lyra::dsp::vis;

namespace {

constexpr double kFs = 48000.0;
constexpr double kPi = 3.14159265358979323846;

int g_failures = 0;

void check(const char *name, bool ok, double got)
{
    std::printf("  %-62s got=%10.4f  %s\n", name, got, ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

// Mono-dup interleaved L/R sine.
std::vector<double> sineLR(double hz, double amp, int frames)
{
    std::vector<double> v(size_t(frames) * 2);
    for (int i = 0; i < frames; ++i) {
        const double s = amp * std::sin(2.0 * kPi * hz * i / kFs);
        v[size_t(2 * i)] = s;
        v[size_t(2 * i + 1)] = s;
    }
    return v;
}

std::vector<double> sineMono(double hz, double amp, int n)
{
    std::vector<double> v(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) v[size_t(i)] = amp * std::sin(2.0 * kPi * hz * i / kFs);
    return v;
}

int peakIndex(const float *a, int n)
{
    return int(std::max_element(a, a + n) - a);
}

// Centre frequency of FFT-line point i for a given span.
double lineHz(int i, double span) { return (i + 0.5) * span / 256.0; }

bool allFiniteAtMost(const Frame &f, float maxDb)
{
    auto ok = [&](const float *a, int n) {
        for (int i = 0; i < n; ++i)
            if (!std::isfinite(a[i]) || a[i] > maxDb) return false;
        return true;
    };
    return ok(f.lineDb, 256) && ok(f.bandsDb25, 25) && ok(f.bandsDbRadial, 24);
}

bool allFinite(const Frame &f)
{
    return allFiniteAtMost(f, 1e9f)
        && std::all_of(f.scope, f.scope + 512, [](float x) { return std::isfinite(x); });
}

void fresh()
{
    AudioVisHub::instance().reset();
}

}  // namespace

int main()
{
    AudioVisHub &hub = AudioVisHub::instance();

    std::printf("(a) 1 kHz sine, amp 0.5, via pushRx\n");
    {
        fresh();
        hub.acquire();
        check("active() after acquire", hub.active(), 1);
        const auto buf = sineLR(1000.0, 0.5, 8192);
        hub.pushRx(buf.data(), 8192, false, false, false);
        hub.setSource(false);
        Frame f{};
        const bool ok = hub.frame(4000.0, f);
        check("frame() returns true", ok, ok);
        check("frame.live", f.live, f.live);
        check("frame.tx == false", !f.tx, f.tx);
        check("frame.spanHz == 4000", std::fabs(f.spanHz - 4000.0) < 1e-9, f.spanHz);
        const int pk = peakIndex(f.lineDb, 256);
        const double hz = lineHz(pk, 4000.0);
        check("line peak within 1000 Hz +/- 50", std::fabs(hz - 1000.0) <= 50.0, hz);
        const double expect = 20.0 * std::log10(0.5);
        check("peak dB within 3 dB of -6.02", std::fabs(f.lineDb[pk] - expect) <= 3.0, f.lineDb[pk]);
        const int pk25 = peakIndex(f.bandsDb25, 25);
        check("25-band peak dB within 3 dB", std::fabs(f.bandsDb25[pk25] - expect) <= 3.0, f.bandsDb25[pk25]);
        const int pkR = peakIndex(f.bandsDbRadial, 24);
        check("radial peak dB within 3 dB", std::fabs(f.bandsDbRadial[pkR] - expect) <= 3.0, f.bandsDbRadial[pkR]);
        check("all outputs finite", allFinite(f), 0);
        hub.release();
        check("active() false after release", !hub.active(), hub.active());
    }

    std::printf("(b) no acquire: pushRx is a no-op\n");
    {
        fresh();
        const auto buf = sineLR(1000.0, 0.5, 4096);
        hub.pushRx(buf.data(), 4096, false, false, false);
        const auto mono = sineMono(1000.0, 0.5, 4096);
        hub.pushTx(mono.data(), 4096);
        Frame f{};
        check("frame() false while inactive", !hub.frame(4000.0, f), 0);
        check("rx ring untouched", hub.rxPending() == 0, double(hub.rxPending()));
        check("tx ring untouched", hub.txPending() == 0, double(hub.txPending()));
    }

    std::printf("(c) all-zero input\n");
    {
        fresh();
        hub.acquire();
        std::vector<double> z(8192 * 2, 0.0);
        hub.pushRx(z.data(), 8192, false, false, false);
        Frame f{};
        const bool ok = hub.frame(4000.0, f);
        check("frame() true", ok, ok);
        check("every dB value finite and <= -100", allFiniteAtMost(f, -100.f), 0);
        check("scope finite", std::all_of(f.scope, f.scope + 512, [](float x) { return std::isfinite(x); }), 0);
        hub.release();
    }

    std::printf("(d) never pushed\n");
    {
        fresh();
        hub.acquire();
        Frame f{};
        const bool ok = hub.frame(4000.0, f);
        check("frame() true", ok, ok);
        check("live == false", !f.live, f.live);
        check("all finite", allFinite(f), 0);
        check("every dB value <= -100", allFiniteAtMost(f, -100.f), 0);
        hub.release();
    }

    std::printf("(e) TX source reads only pushTx\n");
    {
        fresh();
        hub.acquire();
        const auto rx = sineLR(1000.0, 0.5, 8192);
        const auto tx = sineMono(2000.0, 0.5, 8192);
        // The TX tap copies nothing while the source is RX.
        hub.setSource(false);
        hub.pushTx(tx.data(), 8192);
        check("pushTx no-op while source is RX", hub.txPending() == 0, double(hub.txPending()));
        hub.pushRx(rx.data(), 8192, false, false, false);
        hub.setSource(true);
        hub.pushTx(tx.data(), 8192);
        check("pushTx queues once source is TX", hub.txPending() == 8192, double(hub.txPending()));
        Frame f{};
        const bool ok = hub.frame(4000.0, f);
        check("frame() true", ok, ok);
        check("frame.tx == true", f.tx, f.tx);
        const double hz = lineHz(peakIndex(f.lineDb, 256), 4000.0);
        check("line peak within 2000 Hz +/- 50", std::fabs(hz - 2000.0) <= 50.0, hz);
        hub.release();
    }

    std::printf("(f) span 10000 moves the 1 kHz peak to a lower index\n");
    {
        fresh();
        hub.acquire();
        const auto buf = sineLR(1000.0, 0.5, 8192);
        hub.pushRx(buf.data(), 8192, false, false, false);
        Frame a{}, b{};
        hub.frame(4000.0, a);
        hub.frame(10000.0, b);
        const int ia = peakIndex(a.lineDb, 256), ib = peakIndex(b.lineDb, 256);
        check("peak index @10 kHz < @4 kHz", ib < ia, double(ib) - double(ia));
        const double hz = lineHz(ib, 10000.0);
        check("@10 kHz still maps to 1000 Hz +/- 100", std::fabs(hz - 1000.0) <= 100.0, hz);
        check("frame.spanHz == 10000", std::fabs(b.spanHz - 10000.0) < 1e-9, b.spanHz);
        hub.release();
    }

    std::printf("(g) scope triggers on a rising zero crossing\n");
    {
        fresh();
        hub.acquire();
        // Odd length so the window does not end on a fixed phase.
        const auto buf = sineLR(200.0, 0.5, 5001);
        hub.pushRx(buf.data(), 5001, false, false, false);
        Frame f{};
        hub.frame(4000.0, f);
        check("scope[0] within 0.05 of 0", std::fabs(f.scope[0]) <= 0.05, f.scope[0]);
        check("scope[1] > scope[0]", f.scope[1] > f.scope[0], f.scope[1]);
        hub.release();
    }

    std::printf("(h) SUB mix honours per-receiver mute\n");
    {
        fresh();
        hub.acquire();
        // L = 1 kHz, R = 3 kHz; mute RX2 (R) -> only 1 kHz must remain.
        std::vector<double> buf(8192 * 2);
        for (int i = 0; i < 8192; ++i) {
            buf[size_t(2 * i)] = 0.5 * std::sin(2.0 * kPi * 1000.0 * i / kFs);
            buf[size_t(2 * i + 1)] = 0.5 * std::sin(2.0 * kPi * 3000.0 * i / kFs);
        }
        hub.pushRx(buf.data(), 8192, true, false, true);
        Frame f{};
        hub.frame(4000.0, f);
        const double hz = lineHz(peakIndex(f.lineDb, 256), 4000.0);
        check("peak 1000 Hz (RX2 muted)", std::fabs(hz - 1000.0) <= 50.0, hz);
        hub.release();
    }

    std::printf("(i) ring overflow and re-acquire flush\n");
    {
        fresh();
        hub.acquire();
        const auto big = sineLR(1000.0, 0.5, 20000);   // > 16384 capacity
        hub.pushRx(big.data(), 20000, false, false, false);
        check("rx ring capped at 16384", hub.rxPending() == 16384, double(hub.rxPending()));
        hub.release();
        hub.acquire();                                  // stale data must go
        check("rx ring flushed on 0->1 acquire", hub.rxPending() == 0, double(hub.rxPending()));
        hub.release();
    }

    std::printf("(j) DemoSignal\n");
    {
        DemoSignal d;
        std::vector<float> s(48000);
        d.fill(s.data(), 48000, kFs);
        double peak = 0.0, e = 0.0;
        bool fin = true;
        for (float x : s) {
            fin = fin && std::isfinite(x);
            peak = std::max(peak, double(std::fabs(x)));
            e += double(x) * x;
        }
        check("finite", fin, 0);
        check("bounded |x| <= 1", peak <= 1.0, peak);
        check("not silent (rms > 0.01)", std::sqrt(e / 48000.0) > 0.01, std::sqrt(e / 48000.0));
        // Stateful: a split fill equals one continuous fill.
        DemoSignal a, b;
        std::vector<float> one(1000), two(1000);
        a.fill(one.data(), 1000, kFs);
        b.fill(two.data(), 300, kFs);
        b.fill(two.data() + 300, 700, kFs);
        bool same = true;
        for (int i = 0; i < 1000; ++i) same = same && std::fabs(one[size_t(i)] - two[size_t(i)]) < 1e-6f;
        check("split fill == continuous fill", same, 0);
    }

    std::printf("(k) stale data -> silence, not a frozen spectrum\n");
    {
        fresh();
        hub.acquire();
        const auto buf = sineLR(1000.0, 0.5, 8192);
        hub.pushRx(buf.data(), 8192, false, false, false);
        Frame f{};
        hub.frame(4000.0, f);
        check("live right after data", f.live, f.live);
        check("tone visible (peak > -20 dB)", f.lineDb[peakIndex(f.lineDb, 256)] > -20.f, f.lineDb[peakIndex(f.lineDb, 256)]);
        std::this_thread::sleep_for(std::chrono::milliseconds(AudioVisHub::kLiveMs + 100));
        hub.frame(4000.0, f);
        check("live == false after 250 ms of no data", !f.live, f.live);
        check("every dB value finite and <= -100", allFiniteAtMost(f, -100.f), 0);
        float maxScope = 0.f;
        for (float x : f.scope) maxScope = std::max(maxScope, std::fabs(x));
        check("scope all ~0", maxScope < 1e-6f, maxScope);
        // Data resuming goes live again with the tone.
        hub.pushRx(buf.data(), 8192, false, false, false);
        hub.frame(4000.0, f);
        check("live again on resume", f.live, f.live);
        check("tone back (peak > -20 dB)", f.lineDb[peakIndex(f.lineDb, 256)] > -20.f, f.lineDb[peakIndex(f.lineDb, 256)]);
        hub.release();
    }

    std::printf("(l) analyse() on caller-supplied samples\n");
    {
        fresh();                                   // hub inactive, rings untouched
        std::vector<float> tone(8192);
        for (size_t i = 0; i < tone.size(); ++i)
            tone[i] = float(0.5 * std::sin(2.0 * kPi * 1000.0 * double(i) / kFs));
        Frame an{};
        const bool ok = hub.analyse(tone.data(), int(tone.size()), 4000.0, an);
        check("analyse() true while inactive", ok && !hub.active(), ok);
        check("live == true, tx == false", an.live && !an.tx, an.live);
        check("rings untouched", hub.rxPending() == 0 && hub.txPending() == 0, 0);

        // Same line index as the ring path (case a).
        hub.acquire();
        const auto buf = sineLR(1000.0, 0.5, 8192);
        hub.pushRx(buf.data(), 8192, false, false, false);
        Frame ring{};
        hub.frame(4000.0, ring);
        const int ia = peakIndex(an.lineDb, 256), ir = peakIndex(ring.lineDb, 256);
        check("analyse() peak index == ring path", ia == ir, double(ia));
        check("analyse() peak dB within 3 dB of -6.02",
              std::fabs(an.lineDb[ia] - 20.0 * std::log10(0.5)) <= 3.0, an.lineDb[ia]);
        // analyse() while active leaves the ring window alone.
        Frame an2{};
        std::vector<float> z(100, 0.f);
        hub.analyse(z.data(), 100, 4000.0, an2);
        Frame ring2{};
        hub.frame(4000.0, ring2);
        check("ring window unaffected by analyse()", peakIndex(ring2.lineDb, 256) == ir, 0);
        // Short input is zero-padded and still finite.
        Frame sh{};
        check("short input ok + finite", hub.analyse(tone.data(), 64, 4000.0, sh) && allFinite(sh), 0);
        check("null/empty input rejected", !hub.analyse(nullptr, 10, 4000.0, sh) && !hub.analyse(tone.data(), 0, 4000.0, sh), 0);
        hub.release();
    }

    std::printf("(m) non-finite samples are stored as 0\n");
    {
        fresh();
        hub.acquire();
        auto buf = sineLR(1000.0, 0.5, 8192);
        buf[size_t(2 * 8091)] = buf[size_t(2 * 8091 + 1)] = std::nan("");     // in the scope span
        buf[size_t(2 * 6000)] = buf[size_t(2 * 6000 + 1)] = HUGE_VAL;
        buf[size_t(2 * 7000)] = buf[size_t(2 * 7000 + 1)] = -HUGE_VAL;
        hub.pushRx(buf.data(), 8192, false, false, false);
        Frame f{};
        hub.frame(4000.0, f);
        check("RX: all outputs finite", allFinite(f), 0);
        const int pk = peakIndex(f.lineDb, 256);
        check("RX: tone still at 1000 Hz +/- 50", std::fabs(lineHz(pk, 4000.0) - 1000.0) <= 50.0, lineHz(pk, 4000.0));
        check("RX: tone still within 3 dB of -6.02", std::fabs(f.lineDb[pk] - 20.0 * std::log10(0.5)) <= 3.0, f.lineDb[pk]);

        hub.setSource(true);
        auto tx = sineMono(2000.0, 0.5, 8192);
        tx[8100] = std::nan("");
        tx[5000] = HUGE_VAL;
        hub.pushTx(tx.data(), 8192);
        hub.frame(4000.0, f);
        check("TX: all outputs finite", allFinite(f), 0);
        const int pt = peakIndex(f.lineDb, 256);
        check("TX: tone still at 2000 Hz +/- 50", std::fabs(lineHz(pt, 4000.0) - 2000.0) <= 50.0, lineHz(pt, 4000.0));
        hub.release();
    }

    std::printf("(n) DC is not doubled by the single-sided factor\n");
    {
        fresh();
        hub.acquire();
        std::vector<double> dc(8192 * 2, 0.1);              // 0.1 DC = -20 dBFS
        hub.pushRx(dc.data(), 8192, false, false, false);
        Frame f{};
        hub.frame(4000.0, f);
        check("DC 0.1 -> lineDb[0] = -20 dB +/- 0.1", std::fabs(f.lineDb[0] + 20.0) <= 0.1, f.lineDb[0]);
        hub.release();
    }

    std::printf("(o) a full ring (GUI stall) is discarded, not shown as live\n");
    {
        fresh();
        hub.acquire();
        // > 341 ms with no frame(): the ring keeps the OLDEST 16384 samples.
        const auto stale = sineLR(1000.0, 0.5, 20000);
        hub.pushRx(stale.data(), 20000, false, false, false);
        Frame f{};
        hub.frame(4000.0, f);
        check("ring emptied", hub.rxPending() == 0, double(hub.rxPending()));
        check("stale tone not shown (every dB <= -100)", allFiniteAtMost(f, -100.f), f.lineDb[peakIndex(f.lineDb, 256)]);
        check("still live (producer running)", f.live, f.live);
        // Fresh audio after the stall: only it is shown, no stale residue.
        const auto fresh2k = sineLR(2000.0, 0.5, 4096);
        hub.pushRx(fresh2k.data(), 4096, false, false, false);
        hub.frame(4000.0, f);
        const int pk = peakIndex(f.lineDb, 256);
        check("fresh 2 kHz tone shown", std::fabs(lineHz(pk, 4000.0) - 2000.0) <= 50.0, lineHz(pk, 4000.0));
        const int i1k = int(1000.0 / 4000.0 * 256.0);
        check("no 1 kHz residue (<= -100 dB)", f.lineDb[i1k] <= -100.f, f.lineDb[i1k]);
        // A backlog that did NOT overflow is real recent audio: kept.
        const auto backlog = sineLR(1000.0, 0.5, 10000);
        hub.pushRx(backlog.data(), 10000, false, false, false);
        hub.frame(4000.0, f);
        const int pb = peakIndex(f.lineDb, 256);
        check("non-overflow backlog still analysed", std::fabs(lineHz(pb, 4000.0) - 1000.0) <= 50.0, lineHz(pb, 4000.0));
        hub.release();
    }

    std::printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "ALL PASS", g_failures,
                g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}

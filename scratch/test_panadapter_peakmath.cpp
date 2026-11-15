// Offline test for the panadapter peak-math helpers (src/panadapter_peakmath.h):
// the audio-frequency of a peak from its screen fraction + span, and the
// Hz/kHz label formatting.  Qt-light (QString only); no panadapter item.
//   build: cmake --build build --target test_panadapter_peakmath
//   run:   build/test_panadapter_peakmath
#include "panadapter_peakmath.h"

#include <QString>

#include <cmath>
#include <cstdio>

using lyra::peakAudioHz;
using lyra::formatPeakHz;

static int g_failures = 0;

static void expectHz(const char *name, double got, double want)
{
    const bool ok = std::fabs(got - want) < 1e-6;
    std::printf("  %-52s got=%-10.3f want=%-10.3f %s\n", name, got, want,
                ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

static void expectText(const char *name, const QString &got, const QString &want)
{
    const bool ok = got == want;
    std::printf("  %-52s got=%-10s want=%-10s %s\n", name,
                got.toUtf8().constData(), want.toUtf8().constData(),
                ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

int main()
{
    // peakAudioHz = |(frac - 0.5) * span|, 0 for a non-positive span.
    expectHz("centre frac=0.5 -> 0 Hz",            peakAudioHz(0.5, 4000), 0.0);
    expectHz("frac=0.75 span=4000 -> 1000 Hz",     peakAudioHz(0.75, 4000), 1000.0);
    expectHz("frac=0.25 span=4000 -> 1000 (magnitude)", peakAudioHz(0.25, 4000), 1000.0);
    expectHz("frac=0.65 span=6000 -> 900 Hz",      peakAudioHz(0.65, 6000), 900.0);
    expectHz("span=0 -> 0 Hz (degenerate)",        peakAudioHz(0.75, 0.0), 0.0);
    expectHz("span<0 -> 0 Hz (degenerate)",        peakAudioHz(0.75, -4000), 0.0);

    // formatPeakHz: < 1000 -> nearest-10 "NNN Hz"; >= 1000 -> "N.N kHz".
    expectText("650 -> 650 Hz",   formatPeakHz(650),  QStringLiteral("650 Hz"));
    expectText("648 -> 650 Hz",   formatPeakHz(648),  QStringLiteral("650 Hz"));
    expectText("0 -> 0 Hz",       formatPeakHz(0),    QStringLiteral("0 Hz"));
    expectText("1000 -> 1.0 kHz", formatPeakHz(1000), QStringLiteral("1.0 kHz"));
    expectText("1234 -> 1.2 kHz", formatPeakHz(1234), QStringLiteral("1.2 kHz"));
    expectText("2900 -> 2.9 kHz", formatPeakHz(2900), QStringLiteral("2.9 kHz"));

    std::printf(g_failures ? "\n%d FAILURE(S)\n" : "\nALL PASS\n", g_failures);
    return g_failures ? 1 : 0;
}

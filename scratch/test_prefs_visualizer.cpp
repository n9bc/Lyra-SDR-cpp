// Offline test for the audio-visualizer preferences on lyra::ui::Prefs
// (src/prefs.h) — defaults, clamping on set, clamping of a corrupt stored
// value on load, persistence round-trip, and NOTIFY signals.
//   build: cmake --build build --target test_prefs_visualizer
//   run:   build/test_prefs_visualizer
//
// Never touches the operator's real settings: QSettings is redirected to an
// INI file in a throw-away temp directory (and a private org/app name).
#include "prefs.h"

#include <QCoreApplication>
#include <QSettings>
#include <QTemporaryDir>

#include <cstdio>

using lyra::ui::Prefs;

static int g_failures = 0;

static void check(const char *name, int got, int want)
{
    const bool ok = got == want;
    std::printf("  %-44s got=%-6d want=%-6d %s\n", name, got, want,
                ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

static void clearVis()
{
    QSettings s;
    s.beginGroup("visualizer");
    s.remove("");
    s.endGroup();
    s.sync();
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName("LyraTest-Vis");
    QCoreApplication::setApplicationName("LyraTest-Vis");

    QTemporaryDir tmp;
    if (!tmp.isValid()) { std::printf("no temp dir\n"); return 2; }
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, tmp.path());
    QSettings::setPath(QSettings::IniFormat, QSettings::SystemScope, tmp.path());

    std::printf("test_prefs_visualizer\n");
    clearVis();

    // --- defaults -------------------------------------------------------
    {
        Prefs p;
        check("default visView",        p.visView(),        3);
        check("default visPeakHold",    p.visPeakHold(),    1);
        check("default visPalette",     p.visPalette(),     0);
        check("default visEcho",        p.visEcho(),        40);
        check("default visGlow",        p.visGlow(),        50);
        check("default visBgOpacity",   p.visBgOpacity(),   0);
        check("default visAttack",      p.visAttack(),      70);
        check("default visDecay",       p.visDecay(),       12);
        check("default visSmoothing",   p.visSmoothing(),   30);
        check("default visPeakHoldMs",  p.visPeakHoldMs(),  800);
        check("default visSensitivity", p.visSensitivity(), 100);
        check("default visFloorDb",     p.visFloorDb(),     -90);

        // --- clamping on set (high and low) -----------------------------
        p.setVisView(99);        check("set visView 99 -> 3",         p.visView(), 3);
        p.setVisView(-5);        check("set visView -5 -> 0",         p.visView(), 0);
        p.setVisPalette(50);     check("set visPalette 50 -> 8",      p.visPalette(), 8);
        p.setVisPalette(-1);     check("set visPalette -1 -> 0",      p.visPalette(), 0);
        p.setVisEcho(500);       check("set visEcho 500 -> 95",       p.visEcho(), 95);
        p.setVisEcho(-3);        check("set visEcho -3 -> 0",         p.visEcho(), 0);
        p.setVisGlow(500);       check("set visGlow 500 -> 100",      p.visGlow(), 100);
        p.setVisGlow(-3);        check("set visGlow -3 -> 0",         p.visGlow(), 0);
        p.setVisBgOpacity(500);  check("set visBgOpacity 500 -> 100", p.visBgOpacity(), 100);
        p.setVisBgOpacity(-3);   check("set visBgOpacity -3 -> 0",    p.visBgOpacity(), 0);
        p.setVisAttack(500);     check("set visAttack 500 -> 100",    p.visAttack(), 100);
        p.setVisAttack(1);       check("set visAttack 1 -> 5",        p.visAttack(), 5);
        p.setVisDecay(500);      check("set visDecay 500 -> 60",      p.visDecay(), 60);
        p.setVisDecay(0);        check("set visDecay 0 -> 1",         p.visDecay(), 1);
        p.setVisSmoothing(500);  check("set visSmoothing 500 -> 90",  p.visSmoothing(), 90);
        p.setVisSmoothing(-3);   check("set visSmoothing -3 -> 0",    p.visSmoothing(), 0);
        p.setVisPeakHoldMs(9999);check("set visPeakHoldMs 9999 -> 3000", p.visPeakHoldMs(), 3000);
        p.setVisPeakHoldMs(-3);  check("set visPeakHoldMs -3 -> 0",   p.visPeakHoldMs(), 0);
        p.setVisSensitivity(999);check("set visSensitivity 999 -> 300", p.visSensitivity(), 300);
        p.setVisSensitivity(5);  check("set visSensitivity 5 -> 20",  p.visSensitivity(), 20);
        p.setVisFloorDb(-10);    check("set visFloorDb -10 -> -40",   p.visFloorDb(), -40);
        p.setVisFloorDb(-500);   check("set visFloorDb -500 -> -120", p.visFloorDb(), -120);

        // --- NOTIFY fires on change only -------------------------------
        int echoSignals = 0, viewSignals = 0, peakSignals = 0;
        QObject::connect(&p, &Prefs::visEchoChanged, [&] { ++echoSignals; });
        QObject::connect(&p, &Prefs::visViewChanged, [&] { ++viewSignals; });
        QObject::connect(&p, &Prefs::visPeakHoldChanged, [&] { ++peakSignals; });
        p.setVisEcho(60);  p.setVisEcho(60);
        check("visEchoChanged fires once", echoSignals, 1);
        p.setVisView(2);   p.setVisView(2);
        check("visViewChanged fires once", viewSignals, 1);
        p.setVisPeakHold(false); p.setVisPeakHold(false);
        check("visPeakHoldChanged fires once", peakSignals, 1);

        // Leave known values behind for the round-trip below.
        p.setVisView(1);        p.setVisPeakHold(false);  p.setVisPalette(5);
        p.setVisEcho(77);       p.setVisGlow(11);         p.setVisBgOpacity(22);
        p.setVisAttack(33);     p.setVisDecay(44);        p.setVisSmoothing(55);
        p.setVisPeakHoldMs(1234); p.setVisSensitivity(150); p.setVisFloorDb(-60);
    }

    // --- persistence round-trip -----------------------------------------
    {
        Prefs p;
        check("reload visView",        p.visView(),        1);
        check("reload visPeakHold",    p.visPeakHold(),    0);
        check("reload visPalette",     p.visPalette(),     5);
        check("reload visEcho",        p.visEcho(),        77);
        check("reload visGlow",        p.visGlow(),        11);
        check("reload visBgOpacity",   p.visBgOpacity(),   22);
        check("reload visAttack",      p.visAttack(),      33);
        check("reload visDecay",       p.visDecay(),       44);
        check("reload visSmoothing",   p.visSmoothing(),   55);
        check("reload visPeakHoldMs",  p.visPeakHoldMs(),  1234);
        check("reload visSensitivity", p.visSensitivity(), 150);
        check("reload visFloorDb",     p.visFloorDb(),     -60);
    }

    // --- corrupt stored values load clamped (Review Focus 5) ------------
    {
        QSettings s;
        s.setValue("visualizer/view",        99);
        s.setValue("visualizer/palette",     -4);
        s.setValue("visualizer/echo",        500);
        s.setValue("visualizer/glow",        -1);
        s.setValue("visualizer/bgOpacity",   101);
        s.setValue("visualizer/attack",      0);
        s.setValue("visualizer/decay",       999);
        s.setValue("visualizer/smoothing",   1000);
        s.setValue("visualizer/peakHoldMs",  -50);
        s.setValue("visualizer/sensitivity", 5000);
        s.setValue("visualizer/floorDb",     -10);
        s.sync();
        Prefs p;
        check("corrupt view -> 3",          p.visView(),        3);
        check("corrupt palette -> 0",       p.visPalette(),     0);
        check("corrupt echo -> 95",         p.visEcho(),        95);
        check("corrupt glow -> 0",          p.visGlow(),        0);
        check("corrupt bgOpacity -> 100",   p.visBgOpacity(),   100);
        check("corrupt attack -> 5",        p.visAttack(),      5);
        check("corrupt decay 999 -> 60",    p.visDecay(),       60);
        check("corrupt smoothing -> 90",    p.visSmoothing(),   90);
        check("corrupt peakHoldMs -> 0",    p.visPeakHoldMs(),  0);
        check("corrupt sensitivity -> 300", p.visSensitivity(), 300);
        check("corrupt floorDb -10 -> -40", p.visFloorDb(),     -40);
    }

    clearVis();
    std::printf(g_failures ? "FAILED (%d)\n" : "ALL PASS\n", g_failures);
    return g_failures ? 1 : 0;
}

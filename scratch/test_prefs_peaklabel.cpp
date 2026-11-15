// Offline test for the panadapter peak-label preferences on lyra::ui::Prefs
// (src/prefs.h): the new peakShowAudioHz toggle — default, persistence
// round-trip, corrupt-value load, NOTIFY-once, and that it is independent of
// the existing peakShowDb toggle.
//   build: cmake --build build --target test_prefs_peaklabel
//   run:   build/test_prefs_peaklabel
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

static void clearPan()
{
    QSettings s;
    s.beginGroup("panadapter");
    s.remove("");
    s.endGroup();
    s.sync();
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName("LyraTest-PeakLabel");
    QCoreApplication::setApplicationName("LyraTest-PeakLabel");

    QTemporaryDir tmp;
    if (!tmp.isValid()) { std::printf("no temp dir\n"); return 2; }
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, tmp.path());
    QSettings::setPath(QSettings::IniFormat, QSettings::SystemScope, tmp.path());

    std::printf("test_prefs_peaklabel\n");
    clearPan();

    // --- default --------------------------------------------------------
    {
        Prefs p;
        check("default peakShowAudioHz -> false", p.peakShowAudioHz(), 0);
        check("default peakShowDb -> false",      p.peakShowDb(),      0);

        // NOTIFY fires once per real change; the two toggles are independent.
        int hzSignals = 0, dbSignals = 0;
        QObject::connect(&p, &Prefs::peakShowAudioHzChanged, [&] { ++hzSignals; });
        QObject::connect(&p, &Prefs::peakShowDbChanged,      [&] { ++dbSignals; });
        p.setPeakShowAudioHz(true); p.setPeakShowAudioHz(true);
        check("peakShowAudioHzChanged fires once", hzSignals, 1);
        check("setting Hz left Db untouched",       dbSignals, 0);
        check("peakShowAudioHz now true",           p.peakShowAudioHz(), 1);
        check("peakShowDb still false",             p.peakShowDb(),      0);
    }

    // --- persistence round-trip -----------------------------------------
    {
        Prefs p;
        check("reload peakShowAudioHz -> true", p.peakShowAudioHz(), 1);
        check("reload peakShowDb -> false",     p.peakShowDb(),      0);
    }

    // --- corrupt stored value loads as false (Review Focus) -------------
    {
        QSettings s;
        s.setValue("panadapter/peakShowAudioHz", "xyz");
        s.sync();
        Prefs p;
        // QVariant("xyz").toBool() is true, so a bare toBool() would NOT
        // clamp; the loader must treat a non-bool/garbage value as the
        // default false.
        check("corrupt peakShowAudioHz -> false", p.peakShowAudioHz(), 0);
    }

    clearPan();
    std::printf(g_failures ? "FAILED (%d)\n" : "ALL PASS\n", g_failures);
    return g_failures ? 1 : 0;
}

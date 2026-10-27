// Offline test for the eSSB Coach report + advice wording (src/essbcoachreport).
//   build: cmake --build build --target test_essb_report
//   run:   build/test_essb_report
#include "essbcoachreport.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include <algorithm>
#include <cmath>
#include <cstdio>

using namespace lyra::coachreport;
using namespace lyra::dsp::coach;

namespace {

int g_failures = 0;

void check(const char *name, bool ok, double got = 0.0)
{
    std::printf("  %-58s got=%9.3f  %s\n", name, got, ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

ReportInput synthetic()
{
    ReportInput in;
    in.recording = QStringLiteral("baseline");
    in.createdUtc = QStringLiteral("2026-10-26T12:00:00Z");
    in.freqHz = 7200000;
    in.target = builtinTargets().front();
    in.snap.bands = makeBands();
    const size_t n = in.snap.bands.centreHz.size();
    for (size_t k = 0; k < n; ++k) {
        in.snap.baselineDb.push_back(0.1234567891234 * double(k) - 3.25);
        in.snap.liveDb.push_back(-1.0);
    }
    in.snap.baseline = AvgState::Stopped;
    in.snap.speechSec = 12.5;
    in.snap.medianSnrDb = 24.0;
    in.snap.comp.gapToSpeechDb = 30.0;
    in.snap.comp.crestDb = NAN;   // not measured -> null
    in.rx.rxLowHz = 100;
    in.rx.rxHighHz = 7000;
    in.rx.agcMode = "med";
    in.rx.mode = "USB";
    in.edges.lowHz = 100;
    in.edges.highHz = 4000;
    in.edges.tier = "midfi";
    in.zones = defaultZones(in.target.highEdgeHz);
    Finding f;
    f.kind = FindingKind::ToneHeavy;
    f.zone = ZoneId::Bass;
    f.hz = 80;
    f.db = 6;
    f.value = 6.2;
    f.value2 = 5;
    in.findings.push_back(f);
    Finding g;
    g.kind = FindingKind::Splatter;
    g.db = 30;
    g.value = -20;
    g.value2 = -50;
    in.findings.push_back(g);
    in.findingText = {QStringLiteral("t1"), QStringLiteral("t2")};
    in.zoneDeltas = {{ZoneId::Bass, -4.0}};
    in.agcCorrected = true;
    return in;
}

const char *kKeys[] = {"version", "promoted", "app", "recording", "createdUtc", "freqHz", "adviceFor",
                       "target", "targetId", "bandsHz", "baselineDb", "recheckDb", "targetDb",
                       "tolDb", "speechSec", "snrDb", "bandSnrDb", "edges", "zones",
                       "zoneDeltas", "compression", "splatter", "conditions", "thresholds",
                       "findings", "source"};

void testVersion()
{
    std::printf("report_version\n");
    const QJsonObject r = buildReport(synthetic());
    check("version == 1", r.value("version").toInt() == 1);
    bool all = true;
    for (const char *k : kKeys) {
        if (!r.contains(QLatin1String(k))) {
            std::printf("    missing key %s\n", k);
            all = false;
        }
    }
    check("every schema key present", all);
    check("conditions.agcCorrected recorded",
          r.value("conditions").toObject().value("agcCorrected").toBool());
    check("NaN crest serialises as null",
          r.value("compression").toObject().value("crestDb").isNull());
    check("zone Bass present", r.value("zones").toArray().size() == 5);
}

void testRoundtrip()
{
    std::printf("report_roundtrip\n");
    const ReportInput in = synthetic();
    const QJsonObject r = buildReport(in);
    const QByteArray bytes = QJsonDocument(r).toJson(QJsonDocument::Compact);
    const QJsonObject back = QJsonDocument::fromJson(bytes).object();
    const QJsonArray a = back.value("baselineDb").toArray();
    bool sizeOk = a.size() == int(in.snap.baselineDb.size());
    double worst = 0.0;
    for (int k = 0; sizeOk && k < a.size(); ++k)
        worst = std::max(worst, std::fabs(a[k].toDouble() - in.snap.baselineDb[size_t(k)]));
    check("baselineDb size", sizeOk, a.size());
    check("baselineDb round-trips within 1e-6", sizeOk && worst < 1e-6, worst);
    check("recheckDb empty array", back.value("recheckDb").toArray().isEmpty());
    check("freqHz", back.value("freqHz").toDouble() == 7200000.0);
}

void testFindings()
{
    std::printf("report_findings_typed\n");
    const QJsonObject r = buildReport(synthetic());
    const QJsonArray fs = r.value("findings").toArray();
    check("two findings", fs.size() == 2, fs.size());
    const QJsonObject a = fs[0].toObject();
    check("kind is a string", a.value("kind").isString() && a.value("kind").toString() == "ToneHeavy");
    check("zone is a string", a.value("zone").isString() && a.value("zone").toString() == "bass");
    check("hz is a number", a.value("hz").isDouble() && a.value("hz").toDouble() == 80.0);
    check("db is a number", a.value("db").isDouble() && a.value("db").toDouble() == 6.0);
    check("control names TX EQ", a.value("control").toString() == "TX EQ");
    check("text carried", a.value("text").toString() == "t1");
    check("second finding kind", fs[1].toObject().value("kind").toString() == "Splatter");
}

void testWithheldAndNulls()
{
    std::printf("report_withheld_and_nulls\n");
    ReportInput in = synthetic();
    in.snap.comp.gapRiseDb = 4.0;
    in.snap.comp.crestDb = 12.0;
    in.snap.comp.pauses = 3;
    in.agcFallback = true;
    Finding nr;
    nr.kind = FindingKind::NrOn;
    in.findings.push_back(nr);
    Finding rf;
    rf.kind = FindingKind::RxFilterTooNarrow;
    rf.zone = ZoneId::Top;
    rf.value = 4000;
    rf.value2 = 8000;
    in.findings.push_back(rf);
    in.splatterStatus = QStringLiteral("measured");
    in.splatterShiftHz = 0.0;
    in.splatterUsb = false;
    in.splatterEdgeHz = 6000.0;
    const QJsonObject r = buildReport(in);
    const QJsonObject cm = r.value("compression").toObject();
    check("agcFallback: gapToSpeechDb null", cm.value("gapToSpeechDb").isNull());
    check("agcFallback: gapRiseDb null", cm.value("gapRiseDb").isNull());
    check("agcFallback: crestDb null", cm.value("crestDb").isNull());
    check("agcFallback: pauses still counted", cm.value("pauses").toInt() == 3);
    check("agcFallback recorded", r.value("conditions").toObject().value("agcFallback").toBool());
    const QJsonArray fs = r.value("findings").toArray();
    const QJsonObject sp = fs[1].toObject();
    check("Splatter: hz null, zone null", sp.value("hz").isNull() && sp.value("zone").isNull());
    check("Splatter: db and values numbers", sp.value("db").toDouble() == 30.0
                                                 && sp.value("value").toDouble() == -20.0);
    const QJsonObject n = fs[2].toObject();
    check("NrOn: every numeric field null",
          n.value("hz").isNull() && n.value("db").isNull() && n.value("value").isNull()
              && n.value("value2").isNull() && n.value("zone").isNull());
    const QJsonObject w = fs[3].toObject();
    check("RxFilterTooNarrow: zone top, hz/db null, widths",
          w.value("zone").toString() == "top" && w.value("hz").isNull() && w.value("db").isNull()
              && w.value("value").toDouble() == 4000.0 && w.value("value2").toDouble() == 8000.0);
    const QJsonObject s = r.value("splatter").toObject();
    check("splatter channel recorded",
          s.value("status").toString() == "measured" && s.value("shiftHz").toDouble() == 0.0
              && s.value("sideband").toString() == "lsb" && s.value("edgeHz").toDouble() == 6000.0);
    in.agcFallback = false;
    check("no fallback: crest written",
          buildReport(in).value("compression").toObject().value("crestDb").toDouble() == 12.0);
    ReportInput fresh = synthetic();
    check("no channel yet: shiftHz/edgeHz null",
          buildReport(fresh).value("splatter").toObject().value("shiftHz").isNull()
              && buildReport(fresh).value("splatter").toObject().value("edgeHz").isNull());
}

void testZones()
{
    std::printf("report_zones\n");
    ReportInput in = synthetic();
    // Flat curve +4 dB over a flat region: Body zone (600-2000) deviation = +4
    // against the essb target (0 dB above 150 Hz).
    for (size_t k = 0; k < in.snap.baselineDb.size(); ++k) in.snap.baselineDb[k] = 4.0;
    const auto dev = zoneDeviations(in.snap, in.snap.baselineDb, in.target, in.zones, in.rx);
    double body = NAN;
    for (const auto &d : dev) if (d.zone == ZoneId::Body) body = d.deviationDb;
    check("Body deviation +4 dB", std::fabs(body - 4.0) < 1e-9, body);
    // RX filter 300 Hz low: Bass bands (60-150) are all outside -> no deviation.
    RxConditions narrow = in.rx;
    narrow.rxLowHz = 300;
    const auto dev2 = zoneDeviations(in.snap, in.snap.baselineDb, in.target, in.zones, narrow);
    double bass = 0.0;
    for (const auto &d : dev2) if (d.zone == ZoneId::Bass) bass = d.deviationDb;
    check("Bass masked by narrow RX filter", std::isnan(bass));
}

void testAdvice()
{
    std::printf("advice_text\n");
    AdviceContext c;
    c.target = builtinTargets().front();
    c.speechSec = 30;
    c.snrDb = 30;
    Finding f;
    f.kind = FindingKind::ToneHeavy;
    f.hz = 80;
    f.db = 6;
    const QString lyra = adviceText(f, c);
    check("Lyra tone wording",
          lyra == QString::fromUtf8("About 6 dB heavy around 80 Hz. TX EQ, the band nearest 80 Hz: about \xe2\x88\x92" "6 dB."));
    c.lyra = false;
    check("other-rig tone wording", adviceText(f, c) == "About 6 dB heavy around 80 Hz. Cut there.");
    c.lyra = true;
    c.speechSec = 10;   // moderate confidence -> +-1 dB range
    check("moderate confidence shows a range",
          adviceText(f, c).startsWith(QString::fromUtf8("About 5\xe2\x80\x93" "7 dB heavy")));
    Finding t;
    t.kind = FindingKind::ToneThin;
    t.hz = 3000;
    t.db = -4;
    c.speechSec = 30;
    check("thin lifts", adviceText(t, c).contains("about +4 dB"));
    c.speechSec = 10;
    check("range only in the deviation, EQ move is one value",
          adviceText(f, c).contains(QString::fromUtf8("about \xe2\x88\x92" "6 dB.")));
    c.speechSec = 30;
    Finding w;
    w.kind = FindingKind::SignalTooWeak;
    w.value = NAN;
    check("NaN SNR has wording", !adviceText(w, c).contains("nan"));
    Finding n;
    n.kind = FindingKind::NeedMoreSpeech;
    n.value = 5.2;
    n.value2 = 8;
    check("need more speech", adviceText(n, c) == "Need more speech (5 s of 8).");
    check("moderate rule", moderateConfidence(10, 30) && moderateConfidence(30, 10)
                           && !moderateConfidence(30, 30) && moderateConfidence(30, NAN));
}

void testSource()
{
    std::printf("report_source_field\n");
    const QJsonObject rx = buildReport(synthetic());
    check("default source is \"rx\"", rx.value("source").toString() == "rx");
    ReportInput in = synthetic();
    in.source = QStringLiteral("practice");
    const QJsonObject pr = buildReport(in);
    check("source \"practice\" written", pr.value("source").toString() == "practice");
    check("practice report keeps version 1", pr.value("version").toInt() == 1);
    const QByteArray js = QJsonDocument(pr).toJson(QJsonDocument::Compact);
    check("JSON has \"source\":\"practice\"", js.contains("\"source\":\"practice\""));
    // writePracticeReport's shape: A in the baseline slot, B in the re-check
    // slot, labelled "recheck"; the recording's own fields follow B.
    ReportInput ab = synthetic();
    ab.source = QStringLiteral("practice");
    ab.recording = QStringLiteral("recheck");
    ab.snap.recheckDb = ab.snap.baselineDb;
    for (double &v : ab.snap.recheckDb) v += 1.0;
    ab.snap.recheck = AvgState::Stopped;
    ab.snap.recheckSpeechSec = 20.0;
    const QJsonObject pab = buildReport(ab);
    check("practice A/B: both curves written",
          pab.value("baselineDb").toArray().size() == int(ab.snap.baselineDb.size())
              && pab.value("recheckDb").toArray().size() == int(ab.snap.recheckDb.size()));
    check("practice A/B: recording recheck, speechSec from B",
          pab.value("recording").toString() == "recheck" && pab.value("speechSec").toDouble() == 20.0,
          pab.value("speechSec").toDouble());
}

}  // namespace

int main()
{
    testVersion();
    testRoundtrip();
    testFindings();
    testWithheldAndNulls();
    testZones();
    testAdvice();
    testSource();
    std::printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures,
                g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}

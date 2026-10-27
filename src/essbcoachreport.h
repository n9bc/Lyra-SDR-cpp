// eSSB Coach — advice wording and the measurement report (schema in
// docs/essb-coach-report.md).  Free functions, Qt Core only, no GUI /
// WdspEngine dependency, so scratch/test_essb_report.cpp links them
// directly; EssbCoachModel (essbcoachmodel.h) is the thin QObject on top.
#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <utility>
#include <vector>

#include "dsp/coach/CoachAdvisor.h"
#include "dsp/coach/CoachAnalyzer.h"
#include "dsp/coach/CoachEnvelope.h"
#include "dsp/coach/CoachTarget.h"
#include "dsp/coach/SplatterMeter.h"

namespace lyra::coachreport {

inline constexpr int kReportVersion = 1;

// Stable machine keys (the report uses them; the QML zoneDeltas use zoneKey).
QString zoneKey(dsp::coach::ZoneId z);               // bass, lowMid, body, upper, top
QString zoneLabel(dsp::coach::ZoneId z);             // translated, for the panel
QString kindKey(dsp::coach::FindingKind k);          // ToneHeavy, Pumping, ...
// The Lyra control a finding points at ("" = none), for the phase-2 AI step.
QString controlFor(dsp::coach::FindingKind k);

// The speech-seconds / SNR below which a deviation is shown as a +-1 dB range.
bool moderateConfidence(double speechSec, double snrDb);

struct AdviceContext {
    bool lyra = true;                  // false = other-rig wording
    dsp::coach::Target target;         // the target in use (name for Bandwidth)
    dsp::coach::Edges edges;           // measured edges (Bandwidth)
    double speechSec = NAN;            // for the +-1 dB range
    double snrDb = NAN;
};

// One finding as a sentence (translated; Lyra mode names the control).
QString adviceText(const dsp::coach::Finding &f, const AdviceContext &c);
// "Hold AF gain and squelch steady while measuring" (post-AGC level changes
// are not removed by the AGC correction).
QString holdSteadyNote();
// "110 Hz - 4100 Hz (Mid-fi)", "" when no edges.
QString edgesText(const dsp::coach::Edges &e);

struct ZoneDeviation {
    dsp::coach::ZoneId zone{};
    double loHz = 0, hiHz = 0;
    double deviationDb = NAN;          // mean(curve - target) over usable bands; NaN = none usable
    double toleranceDb = 0;
};
// Same band rule as CoachAdvisor::evaluate: only bands wholly inside the RX
// passband (half a 1/6-octave band of margin).
std::vector<ZoneDeviation> zoneDeviations(const dsp::coach::CoachSnapshot &s,
                                          const std::vector<double> &curve,
                                          const dsp::coach::Target &target,
                                          const std::vector<dsp::coach::Zone> &zones,
                                          const dsp::coach::RxConditions &rx);

struct ReportInput {
    QString recording = QStringLiteral("baseline");   // "baseline" | "recheck"
    QString createdUtc;                               // ISO-8601, UTC
    qint64 freqHz = 0;
    dsp::coach::Target target;
    dsp::coach::CoachSnapshot snap;
    dsp::coach::SplatterResult splatter;              // as the panel showed it (blank unless measured/pending)
    QString splatterStatus = QStringLiteral("pending");   // measured | pending | stale | am | practice
    double splatterShiftHz = NAN;                     // channel handed to the meter; NaN = none yet
    bool splatterUsb = true;
    double splatterEdgeHz = NAN;
    dsp::coach::RxConditions rx;
    dsp::coach::Edges edges;
    std::vector<dsp::coach::Zone> zones;
    dsp::coach::CoachThresholds thresholds;
    std::vector<dsp::coach::Finding> findings;
    std::vector<QString> findingText;                 // parallel to findings; may be shorter
    std::vector<std::pair<dsp::coach::ZoneId, double>> zoneDeltas;
    bool agcCorrected = false;                        // was AGC correction in effect?
    // true = AGC correction was not applied, so the compression readings were
    // withheld (AGC on without correction, or AGC Off with a post-AGC stage of
    // unknown delay); buildReport then writes them as null.
    bool agcFallback = false;
    bool promoted = false;                            // baseline was replaced via Make baseline
    bool lyraAdvice = true;
    // What the coach measured: "rx" (RX1 audio, the other station) or
    // "practice" (our own clip after the TX rack, eSSB practice loop).
    QString source = QStringLiteral("rx");
};

// Version-1 report (docs/essb-coach-report.md).  NaN values become null, and
// so do withheld readings and finding fields the kind does not use.
QJsonObject buildReport(const ReportInput &in);

}  // namespace lyra::coachreport

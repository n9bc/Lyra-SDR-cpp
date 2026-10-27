// eSSB Coach — advice wording and the measurement report.  See essbcoachreport.h.

#include "essbcoachreport.h"

#include <QCoreApplication>
#include <QJsonArray>

#include <algorithm>
#include <cmath>

using namespace lyra::dsp::coach;

namespace lyra::coachreport {

namespace {

QString tr(const char *s) { return QCoreApplication::translate("EssbCoach", s); }

// "Lyra wording|other-rig wording" -> the half the mode wants.  A template
// without '|' is the same in both modes.
QString pick(const char *tmpl, bool lyra)
{
    const QString t = tr(tmpl);
    const int bar = t.indexOf(QLatin1Char('|'));
    if (bar < 0) return t;
    return lyra ? t.left(bar) : t.mid(bar + 1);
}

QJsonValue num(double v)
{
    return std::isfinite(v) ? QJsonValue(v) : QJsonValue(QJsonValue::Null);
}

QJsonArray numArray(const std::vector<double> &v)
{
    QJsonArray a;
    for (double x : v) a.append(num(x));
    return a;
}

QString kHz(double hz) { return QString::number(hz / 1000.0, 'f', 1); }

// "5" or, at moderate confidence, "4-6" (+-1 dB).
QString dbText(double absDb, bool range)
{
    const int v = static_cast<int>(std::lround(absDb));
    if (!range) return QString::number(v);
    return QStringLiteral("%1–%2").arg(std::max(0, v - 1)).arg(v + 1);
}

// The first %1 is the deviation (a +-1 dB range at moderate confidence); any
// later %1 is the EQ move, a single rounded value so it stays unambiguous.
QString toneText(QString t, const Finding &f, bool range)
{
    const double a = std::fabs(f.db);
    const int at = t.indexOf(QStringLiteral("%1"));
    if (at >= 0) t.replace(at, 2, dbText(a, range));
    t.replace(QStringLiteral("%1"), dbText(a, false));
    t.replace(QStringLiteral("%2"), QString::number(std::lround(f.hz)));
    return t;
}

QString tierName(const std::string &id)
{
    for (const Target &t : builtinTargets())
        if (t.id == id) return QString::fromStdString(t.name);
    return QString::fromStdString(id);
}

}  // namespace

QString zoneKey(ZoneId z)
{
    switch (z) {
    case ZoneId::Bass:   return QStringLiteral("bass");
    case ZoneId::LowMid: return QStringLiteral("lowMid");
    case ZoneId::Body:   return QStringLiteral("body");
    case ZoneId::Upper:  return QStringLiteral("upper");
    case ZoneId::Top:    return QStringLiteral("top");
    }
    return QString();
}

QString zoneLabel(ZoneId z)
{
    switch (z) {
    case ZoneId::Bass:   return tr("Bass");
    case ZoneId::LowMid: return tr("Low-mid");
    case ZoneId::Body:   return tr("Body");
    case ZoneId::Upper:  return tr("Upper");
    case ZoneId::Top:    return tr("Top");
    }
    return QString();
}

QString kindKey(FindingKind k)
{
    switch (k) {
    case FindingKind::RxFilterTooNarrow: return QStringLiteral("RxFilterTooNarrow");
    case FindingKind::NrOn:              return QStringLiteral("NrOn");
    case FindingKind::AnfOn:             return QStringLiteral("AnfOn");
    case FindingKind::NotVoiceMode:      return QStringLiteral("NotVoiceMode");
    case FindingKind::NeedMoreSpeech:    return QStringLiteral("NeedMoreSpeech");
    case FindingKind::SignalTooWeak:     return QStringLiteral("SignalTooWeak");
    case FindingKind::Bandwidth:         return QStringLiteral("Bandwidth");
    case FindingKind::ToneHeavy:         return QStringLiteral("ToneHeavy");
    case FindingKind::ToneThin:          return QStringLiteral("ToneThin");
    case FindingKind::NoiseBetweenWords: return QStringLiteral("NoiseBetweenWords");
    case FindingKind::Pumping:           return QStringLiteral("Pumping");
    case FindingKind::Squashed:          return QStringLiteral("Squashed");
    case FindingKind::Splatter:          return QStringLiteral("Splatter");
    }
    return QString();
}

QString controlFor(FindingKind k)
{
    switch (k) {
    case FindingKind::ToneHeavy:
    case FindingKind::ToneThin:
    case FindingKind::Bandwidth:         return QStringLiteral("TX EQ");
    case FindingKind::NoiseBetweenWords: return QStringLiteral("Noise Gate / Auto-AGC");
    case FindingKind::Pumping:
    case FindingKind::Squashed:          return QStringLiteral("Combinator");
    default:                             return QString();
    }
}

bool moderateConfidence(double speechSec, double snrDb)
{
    // NaN counts as low (advisor withholds advice then); this is only the
    // "enough to advise, not enough to be exact" band.
    return !(speechSec >= 20.0) || !(snrDb >= 20.0);
}

QString adviceText(const Finding &f, const AdviceContext &c)
{
    const bool range = moderateConfidence(c.speechSec, c.snrDb);
    switch (f.kind) {
    case FindingKind::ToneHeavy:
        return toneText(pick("About %1 dB heavy around %2 Hz. TX EQ, the band nearest %2 Hz: about \u2212%1 dB."
                             "|About %1 dB heavy around %2 Hz. Cut there.", c.lyra), f, range);
    case FindingKind::ToneThin:
        return toneText(pick("About %1 dB thin around %2 Hz. TX EQ, the band nearest %2 Hz: about +%1 dB."
                             "|About %1 dB thin around %2 Hz. Lift there.", c.lyra), f, range);
    case FindingKind::Bandwidth:
        return tr("Low edge %1 Hz, high edge %2 Hz. That's %3. Target is %4.")
            .arg(std::lround(f.value))
            .arg(std::lround(f.value2))
            .arg(tierName(c.edges.tier))
            .arg(QString::fromStdString(c.target.name));
    case FindingKind::NoiseBetweenWords:
        return pick("Background noise is coming up between words. Noise Gate: raise Thresh about 5 dB, or lower Auto-AGC Max gain."
                    "|Background noise is coming up between words. Add a noise gate, or use less compression.",
                    c.lyra);
    case FindingKind::Pumping:
        return pick("Level climbs back after each word (pumping). Combinator: slower Release or lower Ratio."
                    "|Level climbs back after each word (pumping). Try a slower release or a lower ratio.",
                    c.lyra);
    case FindingKind::Squashed:
        return pick("Peaks barely rise above the average (over-compressed). Combinator: lower Ratio or Mix."
                    "|Peaks barely rise above the average (over-compressed). Use less compression.",
                    c.lyra);
    case FindingKind::RxFilterTooNarrow:
        // zone Bass = the low edge of the RX filter is too high, Top = the
        // high edge is too low (value = RX edge, value2 = what is wanted).
        if (f.zone == ZoneId::Bass)
            return tr("Your RX filter starts at %1 Hz, too high to judge this target. Lower it to %2 Hz or less.")
                .arg(std::lround(f.value)).arg(std::lround(f.value2));
        return tr("Your RX filter is %1 kHz, too narrow to judge this target. Widen it to %2 kHz or more.")
            .arg(kHz(f.value), kHz(f.value2));
    case FindingKind::NrOn:
        return tr("NR is on. Turn it off for a fair reading.");
    case FindingKind::AnfOn:
        return tr("ANF is on. Turn it off for a fair reading.");
    case FindingKind::NotVoiceMode:
        return tr("Not a voice SSB mode. Switch to USB or LSB.");
    case FindingKind::NeedMoreSpeech:
        return tr("Need more speech (%1 s of %2).")
            .arg(std::lround(f.value)).arg(std::lround(f.value2));
    case FindingKind::SignalTooWeak:
        if (!std::isfinite(f.value)) return tr("Signal too weak (no SNR estimate yet).");
        return tr("Signal too weak (SNR %1 dB).").arg(std::lround(f.value));
    case FindingKind::Splatter:
        return tr("Splatter: energy past the channel edge is only %1 dB below the peak. Check a quiet neighbouring frequency to confirm.")
            .arg(std::lround(f.db));
    }
    return QString();
}

QString holdSteadyNote() { return tr("Hold AF gain and squelch steady while measuring."); }

QString edgesText(const Edges &e)
{
    if (!std::isfinite(e.lowHz) || !std::isfinite(e.highHz)) return QString();
    QString s = tr("%1 Hz – %2 Hz (%3)")
                    .arg(std::lround(e.lowHz)).arg(std::lround(e.highHz))
                    .arg(tierName(e.tier));
    if (e.lowBeyondRx || e.highBeyondRx)
        s += tr(", limited by your RX filter");
    return s;
}

std::vector<ZoneDeviation> zoneDeviations(const CoachSnapshot &s, const std::vector<double> &curve,
                                          const Target &target, const std::vector<Zone> &zones,
                                          const RxConditions &rx)
{
    std::vector<ZoneDeviation> out;
    const size_t n = std::min({curve.size(), s.bands.centreHz.size(), s.bands.loHz.size(),
                               s.bands.hiHz.size()});
    for (const Zone &z : zones) {
        ZoneDeviation d;
        d.zone = z.id;
        d.loHz = z.loHz;
        d.hiHz = z.hiHz;
        d.toleranceDb = toleranceAt(target, 0.5 * (z.loHz + z.hiHz));
        double sum = 0.0;
        int count = 0;
        for (size_t k = 0; k < n; ++k) {
            const double hz = s.bands.centreHz[k];
            if (hz < z.loHz || hz >= z.hiHz) continue;
            if (!CoachAdvisor::bandUsable(s.bands.loHz[k], s.bands.hiHz[k], rx)) continue;
            const double dev = curve[k] - targetDbAt(target, hz);
            if (!std::isfinite(dev)) continue;
            sum += dev;
            ++count;
        }
        if (count > 0) d.deviationDb = sum / count;
        out.push_back(d);
    }
    return out;
}

QJsonObject buildReport(const ReportInput &in)
{
    const bool recheck = in.recording == QLatin1String("recheck");
    const CoachSnapshot &s = in.snap;

    QJsonObject r;
    r[QStringLiteral("version")] = kReportVersion;
    r[QStringLiteral("app")] = QStringLiteral("Lyra eSSB Coach");
    r[QStringLiteral("recording")] = recheck ? QStringLiteral("recheck") : QStringLiteral("baseline");
    r[QStringLiteral("createdUtc")] = in.createdUtc;
    r[QStringLiteral("freqHz")] = static_cast<double>(in.freqHz);
    r[QStringLiteral("promoted")] = in.promoted;
    r[QStringLiteral("adviceFor")] = in.lyraAdvice ? QStringLiteral("lyra") : QStringLiteral("other");
    r[QStringLiteral("source")] = in.source == QLatin1String("practice") ? QStringLiteral("practice")
                                                                         : QStringLiteral("rx");

    QJsonObject tgt;
    tgt[QStringLiteral("id")] = QString::fromStdString(in.target.id);
    tgt[QStringLiteral("name")] = QString::fromStdString(in.target.name);
    tgt[QStringLiteral("builtin")] = in.target.builtin;
    tgt[QStringLiteral("lowEdgeHz")] = num(in.target.lowEdgeHz);
    tgt[QStringLiteral("highEdgeHz")] = num(in.target.highEdgeHz);
    r[QStringLiteral("target")] = tgt;
    r[QStringLiteral("targetId")] = QString::fromStdString(in.target.id);

    // Per-band data: band centres, the two normalised curves (empty = none),
    // and the target + tolerance at each band centre.
    r[QStringLiteral("bandsHz")] = numArray(s.bands.centreHz);
    r[QStringLiteral("baselineDb")] = numArray(s.baselineDb);
    r[QStringLiteral("recheckDb")] = numArray(s.recheckDb);
    std::vector<double> tdb, tol;
    for (double hz : s.bands.centreHz) {
        tdb.push_back(targetDbAt(in.target, hz));
        tol.push_back(toleranceAt(in.target, hz));
    }
    r[QStringLiteral("targetDb")] = numArray(tdb);
    r[QStringLiteral("tolDb")] = numArray(tol);

    // Confidence (this recording's speech; SNR is the baseline's).
    r[QStringLiteral("speechSec")] = num(recheck ? s.recheckSpeechSec : s.speechSec);
    r[QStringLiteral("snrDb")] = num(s.medianSnrDb);
    r[QStringLiteral("bandSnrDb")] = numArray(s.bandSnrDb);

    QJsonObject ed;
    ed[QStringLiteral("lowHz")] = num(in.edges.lowHz);
    ed[QStringLiteral("highHz")] = num(in.edges.highHz);
    ed[QStringLiteral("lowBeyondRx")] = in.edges.lowBeyondRx;
    ed[QStringLiteral("highBeyondRx")] = in.edges.highBeyondRx;
    ed[QStringLiteral("tier")] = QString::fromStdString(in.edges.tier);
    r[QStringLiteral("edges")] = ed;

    // Zones: deviation of the recording's own curve from the target.
    const std::vector<double> &curve = recheck ? s.recheckDb : s.baselineDb;
    QJsonArray zs;
    for (const ZoneDeviation &d : zoneDeviations(s, curve, in.target, in.zones, in.rx)) {
        QJsonObject z;
        z[QStringLiteral("zone")] = zoneKey(d.zone);
        z[QStringLiteral("loHz")] = d.loHz;
        z[QStringLiteral("hiHz")] = d.hiHz;
        z[QStringLiteral("deviationDb")] = num(d.deviationDb);
        z[QStringLiteral("toleranceDb")] = d.toleranceDb;
        zs.append(z);
    }
    r[QStringLiteral("zones")] = zs;

    QJsonArray zd;
    for (const auto &p : in.zoneDeltas) {
        QJsonObject z;
        z[QStringLiteral("zone")] = zoneKey(p.first);
        z[QStringLiteral("db")] = num(p.second);
        zd.append(z);
    }
    r[QStringLiteral("zoneDeltas")] = zd;

    // Withheld (agcFallback) exactly as the panel withholds them: null.
    const CompressionMetrics &m = recheck ? s.recheckComp : s.comp;
    const auto comp = [&](double v) { return in.agcFallback ? QJsonValue(QJsonValue::Null) : num(v); };
    QJsonObject cm;
    cm[QStringLiteral("gapToSpeechDb")] = comp(m.gapToSpeechDb);
    cm[QStringLiteral("gapRiseDb")] = comp(m.gapRiseDb);
    cm[QStringLiteral("crestDb")] = comp(m.crestDb);
    cm[QStringLiteral("pauses")] = m.pauses;
    r[QStringLiteral("compression")] = cm;

    QJsonObject sp;
    sp[QStringLiteral("valid")] = in.splatter.valid;
    sp[QStringLiteral("alert")] = in.splatter.alert;
    sp[QStringLiteral("peakDb")] = num(in.splatter.peakDb);
    sp[QStringLiteral("outDb")] = num(in.splatter.outDb);
    sp[QStringLiteral("marginDb")] = num(in.splatter.marginDb);
    sp[QStringLiteral("noiseDb")] = num(in.splatter.noiseDb);
    sp[QStringLiteral("status")] = in.splatterStatus;
    sp[QStringLiteral("shiftHz")] = num(in.splatterShiftHz);
    sp[QStringLiteral("sideband")] = in.splatterUsb ? QStringLiteral("usb") : QStringLiteral("lsb");
    sp[QStringLiteral("edgeHz")] = num(in.splatterEdgeHz);
    r[QStringLiteral("splatter")] = sp;

    QJsonObject cd;
    cd[QStringLiteral("rxLowHz")] = num(in.rx.rxLowHz);
    cd[QStringLiteral("rxHighHz")] = num(in.rx.rxHighHz);
    cd[QStringLiteral("nrOn")] = in.rx.nrOn;
    cd[QStringLiteral("anfOn")] = in.rx.anfOn;
    cd[QStringLiteral("agcMode")] = QString::fromStdString(in.rx.agcMode);
    cd[QStringLiteral("mode")] = QString::fromStdString(in.rx.mode);
    cd[QStringLiteral("agcCorrected")] = in.agcCorrected;
    cd[QStringLiteral("agcFallback")] = in.agcFallback;
    r[QStringLiteral("conditions")] = cd;

    QJsonObject th;
    th[QStringLiteral("minSpeechSec")] = in.thresholds.minSpeechSec;
    th[QStringLiteral("minSnrDb")] = in.thresholds.minSnrDb;
    th[QStringLiteral("gapToSpeechDb")] = in.thresholds.gapToSpeechDb;
    th[QStringLiteral("gapRiseDb")] = in.thresholds.gapRiseDb;
    th[QStringLiteral("crestDb")] = in.thresholds.crestDb;
    r[QStringLiteral("thresholds")] = th;

    // Fields a kind does not use are null (docs/essb-coach-report.md table).
    QJsonArray fs;
    const QJsonValue null(QJsonValue::Null);
    for (size_t i = 0; i < in.findings.size(); ++i) {
        const Finding &f = in.findings[i];
        const bool tone = f.kind == FindingKind::ToneHeavy || f.kind == FindingKind::ToneThin;
        const bool zoned = tone || f.kind == FindingKind::RxFilterTooNarrow;
        const bool hasDb = tone || f.kind == FindingKind::Splatter;
        const bool noValues = f.kind == FindingKind::NrOn || f.kind == FindingKind::AnfOn
                              || f.kind == FindingKind::NotVoiceMode;
        QJsonObject o;
        o[QStringLiteral("kind")] = kindKey(f.kind);
        o[QStringLiteral("zone")] = zoned ? QJsonValue(zoneKey(f.zone)) : null;
        o[QStringLiteral("hz")] = tone ? num(f.hz) : null;
        o[QStringLiteral("db")] = hasDb ? num(f.db) : null;
        o[QStringLiteral("value")] = noValues ? null : num(f.value);
        o[QStringLiteral("value2")] = noValues ? null : num(f.value2);
        o[QStringLiteral("control")] = controlFor(f.kind);
        o[QStringLiteral("text")] = i < in.findingText.size() ? in.findingText[i] : QString();
        fs.append(o);
    }
    r[QStringLiteral("findings")] = fs;
    return r;
}

}  // namespace lyra::coachreport

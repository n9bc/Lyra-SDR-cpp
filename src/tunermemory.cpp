// Lyra — manual-ATU tuning memory implementation.  See tunermemory.h.

#include "tunermemory.h"

#include "hl2_stream.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>

#include <algorithm>
#include <cmath>

namespace lyra::ui {

namespace {
constexpr int kNumAntennas = 3;
const QString kDefaultNames[kNumAntennas] = {
    QStringLiteral("Beam"), QStringLiteral("Dipole"), QStringLiteral("Vertical")};

// Ham-band edges (Hz) → short label.  HF + 6 m + 4 m; the manual-tuner
// audience is overwhelmingly HF.
struct BandSpan { double lo, hi; const char *label; };
const BandSpan kBands[] = {
    {1'800'000,   2'000'000,   "160 M"}, {3'500'000,   4'000'000,   "80 M"},
    {5'250'000,   5'450'000,   "60 M"},  {7'000'000,   7'300'000,   "40 M"},
    {10'100'000,  10'150'000,  "30 M"},  {14'000'000,  14'350'000,  "20 M"},
    {18'068'000,  18'168'000,  "17 M"},  {21'000'000,  21'450'000,  "15 M"},
    {24'890'000,  24'990'000,  "12 M"},  {26'965'000,  27'405'000,  "11 M"},
    {28'000'000,  29'700'000,  "10 M"},  {50'000'000,  54'000'000,  "6 M"},
    {70'000'000,  70'500'000,  "4 M"},   {144'000'000, 148'000'000, "2 M"},
};
}  // namespace

TunerMemory::TunerMemory(lyra::ipc::HL2Stream *stream, QObject *parent)
    : QObject(parent) {
    ant_.resize(kNumAntennas);
    for (int i = 0; i < kNumAntennas; ++i) ant_[i].name = kDefaultNames[i];
    load();
    if (stream) {
        curHz_ = stream->rx1FreqHz();
        connect(stream, &lyra::ipc::HL2Stream::rx1FreqChanged, this,
                [this, stream]() { setCurrentFreqHz(stream->rx1FreqHz()); });
    }
    recomputeMatch();
}

QStringList TunerMemory::antennaNames() const {
    QStringList out;
    for (const auto &a : ant_) out << a.name;
    return out;
}

void TunerMemory::setActiveAntenna(int i) {
    if (i < 0 || i >= ant_.size() || i == active_) return;
    active_ = i;
    save();
    emit activeChanged();
    emit pointsChanged();
    recomputeMatch();
}

QVariantList TunerMemory::points() const {
    QVariantList out;
    if (active_ < 0 || active_ >= ant_.size()) return out;
    for (const auto &p : ant_[active_].points) {
        QVariantMap m;
        m[QStringLiteral("band")]     = p.band;
        m[QStringLiteral("freqHz")]   = p.freqHz;
        m[QStringLiteral("freqText")] = fmtFreq(p.freqHz);
        m[QStringLiteral("input")]    = p.input;
        m[QStringLiteral("output")]   = p.output;
        m[QStringLiteral("inductor")] = p.inductor;
        m[QStringLiteral("note")]     = p.note;
        out << m;
    }
    return out;
}

bool TunerMemory::matchExact() const {
    return matchIdx_ >= 0 && std::abs(matchDeltaHz()) <= matchToleranceHz_;
}

void TunerMemory::setMatchToleranceHz(double hz) {
    const double v = std::clamp(hz, 50.0, 20000.0);
    if (v == matchToleranceHz_) return;
    matchToleranceHz_ = v;
    save();
    emit matchToleranceChanged();
    emit matchChanged();   // exact/nearest may flip at the new window
}

int TunerMemory::pointCount() const {
    return (active_ >= 0 && active_ < ant_.size()) ? ant_[active_].points.size() : 0;
}

double TunerMemory::matchFreqHz() const {
    if (matchIdx_ < 0) return 0.0;
    return ant_[active_].points[matchIdx_].freqHz;
}

double TunerMemory::matchDeltaHz() const {
    if (matchIdx_ < 0) return 0.0;
    // Stored point RELATIVE TO the current dial: +ve = the saved point is
    // higher in frequency (tune UP to reach it), −ve = lower (tune DOWN).
    // Reads the natural way ("nearest +10 kHz" = saved setting is 10 kHz up).
    return ant_[active_].points[matchIdx_].freqHz - curHz_;
}

QString TunerMemory::matchInput() const {
    return matchIdx_ < 0 ? QString() : ant_[active_].points[matchIdx_].input;
}
QString TunerMemory::matchOutput() const {
    return matchIdx_ < 0 ? QString() : ant_[active_].points[matchIdx_].output;
}
QString TunerMemory::matchInductor() const {
    return matchIdx_ < 0 ? QString() : ant_[active_].points[matchIdx_].inductor;
}
QString TunerMemory::matchNote() const {
    return matchIdx_ < 0 ? QString() : ant_[active_].points[matchIdx_].note;
}

void TunerMemory::setCollapsed(bool v) {
    if (v == collapsed_) return;
    collapsed_ = v;
    save();
    emit collapsedChanged();
}

void TunerMemory::setCurrentFreqHz(double hz) {
    if (hz == curHz_) return;
    curHz_ = hz;
    emit currentChanged();
    recomputeMatch();
}

void TunerMemory::renameAntenna(int i, const QString &name) {
    if (i < 0 || i >= ant_.size()) return;
    const QString n = name.trimmed();
    if (n.isEmpty() || n == ant_[i].name) return;
    ant_[i].name = n;
    save();
    emit antennasChanged();
}

void TunerMemory::storePoint(double freqHz, const QString &input,
                             const QString &output, const QString &inductor,
                             const QString &note) {
    if (active_ < 0 || active_ >= ant_.size()) return;
    auto &pts = ant_[active_].points;
    // Overwrite a point at essentially the same frequency, else insert a new
    // one (kSameFreqHz, NOT the display match window, so distinct nearby
    // points are kept even when the match window is wide).
    int existing = -1;
    for (int i = 0; i < pts.size(); ++i)
        if (std::abs(pts[i].freqHz - freqHz) <= kSameFreqHz) { existing = i; break; }
    Point p{freqHz, bandLabel(freqHz), input.trimmed(), output.trimmed(),
            inductor.trimmed(), note.trimmed()};
    if (existing >= 0) pts[existing] = p;
    else               pts.append(p);
    sortAntenna(active_);
    save();
    emit pointsChanged();
    recomputeMatch();
}

void TunerMemory::updatePoint(int index, const QString &input,
                              const QString &output, const QString &inductor,
                              const QString &note) {
    if (active_ < 0 || active_ >= ant_.size()) return;
    auto &pts = ant_[active_].points;
    if (index < 0 || index >= pts.size()) return;
    pts[index].input    = input.trimmed();
    pts[index].output   = output.trimmed();
    pts[index].inductor = inductor.trimmed();
    pts[index].note     = note.trimmed();
    save();
    emit pointsChanged();
    recomputeMatch();
}

void TunerMemory::editPoint(int index, double freqHz, const QString &input,
                            const QString &output, const QString &inductor,
                            const QString &note) {
    if (active_ < 0 || active_ >= ant_.size()) return;
    auto &pts = ant_[active_].points;
    if (index < 0 || index >= pts.size()) return;
    pts[index].freqHz   = freqHz;
    pts[index].band     = bandLabel(freqHz);
    pts[index].input    = input.trimmed();
    pts[index].output   = output.trimmed();
    pts[index].inductor = inductor.trimmed();
    pts[index].note     = note.trimmed();
    sortAntenna(active_);
    save();
    emit pointsChanged();
    recomputeMatch();
}

void TunerMemory::deletePoint(int index) {
    if (active_ < 0 || active_ >= ant_.size()) return;
    auto &pts = ant_[active_].points;
    if (index < 0 || index >= pts.size()) return;
    pts.removeAt(index);
    save();
    emit pointsChanged();
    recomputeMatch();
}

void TunerMemory::clearActiveAntenna() {
    if (active_ < 0 || active_ >= ant_.size()) return;
    if (ant_[active_].points.isEmpty()) return;
    ant_[active_].points.clear();
    save();
    emit pointsChanged();
    recomputeMatch();
}

void TunerMemory::recomputeMatch() {
    int best = -1;
    double bestDelta = 0.0;
    // Nearest on the dial's own band only: another band's tuner setting is
    // no starting point (a 40 m match offered on 20 m).  Off the ham bands
    // there is no label to compare, so every point counts.
    const QString band = bandLabel(curHz_);
    if (active_ >= 0 && active_ < ant_.size()) {
        const auto &pts = ant_[active_].points;
        for (int i = 0; i < pts.size(); ++i) {
            if (!band.isEmpty() && pts[i].band != band) continue;
            const double d = std::abs(pts[i].freqHz - curHz_);
            if (best < 0 || d < bestDelta) { best = i; bestDelta = d; }
        }
    }
    // Always emit: even when the nearest index is unchanged, the dial moving
    // changes the delta + exact/nearest state the panel renders.
    matchIdx_ = best;
    emit matchChanged();
}

void TunerMemory::sortAntenna(int i) {
    std::sort(ant_[i].points.begin(), ant_[i].points.end(),
              [](const Point &a, const Point &b) { return a.freqHz < b.freqHz; });
}

QString TunerMemory::bandLabel(double freqHz) {
    for (const auto &b : kBands)
        if (freqHz >= b.lo && freqHz <= b.hi) return QString::fromLatin1(b.label);
    return QString();
}

QString TunerMemory::fmtFreq(double freqHz) {
    const qint64 hz = static_cast<qint64>(std::llround(freqHz));
    const qint64 mhz = hz / 1'000'000;
    const qint64 khz = (hz % 1'000'000) / 1000;
    const qint64 rem = hz % 1000;
    return QStringLiteral("%1.%2.%3")
        .arg(mhz)
        .arg(khz, 3, 10, QChar('0'))
        .arg(rem, 3, 10, QChar('0'));
}

// ---- persistence (QSettings; one JSON array of points per antenna) ----

void TunerMemory::save() const {
    QSettings s;
    s.beginGroup(QStringLiteral("tuner"));
    s.setValue(QStringLiteral("active"), active_);
    s.setValue(QStringLiteral("collapsed"), collapsed_);
    s.setValue(QStringLiteral("matchToleranceHz"), matchToleranceHz_);
    for (int i = 0; i < ant_.size(); ++i) {
        s.beginGroup(QStringLiteral("antenna%1").arg(i));
        s.setValue(QStringLiteral("name"), ant_[i].name);
        QJsonArray arr;
        for (const auto &p : ant_[i].points) {
            QJsonObject o;
            o[QStringLiteral("f")]   = p.freqHz;
            o[QStringLiteral("in")]  = p.input;
            o[QStringLiteral("out")] = p.output;
            o[QStringLiteral("ind")] = p.inductor;
            o[QStringLiteral("n")]   = p.note;
            arr.append(o);
        }
        s.setValue(QStringLiteral("points"),
                   QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
        s.endGroup();
    }
    s.endGroup();
}

void TunerMemory::load() {
    QSettings s;
    s.beginGroup(QStringLiteral("tuner"));
    active_    = std::clamp(s.value(QStringLiteral("active"), 0).toInt(), 0, kNumAntennas - 1);
    collapsed_ = s.value(QStringLiteral("collapsed"), false).toBool();
    matchToleranceHz_ = std::clamp(
        s.value(QStringLiteral("matchToleranceHz"), 1000.0).toDouble(), 50.0, 20000.0);
    for (int i = 0; i < ant_.size(); ++i) {
        s.beginGroup(QStringLiteral("antenna%1").arg(i));
        ant_[i].name = s.value(QStringLiteral("name"), kDefaultNames[i]).toString();
        ant_[i].points.clear();
        const auto doc = QJsonDocument::fromJson(
            s.value(QStringLiteral("points")).toString().toUtf8());
        for (const auto v : doc.array()) {
            const QJsonObject o = v.toObject();
            Point p;
            p.freqHz   = o.value(QStringLiteral("f")).toDouble();
            p.band     = bandLabel(p.freqHz);
            p.input    = o.value(QStringLiteral("in")).toString();
            p.output   = o.value(QStringLiteral("out")).toString();
            p.inductor = o.value(QStringLiteral("ind")).toString();
            p.note     = o.value(QStringLiteral("n")).toString();
            ant_[i].points.append(p);
        }
        sortAntenna(i);
        s.endGroup();
    }
    s.endGroup();
}

} // namespace lyra::ui

// Lyra — EssbCoachModel implementation.  See essbcoachmodel.h.

#include "essbcoachmodel.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QSettings>
#include <QTimer>

#include <algorithm>

#include "essbcoachreport.h"
#include "recorder/RecorderEngine.h"
#include "wdsp_engine.h"

using namespace lyra::dsp::coach;
namespace rep = lyra::coachreport;

namespace lyra::ui {

namespace {

constexpr int kPollMs = 40;
// setActive(false) waits this long: a dock moving between windows or tabs is
// briefly hidden, and must neither detach the taps nor flag a paused average.
constexpr int kDetachDebounceMs = 300;
// AGC correction must be missing this long (poll ticks) before the panel says
// so: the first DSP blocks after a channel open are unaligned by design.
constexpr int kFallbackTicks = 25;   // 1 s
// A published analyzer / meter result older than this means nothing is being
// fed: "No RX audio" for the analyzer, a blanked splatter reading for the meter.
constexpr qint64 kStaleMs = 1000;

const QString kRoot = QStringLiteral("essbCoach/");

QVariantList toList(const std::vector<double> &v)
{
    QVariantList l;
    l.reserve(static_cast<int>(v.size()));
    for (double x : v) l.append(x);
    return l;
}

bool sameRx(const RxConditions &a, const RxConditions &b)
{
    return a.rxLowHz == b.rxLowHz && a.rxHighHz == b.rxHighHz && a.nrOn == b.nrOn
           && a.anfOn == b.anfOn && a.agcMode == b.agcMode && a.mode == b.mode;
}

bool isAmMode(const std::string &m)
{
    return m == "AM" || m == "SAM";
}

bool isCompression(FindingKind k)
{
    return k == FindingKind::NoiseBetweenWords || k == FindingKind::Pumping
           || k == FindingKind::Squashed;
}

}  // namespace

const EssbCoachModel::SettingDef EssbCoachModel::kSettings[] = {
    {"minSpeechSec", 2.0, 60.0, 8.0},
    {"minSnrDb", 0.0, 40.0, 15.0},
    {"gapToSpeechDb", 5.0, 50.0, kGapToSpeechFlagDb},
    {"gapRiseDb", 1.0, 20.0, kGapRiseFlagDb},
    {"crestDb", 2.0, 20.0, kCrestFlagDb},
    {"zone0Hz", 20.0, 12000.0, 60.0},     // Bass lower edge
    {"zone1Hz", 20.0, 12000.0, 150.0},    // Low-mid
    {"zone2Hz", 20.0, 12000.0, 600.0},    // Body
    {"zone3Hz", 20.0, 12000.0, 2000.0},   // Upper
    {"zone4Hz", 20.0, 12000.0, 3500.0},   // Top (runs to the target's high edge)
};

EssbCoachModel::EssbCoachModel(QObject *parent)
    : QObject(parent)
    , analyzer_(new CoachAnalyzer(48000.0))
    , meter_(new SplatterMeter)
{
    analyzer_->prepare();   // before any audio can reach it
    clock_.start();
    snap_.bands = makeBands();
    view_ = snap_;

    timer_ = new QTimer(this);
    timer_->setInterval(kPollMs);
    connect(timer_, &QTimer::timeout, this, &EssbCoachModel::poll);
    offTimer_ = new QTimer(this);
    offTimer_->setSingleShot(true);
    offTimer_->setInterval(kDetachDebounceMs);
    connect(offTimer_, &QTimer::timeout, this, [this] { applyActive(false); });

    QSettings s;
    lyraAdvice_ = s.value(kRoot + QStringLiteral("lyraAdvice"), true).toBool();
    loadTargets();
    loadSettings();
    applySettings();
    rebuild();
}

EssbCoachModel::~EssbCoachModel()
{
    // The analyzer and meter are released with the model; the engine must
    // stop calling them first (MainWindow tears the engine down before this).
    if (engine_) engine_->setCoachTaps(nullptr, nullptr);
}

void EssbCoachModel::setEngine(lyra::dsp::WdspEngine *engine)
{
    engine_ = engine;
    // The engine can be torn down before this model; never touch it after.
    if (engine_) {
        connect(engine_, &QObject::destroyed, this, [this] { engine_ = nullptr; });
        // Key-down and the (delayed) un-mute: the splatter average no longer
        // describes the other station.
        connect(engine_, &lyra::dsp::WdspEngine::txMutedChanged, this, &EssbCoachModel::onTxEdge);
    }
}

void EssbCoachModel::onTxEdge()
{
    meter_->restart();   // applied at the meter's next feed (after the TX hold)
    spRaw_ = SplatterResult();
    lastSplatterMs_ = clock_.elapsed() - kStaleMs - 1;
    presentSplatter();
    markDirty();
}

void EssbCoachModel::setRecorder(lyra::recorder::RecorderEngine *rec)
{
    rec_ = rec;
    if (!rec_) return;
    recording_ = rec_->isRecording();
    connect(rec_, &lyra::recorder::RecorderEngine::recordingChanged, this, [this](bool on) {
        recording_ = on;
        pendingReport_.clear();
        if (on) reportSeq_ = 0;
        markDirty();
    });
}

void EssbCoachModel::setAvailable(bool on)
{
    if (available_ == on) return;
    available_ = on;
    if (!available_) {
        timer_->stop();
        detach();
    } else if (active_) {
        attach();
        timer_->start();
    }
    markDirty();
}

void EssbCoachModel::noteRx1FreqChanged()
{
    meter_->restart();
}

// ---- attach / detach ------------------------------------------------------

void EssbCoachModel::setActive(bool on)
{
    if (on) {
        offTimer_->stop();
        applyActive(true);
    } else if (active_) {
        offTimer_->start();
    }
}

void EssbCoachModel::applyActive(bool on)
{
    if (active_ == on) return;
    active_ = on;
    // Hidden = taps detached = a running average stops accumulating.
    if (!on && (snap_.baseline == AvgState::Running || snap_.recheck == AvgState::Running))
        pausedWhileHidden_ = true;
    if (on && running()) {
        attach();
        dirty_ = true;
        timer_->start();
        poll();
    } else {
        timer_->stop();
        detach();
    }
    if (!on) emit panelClosed();
}

void EssbCoachModel::attach()
{
    if (!engine_) return;
    const int rate = engine_->iqRate();
    if (preparedRate_ == 0 && rate > 0) {
        // First attach: the meter has never been fed, so preparing here is safe.
        meter_->prepare(rate);
        preparedRate_ = rate;
        chValid_ = false;
    } else if (preparedRate_ > 0 && rate > 0 && rate != preparedRate_) {
        meter_->setRate(rate);   // applied by the meter's own thread
        preparedRate_ = rate;
    }
    const bool withMeter = preparedRate_ > 0;
    engine_->setCoachTaps(analyzer_.get(), withMeter ? meter_.get() : nullptr);
    attachedMeter_ = withMeter;
    // The analyzer gets kStaleMs to deliver before "no audio" applies; the
    // meter's last result predates the detach, so it is stale until the
    // meter publishes again (at most one FFT hop).
    lastAudioMs_ = clock_.elapsed();
    lastSplatterMs_ = lastAudioMs_ - kStaleMs - 1;
}

void EssbCoachModel::detach()
{
    if (engine_) engine_->setCoachTaps(nullptr, nullptr);
    attachedMeter_ = false;
    // Practice: nothing is fed while detached, so the pass in progress and
    // any ended pass whose lap has not been read are not captured.
    passId_ = 0;
    wanted_.clear();
}

void EssbCoachModel::ensureMeter()
{
    const int rate = engine_->iqRate();
    if (rate <= 0 || rate == preparedRate_) return;
    if (preparedRate_ == 0) {
        meter_->prepare(rate);
        preparedRate_ = rate;
        chValid_ = false;
        engine_->setCoachTaps(analyzer_.get(), meter_.get());
        attachedMeter_ = true;
        return;
    }
    // Rate change under a prepared meter: the meter re-derives its bin width,
    // band size and smoothing on its own thread and re-arms its validity timer.
    meter_->setRate(rate);
    preparedRate_ = rate;
}

void EssbCoachModel::syncSplatterChannel()
{
    const QString m = engine_->mode();
    const bool usb = !(m == QLatin1String("LSB") || m == QLatin1String("DIGL")
                       || m == QLatin1String("CWL"));
    const double shift = engine_->rxShiftHz();
    const double edge = target().highEdgeHz;
    // Identical calls would re-arm the meter's 3 s validity timer, so only
    // pass real changes.
    if (chValid_ && usb == chUsb_ && shift == chShift_ && edge == chEdge_) return;
    meter_->setChannel(shift, usb, edge);
    chValid_ = true;
    chUsb_ = usb;
    chShift_ = shift;
    chEdge_ = edge;
}

// ---- poll / rebuild -------------------------------------------------------

void EssbCoachModel::markDirty()
{
    dirty_ = true;
    if (!timer_->isActive()) {   // no poll running: publish the change now
        dirty_ = false;
        rebuild();
        emit updated();
    }
}

void EssbCoachModel::readConditions()
{
    RxConditions c;
    const double lo = engine_->passbandLowHz(), hi = engine_->passbandHighHz();
    if (lo < 0.0 && hi > 0.0) {   // symmetric (AM/DSB): audio runs 0 .. edge
        c.rxLowHz = 0.0;
        c.rxHighHz = std::max(-lo, hi);
    } else {
        c.rxLowHz = std::min(std::fabs(lo), std::fabs(hi));
        c.rxHighHz = std::max(std::fabs(lo), std::fabs(hi));
    }
    c.nrOn = engine_->nrEnabled() || engine_->nnrEnabled() || engine_->lmsEnabled();
    c.anfOn = engine_->anfEnabled();
    if (practice_) {
        // The practice audio comes from the TX rack: the RX filter, NR and
        // ANF are not in its path; the live TX filter edges are.
        c.nrOn = c.anfOn = false;
        if (txEdgesProvider_) {
            const auto [txLo, txHi] = txEdgesProvider_();
            if (std::isfinite(txLo) && std::isfinite(txHi) && txLo >= 0.0 && txLo < txHi) {
                c.rxLowHz = txLo;
                c.rxHighHz = txHi;
            }
        }
    }
    c.agcMode = engine_->agcMode().toStdString();
    c.mode = engine_->mode().toStdString();
    if (!sameRx(c, rx_)) dirty_ = true;
    rx_ = c;

    const bool tx = engine_->coachTxGated();
    const bool silent = clock_.elapsed() - lastAudioMs_ > kStaleMs;
    if (tx != transmitting_ || silent != noAudio_) dirty_ = true;
    transmitting_ = tx;
    noAudio_ = silent;

    // Practice audio is fed with a 0 dB gain, which is its true gain: no AGC
    // to correct, so no fallback and nothing withheld.
    const bool aligned = practice_ || engine_->coachAgcAligned();
    // While transmitting (AGC forced Off, then restored and resynced) or with
    // no audio arriving, alignment says nothing about the RX audio: neither
    // blames AGC, and the 1 s wait restarts afterwards.
    unalignedTicks_ = (aligned || tx || silent) ? 0
                                                : std::min(unalignedTicks_ + 1, kFallbackTicks);
    const bool fallback = unalignedTicks_ >= kFallbackTicks && rx_.agcMode != "off";
    // AGC Off, in-tree WDSP, but a post-AGC stage of unknown latency
    // runs.  (Prebuilt WDSP is never "unavailable": with AGC Off the
    // uncorrected 0 dB gain is the true gain.)
    const bool unavailable = unalignedTicks_ >= kFallbackTicks && rx_.agcMode == "off"
        && engine_->coachAgcState() == lyra::dsp::WdspEngine::CoachAgcState::UnknownLatency;
    // Name the stage only when we know it exactly: the neural NR is the one
    // stage the latency model rejects by name.
    QString stage;
    if (unavailable && engine_->nnrEnabled()) stage = tr("neural NR");
    if (aligned != agcCorrected_ || fallback != agcFallback_
        || unavailable != compressionUnavailable_ || stage != unalignedStage_)
        dirty_ = true;
    agcCorrected_ = aligned;
    agcFallback_ = fallback;
    compressionUnavailable_ = unavailable;
    unalignedStage_ = stage;
}

void EssbCoachModel::poll()
{
    if (!running()) return;
    if (analyzer_->snapshot(snap_)) {
        dirty_ = true;
        lastAudioMs_ = clock_.elapsed();
        if (practice_) collectPracticeLap();
    }
    if (meter_->snapshot(spRaw_)) {
        dirty_ = true;
        lastSplatterMs_ = clock_.elapsed();
    }
    if (unmaskPending_ && snap_.recheck == AvgState::Running) {
        recheckMasked_ = false;
        unmaskPending_ = false;
        dirty_ = true;
    }
    readConditions();
    ensureMeter();
    syncSplatterChannel();
    presentSplatter();

    if (!dirty_) return;
    dirty_ = false;
    rebuild();

    // A Stop while recording writes its report once the stopped curve is in.
    if (recording_ && !pendingReport_.isEmpty()) {
        const bool isBase = pendingReport_ == QLatin1String("baseline");
        const AvgState st = isBase ? view_.baseline : view_.recheck;
        const bool has = isBase ? !view_.baselineDb.empty() : !view_.recheckDb.empty();
        if (st == AvgState::Stopped && has) {
            writeSessionReport(pendingReport_);
            pendingReport_.clear();
        }
    }
    emit updated();
}

void EssbCoachModel::presentSplatter()
{
    // AM: a carrier-dominated, one-sided measurement would never alert
    // honestly, so it is not measured.  Stale: nothing fed for kStaleMs
    // (transmitting, or the tap stopped), so the last result is not current.
    // Practice: no TX filter in the loop, so a reading would be meaningless.
    QString st;
    if (practice_) st = QStringLiteral("practice");
    else if (isAmMode(rx_.mode)) st = QStringLiteral("am");
    else if (clock_.elapsed() - lastSplatterMs_ > kStaleMs) st = QStringLiteral("stale");
    else st = spRaw_.valid ? QStringLiteral("measured") : QStringLiteral("pending");
    const bool show = st == QLatin1String("measured") || st == QLatin1String("pending");
    const SplatterResult r = show ? spRaw_ : SplatterResult();
    const auto same = [](double a, double b) { return a == b || (std::isnan(a) && std::isnan(b)); };
    if (st != spStatus_ || r.valid != sp_.valid || r.alert != sp_.alert || !same(r.peakDb, sp_.peakDb)
        || !same(r.outDb, sp_.outDb) || !same(r.marginDb, sp_.marginDb) || !same(r.noiseDb, sp_.noiseDb))
        dirty_ = true;
    spStatus_ = st;
    sp_ = r;
}

void EssbCoachModel::applyView(CoachSnapshot &s) const
{
    if (practice_) {
        // A in the baseline slot, B in the re-check slot.  The SNR estimate
        // stays the analyzer's (its baseline runs over the whole session).
        const PracticeStore &a = store_[0], &b = store_[1];
        s.baselineDb = a.has ? a.db : std::vector<double>();
        s.speechSec = a.has ? a.speechSec : 0.0;
        s.comp = a.has ? a.comp : CompressionMetrics();
        s.baseline = a.has ? AvgState::Stopped : AvgState::Idle;
        s.recheckDb = b.has ? b.db : std::vector<double>();
        s.recheckSpeechSec = b.has ? b.speechSec : 0.0;
        s.recheckComp = b.has ? b.comp : CompressionMetrics();
        s.recheck = b.has ? AvgState::Stopped : AvgState::Idle;
        return;
    }
    if (promoted_) {
        // "Make baseline": the re-check's curve, speech time and compression
        // replace the baseline's.  The SNR estimate stays the analyzer's.
        s.baselineDb = promBaseDb_;
        s.speechSec = promSpeechSec_;
        s.comp = promComp_;
        s.baseline = AvgState::Stopped;
    }
    if (recheckMasked_) {
        s.recheckDb.clear();
        s.recheck = AvgState::Idle;
        s.recheckSpeechSec = 0.0;
        s.recheckComp = CompressionMetrics();
    }
}

void EssbCoachModel::rebuild()
{
    view_ = snap_;
    applyView(view_);
    const Target &tg = target();

    bandsHz_ = toList(view_.bands.centreHz);
    liveDb_ = toList(view_.liveDb);
    baselineDb_ = toList(view_.baselineDb);
    recheckDb_ = toList(view_.recheckDb);
    std::vector<double> tdb, tol;
    for (double hz : view_.bands.centreHz) {
        tdb.push_back(targetDbAt(tg, hz));
        tol.push_back(toleranceAt(tg, hz));
    }
    targetDb_ = toList(tdb);
    tolDb_ = toList(tol);

    // Same choice the advisor makes: the re-check once it has a curve.
    const bool rc = view_.recheck != AvgState::Idle && !view_.recheckDb.empty();
    speechSec_ = rc ? view_.recheckSpeechSec : view_.speechSec;
    snrDb_ = view_.medianSnrDb;

    findings_ = advisor_.evaluate(view_, sp_, rx_, tg);
    if (practice_) {
        // "RX filter too narrow" would point at the RX filter, which is not
        // in the practice path (its edges here are the TX filter's).
        findings_.erase(std::remove_if(findings_.begin(), findings_.end(),
                                       [](const Finding &f) {
                                           return f.kind == FindingKind::RxFilterTooNarrow;
                                       }),
                        findings_.end());
    }
    const bool withhold = agcFallback_ || compressionUnavailable_;
    if (withhold) {
        // Without AGC correction our own AGC would read as the other
        // station's noise / pumping; hold the compression advice back.
        findings_.erase(std::remove_if(findings_.begin(), findings_.end(),
                                       [](const Finding &f) { return isCompression(f.kind); }),
                        findings_.end());
    }
    edgesRaw_ = advisor_.edges(view_, rx_);
    deltasRaw_ = advisor_.zoneDelta(view_);

    rep::AdviceContext ctx;
    ctx.lyra = lyraAdvice_;
    ctx.target = tg;
    ctx.edges = edgesRaw_;
    ctx.speechSec = speechSec_;
    ctx.snrDb = snrDb_;
    findingText_.clear();
    adviceLines_.clear();
    // The AGC / no-audio / transmitting state is the panel's one status line
    // (EssbCoachPanel.qml statusNote), never repeated as an advice line.
    for (const Finding &f : findings_) {
        const QString t = rep::adviceText(f, ctx);
        findingText_.push_back(t);
        adviceLines_ << t;
    }

    edgesText_ = rep::edgesText(edgesRaw_);
    edges_ = QVariantMap{
        {QStringLiteral("lowHz"), edgesRaw_.lowHz},
        {QStringLiteral("highHz"), edgesRaw_.highHz},
        {QStringLiteral("lowBeyondRx"), edgesRaw_.lowBeyondRx},
        {QStringLiteral("highBeyondRx"), edgesRaw_.highBeyondRx},
        {QStringLiteral("tier"), QString::fromStdString(edgesRaw_.tier)},
        {QStringLiteral("tierName"), [&] {
             for (const Target &t : builtinTargets())
                 if (t.id == edgesRaw_.tier) return QString::fromStdString(t.name);
             return QString();
         }()},
    };

    const CompressionMetrics &m = rc ? view_.recheckComp : view_.comp;
    metrics_ = QVariantMap{
        {QStringLiteral("gapToSpeechDb"), withhold ? double(NAN) : m.gapToSpeechDb},
        {QStringLiteral("gapRiseDb"), withhold ? double(NAN) : m.gapRiseDb},
        {QStringLiteral("crestDb"), withhold ? double(NAN) : m.crestDb},
        {QStringLiteral("pauses"), m.pauses},
    };
    splatter_ = QVariantMap{
        {QStringLiteral("valid"), sp_.valid},
        {QStringLiteral("marginDb"), sp_.marginDb},
        {QStringLiteral("alert"), sp_.alert},
        {QStringLiteral("peakDb"), sp_.peakDb},
        {QStringLiteral("outDb"), sp_.outDb},
        {QStringLiteral("noiseDb"), sp_.noiseDb},
        {QStringLiteral("status"), spStatus_},
    };

    zoneDeltas_.clear();
    for (const auto &p : deltasRaw_)
        zoneDeltas_.append(QVariantMap{{QStringLiteral("zone"), rep::zoneKey(p.first)},
                                       {QStringLiteral("label"), rep::zoneLabel(p.first)},
                                       {QStringLiteral("db"), p.second}});
}

QString EssbCoachModel::holdNote() const
{
    return rep::holdSteadyNote();
}

// ---- controls -------------------------------------------------------------

void EssbCoachModel::startBaseline()
{
    if (practice_) return;   // the practice loop owns the analyzer's recordings
    pausedWhileHidden_ = false;
    promoted_ = false;
    analyzer_->startBaseline();
    markDirty();
}

void EssbCoachModel::stopBaseline()
{
    if (practice_) return;   // the practice loop owns the analyzer's recordings
    pausedWhileHidden_ = false;
    analyzer_->stopBaseline();
    if (recording_) pendingReport_ = QStringLiteral("baseline");
    markDirty();
}

void EssbCoachModel::startRecheck()
{
    if (practice_) return;   // the practice loop owns the analyzer's recordings
    pausedWhileHidden_ = false;
    // After a promotion the old re-check is still in the published snapshot;
    // keep it hidden until the snapshot shows the new one Running.
    if (recheckMasked_) unmaskPending_ = true;
    analyzer_->startRecheck();
    markDirty();
}

void EssbCoachModel::stopRecheck()
{
    if (practice_) return;   // the practice loop owns the analyzer's recordings
    pausedWhileHidden_ = false;
    analyzer_->stopRecheck();
    if (recording_) pendingReport_ = QStringLiteral("recheck");
    markDirty();
}

void EssbCoachModel::makeBaseline()
{
    if (practice_ || recheckMasked_ || snap_.recheckDb.empty()) return;
    pausedWhileHidden_ = false;
    // The analyzer has no promote operation: freeze the re-check, copy its
    // results into the view as the baseline, and hide the re-check until the
    // next startRecheck().
    analyzer_->stopRecheck();
    analyzer_->stopBaseline();
    promBaseDb_ = snap_.recheckDb;
    promSpeechSec_ = snap_.recheckSpeechSec;
    promComp_ = snap_.recheckComp;
    promoted_ = true;
    recheckMasked_ = true;
    unmaskPending_ = false;
    advisor_.reset();
    markDirty();
}

void EssbCoachModel::reset()
{
    pausedWhileHidden_ = false;
    analyzer_->reset();
    advisor_.reset();
    promoted_ = false;
    recheckMasked_ = false;
    unmaskPending_ = false;
    pendingReport_.clear();
    store_[0] = store_[1] = PracticeStore();
    wanted_.clear();
    passId_ = 0;
    lastLapId_ = 0;
    if (practice_) {
        // Posted after the reset, so applied after it (CoachAnalyzer THREADING).
        analyzer_->startBaseline();   // SNR estimate only (see PRACTICE MODE)
        beginPracticePass();
    }
    markDirty();
}

// ---- practice mode --------------------------------------------------------

void EssbCoachModel::setPracticeMode(bool on)
{
    if (practice_ == on) return;
    practice_ = on;
    reset();
}

void EssbCoachModel::beginPracticePass()
{
    const std::uint64_t id = analyzer_->startRecheck();
    // Only a pass that starts with the taps attached can be whole.
    passId_ = running() ? id : 0;
}

void EssbCoachModel::practicePassStarted()
{
    if (!practice_) return;
    pausedWhileHidden_ = false;   // this pass is measured whole (or not at all)
    beginPracticePass();
}

void EssbCoachModel::practicePassEnded(int side, bool clean)
{
    if (!practice_) return;
    analyzer_->stopRecheck();
    // The pass ends with this request; its result arrives as the lap tagged
    // passId_ (CoachAnalyzer LAP), even when the next pass's start overtakes
    // the stop.  A dirty pass copies nothing.
    if (clean && passId_ != 0 && (side == 0 || side == 1) && running())
        wanted_.push_back({passId_, side});
    passId_ = 0;
}

void EssbCoachModel::clearPracticeSide(int side)
{
    if (!practice_ || (side != 0 && side != 1)) return;
    store_[side] = PracticeStore();
    // A pass that ended before the edit / save but is not read yet belongs to
    // the old settings: drop it too.
    wanted_.erase(std::remove_if(wanted_.begin(), wanted_.end(),
                                 [side](const PracticeWant &w) { return w.side == side; }),
                  wanted_.end());
    markDirty();
}

void EssbCoachModel::writePracticeReport()
{
    if (!practice_ || (!store_[0].has && !store_[1].has)) return;
    if (!recording_) return;   // same rule as the Stop reports: only into a session
    rebuild();                 // view_, findings and edges reflect the stores now
    writeSessionReport(store_[1].has ? QStringLiteral("recheck") : QStringLiteral("baseline"));
}

void EssbCoachModel::collectPracticeLap()
{
    if (snap_.lapId == 0 || snap_.lapId == lastLapId_) return;
    lastLapId_ = snap_.lapId;
    // Laps end in pass order, so a wanted pass older than this lap was
    // overwritten before a poll saw it (two passes inside one poll): drop it.
    for (auto it = wanted_.begin(); it != wanted_.end();) {
        if (it->id > snap_.lapId) { ++it; continue; }
        if (it->id == snap_.lapId && !snap_.lapDb.empty()) {
            PracticeStore &st = store_[it->side];   // most recent clean pass wins
            st.has = true;
            st.db = snap_.lapDb;
            st.speechSec = snap_.lapSpeechSec;
            st.comp = snap_.lapComp;
            dirty_ = true;
        }
        it = wanted_.erase(it);
    }
}

void EssbCoachModel::setFrozen(bool on)
{
    analyzer_->freeze(on);
    snap_.frozen = on;
    markDirty();
}

void EssbCoachModel::setLyraAdvice(bool on)
{
    if (lyraAdvice_ == on) return;
    lyraAdvice_ = on;
    QSettings().setValue(kRoot + QStringLiteral("lyraAdvice"), on);
    markDirty();
}

void EssbCoachModel::toggleRecord()
{
    // RecorderEngine::toggle() stamps the session with the same (freq, mode)
    // provider as the main REC button; recordingChanged updates recording_.
    if (rec_) rec_->toggle();
}

// ---- targets --------------------------------------------------------------

const Target &EssbCoachModel::target() const
{
    return targets_[static_cast<size_t>(targetIdx_)];
}

QVariantList EssbCoachModel::targets() const
{
    QVariantList l;
    for (const Target &t : targets_)
        l.append(QVariantMap{{QStringLiteral("id"), QString::fromStdString(t.id)},
                             {QStringLiteral("name"), QString::fromStdString(t.name)},
                             {QStringLiteral("builtin"), t.builtin}});
    return l;
}

void EssbCoachModel::loadTargets()
{
    targets_ = builtinTargets();   // never written to QSettings, never deleted
    QSettings s;
    s.beginGroup(kRoot + QStringLiteral("targets"));
    QStringList keys = s.childKeys();
    keys.sort();
    for (const QString &k : keys) {
        Target t;
        if (!targetFromJson(s.value(k).toString().toStdString(), t)) continue;
        const auto fin = [](double v) { return std::isfinite(v); };
        if (!(fin(t.lowEdgeHz) && fin(t.highEdgeHz) && t.lowEdgeHz > 0.0
              && t.lowEdgeHz < t.highEdgeHz && t.highEdgeHz <= 12000.0)
            || t.points.size() < 2 || !fin(t.tolLowDb) || !fin(t.tolDb) || !fin(t.tolSplitHz))
            continue;
        bool ok = true;
        for (const TargetPoint &pt : t.points) ok = ok && fin(pt.hz) && fin(pt.db) && pt.hz > 0.0;
        if (!ok) continue;
        t.id = k.toStdString();   // the key is the identity
        t.builtin = false;
        targets_.push_back(t);
    }
    s.endGroup();

    const QString want = s.value(kRoot + QStringLiteral("targetId"), QStringLiteral("essb")).toString();
    targetIdx_ = 0;
    for (size_t i = 0; i < targets_.size(); ++i)
        if (QString::fromStdString(targets_[i].id) == want) targetIdx_ = static_cast<int>(i);
}

void EssbCoachModel::setTargetId(const QString &id)
{
    for (size_t i = 0; i < targets_.size(); ++i) {
        if (QString::fromStdString(targets_[i].id) != id) continue;
        if (static_cast<int>(i) == targetIdx_) return;
        targetIdx_ = static_cast<int>(i);
        QSettings().setValue(kRoot + QStringLiteral("targetId"), id);
        applySettings();   // the Top zone runs to the new target's high edge
        markDirty();
        return;
    }
}

void EssbCoachModel::captureAsTarget(const QString &name)
{
    // The baseline curve (not the re-check) with its measured edges.
    CoachSnapshot tmp = view_;
    tmp.recheckDb.clear();
    tmp.recheck = AvgState::Idle;
    const Edges e = advisor_.edges(tmp, rx_);
    if (view_.baselineDb.empty() || !std::isfinite(e.lowHz) || !std::isfinite(e.highHz)) return;

    Target t;
    t.id = QStringLiteral("u%1").arg(QDateTime::currentMSecsSinceEpoch()).toStdString();
    const QString nm = name.trimmed();
    t.name = (nm.isEmpty() ? tr("Captured target") : nm).toStdString();
    t.lowEdgeHz = e.lowHz;
    t.highEdgeHz = e.highHz;
    t.builtin = false;
    const size_t n = std::min(view_.baselineDb.size(), view_.bands.centreHz.size());
    for (size_t k = 0; k < n; ++k) {
        const double hz = view_.bands.centreHz[k];
        if (hz < e.lowHz || hz > e.highHz || !std::isfinite(view_.baselineDb[k])) continue;
        t.points.push_back({hz, view_.baselineDb[k]});
    }
    if (t.points.size() < 2) return;

    QSettings s;
    s.setValue(kRoot + QStringLiteral("targets/") + QString::fromStdString(t.id),
               QString::fromStdString(targetToJson(t)));
    targets_.push_back(t);
    setTargetId(QString::fromStdString(t.id));
    markDirty();
}

void EssbCoachModel::deleteTarget(const QString &id)
{
    for (size_t i = 0; i < targets_.size(); ++i) {
        if (QString::fromStdString(targets_[i].id) != id) continue;
        if (targets_[i].builtin) return;
        QSettings().remove(kRoot + QStringLiteral("targets/") + id);
        targets_.erase(targets_.begin() + static_cast<long>(i));
        if (static_cast<int>(i) == targetIdx_) {
            targetIdx_ = 0;
            QSettings().setValue(kRoot + QStringLiteral("targetId"), QStringLiteral("essb"));
            applySettings();
        } else if (static_cast<int>(i) < targetIdx_) {
            --targetIdx_;
        }
        markDirty();
        return;
    }
}

// ---- settings -------------------------------------------------------------

Zone EssbCoachModel::zoneAt(int i, double hiHz) const
{
    static const ZoneId ids[5] = {ZoneId::Bass, ZoneId::LowMid, ZoneId::Body, ZoneId::Upper,
                                  ZoneId::Top};
    return Zone{ids[i], zoneLo_[i], hiHz};
}

void EssbCoachModel::loadSettings()
{
    QSettings s;
    double v[kSettingCount];
    for (int i = 0; i < kSettingCount; ++i) {
        const SettingDef &d = kSettings[i];
        const double raw = s.value(kRoot + QLatin1String(d.key), d.def).toDouble();
        v[i] = std::isfinite(raw) ? std::clamp(raw, d.lo, d.hi) : d.def;   // same range as setSetting
    }
    thresholds_.minSpeechSec = v[0];
    thresholds_.minSnrDb = v[1];
    thresholds_.gapToSpeechDb = v[2];
    thresholds_.gapRiseDb = v[3];
    thresholds_.crestDb = v[4];
    for (int i = 0; i < 5; ++i) zoneLo_[i] = v[5 + i];
    // setSetting's zone rule: strictly ascending, Top below the selected
    // target's high edge.  A store that breaks it falls back to the defaults.
    bool ok = zoneLo_[4] < target().highEdgeHz;
    for (int i = 1; i < 5; ++i) ok = ok && zoneLo_[i] > zoneLo_[i - 1];
    if (!ok)
        for (int j = 0; j < 5; ++j) zoneLo_[j] = kSettings[5 + j].def;
}

void EssbCoachModel::applySettings()
{
    advisor_.setThresholds(thresholds_);
    advisor_.setZones(zones());
}

QVariantMap EssbCoachModel::settings() const
{
    return QVariantMap{
        {QStringLiteral("minSpeechSec"), thresholds_.minSpeechSec},
        {QStringLiteral("minSnrDb"), thresholds_.minSnrDb},
        {QStringLiteral("gapToSpeechDb"), thresholds_.gapToSpeechDb},
        {QStringLiteral("gapRiseDb"), thresholds_.gapRiseDb},
        {QStringLiteral("crestDb"), thresholds_.crestDb},
        {QStringLiteral("zone0Hz"), zoneLo_[0]},
        {QStringLiteral("zone1Hz"), zoneLo_[1]},
        {QStringLiteral("zone2Hz"), zoneLo_[2]},
        {QStringLiteral("zone3Hz"), zoneLo_[3]},
        {QStringLiteral("zone4Hz"), zoneLo_[4]},
    };
}

QVariantList EssbCoachModel::settingDefs() const
{
    QVariantList l;
    for (const SettingDef &d : kSettings)
        l.append(QVariantMap{{QStringLiteral("key"), QLatin1String(d.key)},
                             {QStringLiteral("min"), d.lo},
                             {QStringLiteral("max"), d.hi},
                             {QStringLiteral("def"), d.def}});
    return l;
}

void EssbCoachModel::setSetting(const QString &key, double value)
{
    int idx = -1;
    for (int i = 0; i < kSettingCount; ++i)
        if (key == QLatin1String(kSettings[i].key)) idx = i;
    if (idx < 0 || !std::isfinite(value)) return;
    const SettingDef &d = kSettings[idx];
    value = std::clamp(value, d.lo, d.hi);

    if (idx >= 5) {   // zone lower edge: keep the five edges strictly ascending
        const int z = idx - 5;
        const double above = z < 4 ? zoneLo_[z + 1] : target().highEdgeHz;
        if ((z > 0 && value <= zoneLo_[z - 1]) || value >= above) {
            markDirty();   // rejected: let the control snap back
            return;
        }
        zoneLo_[z] = value;
    } else {
        double *t[5] = {&thresholds_.minSpeechSec, &thresholds_.minSnrDb, &thresholds_.gapToSpeechDb,
                        &thresholds_.gapRiseDb, &thresholds_.crestDb};
        *t[idx] = value;
    }
    QSettings().setValue(kRoot + QLatin1String(d.key), value);
    applySettings();
    markDirty();
}

void EssbCoachModel::resetSettings()
{
    QSettings s;
    for (const SettingDef &d : kSettings) s.remove(kRoot + QLatin1String(d.key));
    thresholds_ = CoachThresholds();
    thresholds_.minSpeechSec = kSettings[0].def;
    thresholds_.minSnrDb = kSettings[1].def;
    for (int i = 0; i < 5; ++i) zoneLo_[i] = kSettings[5 + i].def;
    applySettings();
    markDirty();
}

// ---- session record -------------------------------------------------------

void EssbCoachModel::writeJson(const QString &name, const QJsonObject &obj)
{
    if (!rec_ || rec_->sessionDir().isEmpty()) return;
    QFile f(QDir(rec_->sessionDir()).filePath(name));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
}

void EssbCoachModel::writeSessionReport(const QString &recording)
{
    rep::ReportInput in;
    in.recording = recording;
    in.createdUtc = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    in.freqHz = freqProvider_ ? freqProvider_() : 0;
    in.target = target();
    in.snap = view_;
    in.splatter = sp_;
    in.splatterStatus = spStatus_;
    in.splatterShiftHz = chValid_ ? chShift_ : double(NAN);
    in.splatterUsb = chUsb_;
    in.splatterEdgeHz = chValid_ ? chEdge_ : double(NAN);
    in.rx = rx_;
    in.edges = edgesRaw_;
    in.zones = zones();
    in.thresholds = thresholds_;
    in.findings = findings_;
    in.findingText = findingText_;
    in.zoneDeltas = deltasRaw_;
    in.agcCorrected = agcCorrected_;
    // Same rule as the panel's withheld readings (rebuild()).
    in.agcFallback = agcFallback_ || compressionUnavailable_;
    in.promoted = promoted_;
    in.lyraAdvice = lyraAdvice_;
    in.source = practice_ ? QStringLiteral("practice") : QStringLiteral("rx");

    // Each report carries its own target (target, targetId, targetDb); no
    // separate target file.
    writeJson(QStringLiteral("coach-%1-%2.json").arg(++reportSeq_).arg(recording),
              rep::buildReport(in));
}

std::vector<Zone> EssbCoachModel::zones() const
{
    std::vector<Zone> z;
    for (int i = 0; i < 5; ++i)
        z.push_back(zoneAt(i, i < 4 ? zoneLo_[i + 1] : target().highEdgeHz));
    return z;
}

}  // namespace lyra::ui

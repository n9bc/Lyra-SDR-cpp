// Lyra — eSSB Coach model.  The "model" half of the eSSB Coach panel
// (EssbCoachPanel.qml, context property `EssbCoach`): owns the receive-side
// measurement engines (CoachAnalyzer on RX1 audio, SplatterMeter on RX1 IQ),
// polls them at 40 ms while the panel is open (setActive), runs CoachAdvisor and
// republishes everything as plain QML-friendly properties.  It also keeps the
// coach's editable settings and the custom targets in QSettings (essbCoach/),
// and writes the version-1 measurement report (essbcoachreport.h) next to the
// session recording.
//
// LIFETIME: the analyzer and the meter live as long as the model (= the main
// window).  WdspEngine::setCoachTaps(nullptr, nullptr) does not wait for a
// feed() that is already running on the audio / RX worker thread, so they are
// never deleted while the engine could still be calling them.
//
// PRACTICE MODE (eSSB practice loop, driven by PracticeLoop): the analyzer is
// fed our own recorded clip after the TX rack instead of RX1 audio.  Each loop
// pass is one analyzer re-check (practicePassStarted / practicePassEnded); a
// clean pass's result is copied into the store of the side it played on (its
// most recent clean pass), and the stores replace the baseline (A) and
// re-check (B) slots of the view.  The capture reads the analyzer's LAP
// (CoachAnalyzer.h), matched by the id startRecheck() returned for that pass:
// PracticeLoop posts the end of one pass and the start of the next back to
// back, the two requests coalesce into one start, so the ended pass never
// shows up as a Stopped re-check.  A pass is captured only if the panel stayed
// open for the whole of it.  The analyzer's baseline runs for the whole
// practice session only to give the SNR estimate the advisor's confidence gate
// needs; its curve is never shown.
//
// All properties notify on updated(), emitted once per change of the polled
// state.  Lists of dB values are QVariantList of doubles; NaN means "no data".

#pragma once

#include <QElapsedTimer>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

#include "dsp/coach/CoachAdvisor.h"
#include "dsp/coach/CoachAnalyzer.h"
#include "dsp/coach/CoachTarget.h"
#include "dsp/coach/SplatterMeter.h"

class QTimer;

namespace lyra::dsp { class WdspEngine; }
namespace lyra::recorder { class RecorderEngine; }

namespace lyra::ui {

class EssbCoachModel : public QObject {
    Q_OBJECT
    // Band centres (Hz) and the per-band curves (dB, mid-band mean = 0).
    Q_PROPERTY(QVariantList bandsHz READ bandsHz NOTIFY updated)
    Q_PROPERTY(QVariantList liveDb READ liveDb NOTIFY updated)
    Q_PROPERTY(QVariantList baselineDb READ baselineDb NOTIFY updated)
    Q_PROPERTY(QVariantList recheckDb READ recheckDb NOTIFY updated)
    Q_PROPERTY(QVariantList targetDb READ targetDb NOTIFY updated)   // at each band centre
    Q_PROPERTY(QVariantList tolDb READ tolDb NOTIFY updated)         // +-, at each band centre
    // RX1 passband (absolute audio Hz); bands outside it are not judged.
    Q_PROPERTY(double rxLowHz READ rxLowHz NOTIFY updated)
    Q_PROPERTY(double rxHighHz READ rxHighHz NOTIFY updated)
    // Confidence: gated speech seconds of the curve in use, baseline median SNR.
    Q_PROPERTY(double speechSec READ speechSec NOTIFY updated)
    Q_PROPERTY(double snrDb READ snrDb NOTIFY updated)
    Q_PROPERTY(QString edgesText READ edgesText NOTIFY updated)
    // {lowHz, highHz, lowBeyondRx, highBeyondRx, tier, tierName}; lowHz/highHz NaN = none.
    Q_PROPERTY(QVariantMap edges READ edges NOTIFY updated)
    // {gapToSpeechDb, gapRiseDb, crestDb, pauses}; NaN = not measured.
    Q_PROPERTY(QVariantMap metrics READ metrics NOTIFY updated)
    // {valid, marginDb, alert, peakDb, outDb, noiseDb, status}.  status:
    // "measured" (valid), "pending" (fed, no valid result yet: under 3 s
    // since a restart, no signal above the floor, or the out window does not
    // fit the IQ span), "stale" (nothing fed for 1 s: transmitting, or the
    // tap stopped), "am" (not measured in AM/SAM) or "practice" (not measured
    // in the practice loop: no TX filter in the loop).  "measured" and "pending"
    // pass the meter's result through (valid is false while pending); "stale",
    // "am" and "practice" are blanked, and the advisor and the report see the same result.
    Q_PROPERTY(QVariantMap splatter READ splatter NOTIFY updated)
    Q_PROPERTY(QStringList adviceLines READ adviceLines NOTIFY updated)
    // Re-check minus baseline per zone: [{zone, label, db}], zone = bass|lowMid|body|upper|top.
    Q_PROPERTY(QVariantList zoneDeltas READ zoneDeltas NOTIFY updated)
    // [{id, name, builtin}] and the selected id (default "essb").
    Q_PROPERTY(QVariantList targets READ targets NOTIFY updated)
    Q_PROPERTY(QString targetId READ targetId WRITE setTargetId NOTIFY updated)
    // true = advice names Lyra's controls; false = plain "other rig" wording.
    Q_PROPERTY(bool lyraAdvice READ lyraAdvice WRITE setLyraAdvice NOTIFY updated)
    // AvgState as int: 0 Idle, 1 Running, 2 Stopped.
    Q_PROPERTY(int baselineState READ baselineState NOTIFY updated)
    Q_PROPERTY(int recheckState READ recheckState NOTIFY updated)
    Q_PROPERTY(bool frozen READ frozen NOTIFY updated)
    // false on a desk-side Lyra (the coach only runs where the radio is).
    Q_PROPERTY(bool available READ available NOTIFY updated)
    // true while the AGC gain reaching the coach is the gain WDSP applied
    // (compression readings are corrected for our own AGC).  False on
    // Windows/Linux builds and while stages with unknown latency run.
    Q_PROPERTY(bool agcCorrected READ agcCorrected NOTIFY updated)
    // true when compression advice is withheld because AGC correction is not
    // in effect and AGC is not Off ("Set AGC to Off ...").  Never while
    // transmitting or with no RX audio (nothing is being corrected then).
    Q_PROPERTY(bool agcFallback READ agcFallback NOTIFY updated)
    // true when AGC is Off yet the gain still cannot be aligned (a
    // post-AGC stage with unknown latency runs): compression is unavailable
    // and shows a dash.  unalignedStage names the stage ("" = unknown).
    Q_PROPERTY(bool compressionUnavailable READ compressionUnavailable NOTIFY updated)
    Q_PROPERTY(QString unalignedStage READ unalignedStage NOTIFY updated)
    // true when the dock was hidden while a baseline / re-check was running:
    // the taps were detached, so that time was not measured.  Cleared by the
    // next start / stop / make-baseline / reset.
    Q_PROPERTY(bool pausedWhileHidden READ pausedWhileHidden NOTIFY updated)
    // true while we transmit (WdspEngine::coachTxGated: keyed, the RX un-mute
    // delay and a 300 ms hold): the coach is fed no-information blocks.
    Q_PROPERTY(bool transmitting READ transmitting NOTIFY updated)
    // true when the analyzer has published nothing for 1 s while the panel is
    // open (radio connected but no RX audio arriving).
    Q_PROPERTY(bool noAudio READ noAudio NOTIFY updated)
    // Short note for the panel: post-AGC level changes are not corrected.
    Q_PROPERTY(QString holdNote READ holdNote CONSTANT)
    Q_PROPERTY(bool recording READ recording NOTIFY updated)
    // Editable thresholds/zone edges (QSettings essbCoach/<key>); keys below.
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY updated)
    // [{key, min, max, def}] for the settings above.
    Q_PROPERTY(QVariantList settingDefs READ settingDefs CONSTANT)
    // true while the practice loop feeds the coach (see PRACTICE MODE).
    Q_PROPERTY(bool practice READ practice NOTIFY updated)

public:
    explicit EssbCoachModel(QObject *parent = nullptr);
    ~EssbCoachModel() override;

    // MainWindow wiring.  The engine is the only source of RX conditions and
    // the tap attach point; the recorder is optional.
    void setEngine(lyra::dsp::WdspEngine *engine);
    void setRecorder(lyra::recorder::RecorderEngine *rec);
    // Current RX1 frequency (Hz), for the report header.
    void setFreqProvider(std::function<qint64()> fn) { freqProvider_ = std::move(fn); }
    // false = desk-side Lyra: the taps are detached and the panel says so.
    void setAvailable(bool on);
    // The RX1 frequency changed: the splatter meter's average no longer
    // describes the new channel (restart() re-arms its 3 s validity timer).
    void noteRx1FreqChanged();
    // Live TX filter edges (low, high; absolute audio Hz), used as the passband
    // while in practice.  Unset, or not 0 <= low < high: the RX passband stays.
    void setTxEdgesProvider(std::function<std::pair<double, double>()> fn)
    {
        txEdgesProvider_ = std::move(fn);
    }

    // PracticeLoop (GUI thread).  setPracticeMode enters / leaves practice;
    // both edges reset() the coach, so neither RX nor practice data carries
    // across.  Entering also begins the first pass.  The other three are
    // ignored outside practice.  side: 0 = A (baseline slot), 1 = B (re-check).
    void setPracticeMode(bool on);
    void practicePassStarted();
    void practicePassEnded(int side, bool clean);
    void clearPracticeSide(int side);
    // One report of the practice session (source "practice"): A as the
    // baseline, B as the re-check, through the same path, folder and naming
    // as the Stop reports ("recheck" when B has a curve, else "baseline").
    // No-op outside practice, when neither side has a curve, or when the
    // session recorder is not running.  PracticeLoop::save() calls it.
    Q_INVOKABLE void writePracticeReport();

    // MainWindow calls this with "the panel is open" (dock checked and its
    // window visible).  Attaches / detaches the taps and runs the 40 ms poll
    // only while open.  on=false is debounced (300 ms; on=true cancels it) so
    // a dock re-parent / float / tab move does not detach or flag a pause.
    Q_INVOKABLE void setActive(bool on);

    Q_INVOKABLE void startBaseline();
    Q_INVOKABLE void stopBaseline();
    Q_INVOKABLE void startRecheck();
    Q_INVOKABLE void stopRecheck();
    Q_INVOKABLE void makeBaseline();       // promote the re-check to the baseline
    Q_INVOKABLE void reset();              // analyzer + advisor + promoted state
    Q_INVOKABLE void setFrozen(bool on);
    Q_INVOKABLE void captureAsTarget(const QString &name);
    Q_INVOKABLE void deleteTarget(const QString &id);
    Q_INVOKABLE void toggleRecord();
    // keys: minSpeechSec, minSnrDb, gapToSpeechDb, gapRiseDb, crestDb,
    // zone0Hz..zone4Hz (lower edge of Bass, Low-mid, Body, Upper, Top).
    Q_INVOKABLE void setSetting(const QString &key, double value);
    Q_INVOKABLE void resetSettings();

    QVariantList bandsHz() const { return bandsHz_; }
    QVariantList liveDb() const { return liveDb_; }
    QVariantList baselineDb() const { return baselineDb_; }
    QVariantList recheckDb() const { return recheckDb_; }
    QVariantList targetDb() const { return targetDb_; }
    QVariantList tolDb() const { return tolDb_; }
    double rxLowHz() const { return rx_.rxLowHz; }
    double rxHighHz() const { return rx_.rxHighHz; }
    double speechSec() const { return speechSec_; }
    double snrDb() const { return snrDb_; }
    QString edgesText() const { return edgesText_; }
    QVariantMap edges() const { return edges_; }
    QVariantMap metrics() const { return metrics_; }
    QVariantMap splatter() const { return splatter_; }
    QStringList adviceLines() const { return adviceLines_; }
    QVariantList zoneDeltas() const { return zoneDeltas_; }
    QVariantList targets() const;
    QString targetId() const { return QString::fromStdString(target().id); }
    void setTargetId(const QString &id);
    bool lyraAdvice() const { return lyraAdvice_; }
    void setLyraAdvice(bool on);
    int baselineState() const { return static_cast<int>(view_.baseline); }
    int recheckState() const { return static_cast<int>(view_.recheck); }
    bool frozen() const { return view_.frozen; }
    bool available() const { return available_; }
    bool agcCorrected() const { return agcCorrected_; }
    bool agcFallback() const { return agcFallback_; }
    bool compressionUnavailable() const { return compressionUnavailable_; }
    QString unalignedStage() const { return unalignedStage_; }
    bool pausedWhileHidden() const { return pausedWhileHidden_; }
    bool transmitting() const { return transmitting_; }
    bool noAudio() const { return noAudio_; }
    QString holdNote() const;
    bool recording() const { return recording_; }
    QVariantMap settings() const;
    QVariantList settingDefs() const;
    bool practice() const { return practice_; }

signals:
    void updated();
    // The panel went from open to closed: the debounced setActive(false)
    // edge, the moment the taps detach.  A re-parent / float / tab move
    // inside the debounce window does not fire it.  PracticeLoop stops on it.
    void panelClosed();

private:
    struct SettingDef { const char *key; double lo, hi, def; };
    static const SettingDef kSettings[];
    static constexpr int kSettingCount = 10;

    void poll();
    void applyActive(bool on);
    void rebuild();
    void loadSettings();
    void markDirty();
    bool running() const { return active_ && available_ && engine_; }
    void ensureMeter();
    void applySettings();
    void loadTargets();
    const lyra::dsp::coach::Target &target() const;
    void attach();
    void detach();
    void syncSplatterChannel();
    void readConditions();
    void presentSplatter();
    void onTxEdge();
    void applyView(lyra::dsp::coach::CoachSnapshot &s) const;
    void beginPracticePass();
    void collectPracticeLap();
    void writeSessionReport(const QString &recording);
    void writeJson(const QString &name, const QJsonObject &obj);
    lyra::dsp::coach::Zone zoneAt(int i, double hiHz) const;
    std::vector<lyra::dsp::coach::Zone> zones() const;   // the five zones in use

    lyra::dsp::WdspEngine *engine_ = nullptr;
    lyra::recorder::RecorderEngine *rec_ = nullptr;
    std::function<qint64()> freqProvider_;
    QTimer *timer_ = nullptr;
    QTimer *offTimer_ = nullptr;   // debounced setActive(false)

    // Heap-owned for the model's whole life (see LIFETIME).
    std::unique_ptr<lyra::dsp::coach::CoachAnalyzer> analyzer_;
    std::unique_ptr<lyra::dsp::coach::SplatterMeter> meter_;
    lyra::dsp::coach::CoachAdvisor advisor_;
    lyra::dsp::coach::CoachThresholds thresholds_;
    double zoneLo_[5] = {};

    bool active_ = false;
    bool available_ = true;
    bool attachedMeter_ = false;
    bool dirty_ = true;
    int preparedRate_ = 0;
    int unalignedTicks_ = 0;
    bool lyraAdvice_ = true;
    bool agcCorrected_ = false, agcFallback_ = false;
    bool compressionUnavailable_ = false;
    QString unalignedStage_;
    bool pausedWhileHidden_ = false;
    bool transmitting_ = false, noAudio_ = false;
    // Monotonic ms (clock_) of the last analyzer / meter publish; a result
    // older than kStaleMs is not shown.  Seeded on attach.
    QElapsedTimer clock_;
    qint64 lastAudioMs_ = 0, lastSplatterMs_ = 0;

    std::vector<lyra::dsp::coach::Target> targets_;   // built-ins first, then custom
    int targetIdx_ = 0;

    // Last published raw state + the model-side view adjustments for
    // "make baseline" (the analyzer has no promote operation).
    lyra::dsp::coach::CoachSnapshot snap_, view_;
    // spRaw_ = the meter's last result; sp_ = what the panel, advisor and
    // report use (spRaw_, or blank when spStatus_ is not measured/pending).
    lyra::dsp::coach::SplatterResult spRaw_, sp_;
    QString spStatus_ = QStringLiteral("pending");
    lyra::dsp::coach::RxConditions rx_;
    bool promoted_ = false;       // baseline fields below replace the analyzer's
    std::vector<double> promBaseDb_;
    double promSpeechSec_ = 0.0;
    lyra::dsp::coach::CompressionMetrics promComp_;
    bool recheckMasked_ = false;  // re-check hidden until the next startRecheck() runs
    bool unmaskPending_ = false;  // startRecheck() issued; unmask once the snapshot shows Running

    // Splatter channel last handed to the meter.
    bool chValid_ = false, chUsb_ = true;
    double chShift_ = 0.0, chEdge_ = 0.0;

    // Derived, published to QML.
    QVariantList bandsHz_, liveDb_, baselineDb_, recheckDb_, targetDb_, tolDb_;
    double speechSec_ = 0.0, snrDb_ = NAN;
    QString edgesText_;
    QVariantMap edges_, metrics_, splatter_;
    QStringList adviceLines_;
    QVariantList zoneDeltas_;
    std::vector<lyra::dsp::coach::Finding> findings_;
    std::vector<QString> findingText_;
    lyra::dsp::coach::Edges edgesRaw_;
    std::vector<std::pair<lyra::dsp::coach::ZoneId, double>> deltasRaw_;

    // Session record.
    bool recording_ = false;
    int reportSeq_ = 0;
    QString pendingReport_;       // "baseline" | "recheck": write once it reads Stopped

    // Practice mode (see PRACTICE MODE).
    struct PracticeStore {
        bool has = false;
        std::vector<double> db;
        double speechSec = 0.0;
        lyra::dsp::coach::CompressionMetrics comp;
    };
    struct PracticeWant { std::uint64_t id; int side; };
    std::function<std::pair<double, double>()> txEdgesProvider_;
    bool practice_ = false;
    PracticeStore store_[2];              // 0 = A, 1 = B
    std::uint64_t passId_ = 0;            // re-check id of the pass in progress; 0 = not captured
    std::uint64_t lastLapId_ = 0;         // newest lap already looked at
    std::vector<PracticeWant> wanted_;    // clean passes ended, lap not seen yet (ascending id)
};

}  // namespace lyra::ui

// Lyra-cpp — eSSB practice loop: the controller.  See PracticeLoop.h.

#include "tx/PracticeLoop.h"

#include "essbcoachmodel.h"
#include "hl2_stream.h"
#include "profile/ProfileManager.h"
#include "tx/ClipBank.h"
#include "tx/ClipRecorder.h"
#include "tx/ClipRecorderPlayer.h"
#include "tx/VoiceKeyer.h"
#include "wdsp_engine.h"

#include <QDateTime>
#include <QTimer>

#include <cmath>
#include <utility>

namespace lyra::tx {

namespace {

int sideIndex(RackAbSwitch::Side s) { return s == RackAbSwitch::Side::A ? 0 : 1; }

QString noteNoHl2()    { return PracticeLoop::tr("Practice needs an HL2 connection."); }
QString noteCantRun()  { return PracticeLoop::tr("Practice needs the HL2 connected, receiving, and a voice mode."); }
QString noteKeyed()    { return PracticeLoop::tr("Stopped — the radio keyed."); }
QString noteNoAb()     { return PracticeLoop::tr("Save a profile first to use A/B."); }
QString noteTooShort() { return PracticeLoop::tr("Practice clip too short — record at least 15 s."); }
QString noteVox()      { return PracticeLoop::tr("Turn VOX off to use practice."); }

} // namespace

PracticeLoop::PracticeLoop(VoiceKeyer *keyer, ClipBank *bank,
                           lyra::profile::ProfileManager *profiles,
                           lyra::ui::EssbCoachModel *coach,
                           lyra::dsp::WdspEngine *engine,
                           PracticeBindings bindings,
                           QObject *parent)
    : QObject(parent), keyer_(keyer), bank_(bank), profiles_(profiles),
      coach_(coach), engine_(engine), b_(std::move(bindings)),
      // The switch only runs while abAvailable, which needs both rack seams
      // (storedRack); the guards keep an empty seam from ever being called.
      ab_([this] { return b_.captureRack ? b_.captureRack() : RackState{}; },
          [this](const RackState &s) { if (b_.applyRack) b_.applyRack(s); }) {
    poll_ = new QTimer(this);
    poll_->setInterval(kPollMs);
    connect(poll_, &QTimer::timeout, this, &PracticeLoop::onPoll);

    countdown_ = new QTimer(this);
    countdown_->setInterval(1000);   // 1 Hz get-set countdown
    connect(countdown_, &QTimer::timeout, this, &PracticeLoop::onCountdownTick);

    // A different active name ends the session (A would be stale):
    //   * the session's profile still exists → another profile was loaded
    //     (or saved as a new name), which already replaced or saved the live
    //     rack, so B is NOT put back: the live rack stays;
    //   * it no longer exists → it was renamed or deleted, which applies
    //     nothing, so B goes back live as on any other stop.
    // The SAME name is a save (saveActive from any panel) or a reload of the
    // stored profile: the stored rack is the new A, and the loop goes on.
    if (profiles_) {
        connect(profiles_, &lyra::profile::ProfileManager::activeChanged, this,
                [this](const QString &name) {
                    if (!looping_) return;
                    if (name != sessionProfile_) {
                        if (profiles_->names().contains(sessionProfile_))
                            stopLoop(tr("Stopped — a different profile was loaded."),
                                     /*restoreB=*/false);
                        else
                            stopLoop(tr("Stopped — the profile was renamed or deleted."));
                        return;
                    }
                    RackState a;
                    if (!ab_.active() || !storedRack(a)) return;
                    // On A the label moves to B with no apply: discard the
                    // pass in progress like a flip.
                    if (ab_.side() == RackAbSwitch::Side::A) tracker_.onFlip();
                    ab_.setA(a);
                    if (coach_) coach_->clearPracticeSide(0);
                    emit changed();
                });
    }
}

PracticeLoop::~PracticeLoop() {
    // No signals out of a dying object: tear down without emitting.
    blockSignals(true);
    stopLoop(QString());
    if (countdown_) countdown_->stop();
    if (recording_ && keyer_ && keyer_->recorder())
        keyer_->recorder()->stop();   // discard: the bank may already be gone
}

// ── properties ──

int PracticeLoop::recordMs() const {
    if (!recording_ || !keyer_ || !keyer_->recorder()) return 0;
    return keyer_->recorder()->durationMs();
}

int PracticeLoop::side() const {
    return ab_.active() ? sideIndex(ab_.side()) : 1;
}

double PracticeLoop::progress() const {
    if (!looping_ || !keyer_ || !keyer_->player()) return 0.0;
    return keyer_->player()->progress();
}

// ── helpers ──

void PracticeLoop::setNote(const QString &n) {
    note_ = n;
}

bool PracticeLoop::keyedNow() const {
    auto *s = b_.stream ? b_.stream() : nullptr;
    return s && s->keyIntentOrMox();
}

bool PracticeLoop::voxOn() const {
    return b_.voxEnabled && b_.voxEnabled();
}

bool PracticeLoop::keyerBusy() const {
    if (!keyer_) return true;
    if (keyer_->recording() || keyer_->counting() || !keyer_->playingId().isEmpty())
        return true;
    if (keyer_->player() && keyer_->player()->active()) return true;
    if (keyer_->recorder() && keyer_->recorder()->recording()) return true;
    return false;
}

bool PracticeLoop::storedRack(RackState &out) const {
    if (!profiles_ || !b_.captureRack || !b_.applyRack) return false;
    const QString name = profiles_->activeName();
    if (name.isEmpty()) return false;
    const lyra::profile::Profile p = profiles_->storedProfile(name);
    // A profile without the rack blobs (pre-v3) cannot be A: loadState of an
    // empty blob leaves the live stage as is, so "A" would play B.
    if (p.eq.isEmpty() || p.speech.isEmpty() || p.combinator.isEmpty() || p.plate.isEmpty())
        return false;
    out = RackState{p.eq, p.speech, p.combinator, p.plate};
    return true;
}

// ── record ──

void PracticeLoop::startRecord() {
    if (recording_ || countdownSec_ > 0) return;
    if (looping_) return;
    if (!keyer_ || !keyer_->recorder() || !bank_) return;
    if (keyerBusy()) {
        setNote(tr("The voice keyer is busy."));
        emit changed();
        return;
    }
    if (!b_.stream || !b_.stream()) {
        setNote(noteNoHl2());
        emit changed();
        return;
    }
    if (!b_.canRun || !b_.canRun()) {
        setNote(noteCantRun());
        emit changed();
        return;
    }
    if (voxOn()) {
        setNote(noteVox());
        emit changed();
        return;
    }

    // The label names the source the clip is recorded from, fixed now.
    const QString profile = (profiles_ && !profiles_->activeName().isEmpty())
                                ? profiles_->activeName()
                                : QStringLiteral("no profile");
    const QString src = b_.micSource ? b_.micSource() : QString();
    recordLabel_ = QStringLiteral("Practice: %1 (%2) %3")
                       .arg(profile, src,
                            QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm")));
    setNote(QString());

    const int delay = keyer_->recordDelaySec();   // read only; never changed here
    if (delay > 0) {
        countdownSec_ = delay;
        countdown_->start();
        emit changed();
        return;
    }
    startRecordNow();
}

void PracticeLoop::onCountdownTick() {
    if (countdownSec_ <= 0) { countdown_->stop(); return; }
    if (--countdownSec_ > 0) { emit changed(); return; }
    countdown_->stop();
    // Re-check: the keyer or the radio may have changed during the countdown.
    if (looping_ || keyerBusy() || !b_.canRun || !b_.canRun() || voxOn()) {
        setNote(keyerBusy() ? tr("The voice keyer is busy.")
                : voxOn()   ? noteVox()
                            : noteCantRun());
        emit changed();
        return;
    }
    startRecordNow();
}

void PracticeLoop::startRecordNow() {
    if (!keyer_ || !keyer_->recorder()) return;
    keyer_->recorder()->start(ClipRecorder::Source::Mic,
                              kMaxClipSec * ClipRecorder::sampleRate());
    recording_ = true;
    poll_->start();
    emit changed();
}

void PracticeLoop::stopRecord() {
    if (countdownSec_ > 0) {             // cancel the countdown
        countdown_->stop();
        countdownSec_ = 0;
        emit changed();
        return;
    }
    if (!recording_) return;
    recording_ = false;
    std::vector<float> samples;
    if (keyer_ && keyer_->recorder()) samples = keyer_->recorder()->stop();
    if (!looping_) poll_->stop();

    const std::size_t minSamples =
        static_cast<std::size_t>(kMinClipSec) * ClipRecorder::sampleRate();
    if (samples.size() < minSamples) {
        setNote(noteTooShort());
    } else if (!bank_) {
        setNote(tr("Could not save the practice clip."));
    } else {
        const QString id = bank_->addFromSamples(recordLabel_, ClipBank::Voice, samples);
        if (id.isEmpty()) {
            setNote(tr("Could not save the practice clip."));
        } else {
            clipId_ = id;
            setNote(QString());
        }
    }
    emit changed();
}

// ── loop ──

void PracticeLoop::play(const QString &clipId) {
    if (looping_ || recording_ || countdownSec_ > 0) return;
    if (!keyer_ || !keyer_->player() || !bank_ || !engine_ || !coach_) return;

    lyra::ipc::HL2Stream *stream = b_.stream ? b_.stream() : nullptr;
    if (!stream) {
        setNote(noteNoHl2());
        emit changed();
        return;
    }
    if (stream->keyIntentOrMox()) {
        setNote(tr("Practice cannot start while the radio is keyed."));
        emit changed();
        return;
    }
    if (!b_.canRun || !b_.canRun()) {
        setNote(noteCantRun());
        emit changed();
        return;
    }
    if (voxOn()) {
        setNote(noteVox());
        emit changed();
        return;
    }
    if (keyerBusy()) {
        setNote(tr("The voice keyer is busy."));
        emit changed();
        return;
    }
    auto samples = bank_->loadSamples(clipId);
    if (!samples || samples->empty()) {
        setNote(tr("Could not load the practice clip."));
        emit changed();
        return;
    }

    ClipRecorderPlayer *player = keyer_->player();
    ClipRecorderPlayer::PlayOptions opt;
    opt.ota       = false;   // never key
    opt.loop      = true;
    opt.bypassDsp = false;   // the rack always runs
    opt.gainLin   = std::pow(10.0, bank_->gainDbOf(clipId) / 20.0);

    // The air guard goes in BEFORE the first block can play.  Lock-free
    // atomic reads (and, on a refusal, one atomic flush request) only: it
    // runs on the cm TX thread under the player mutex.  The refusal flushes
    // the Plate before this same block reaches it, so the clip's reverb
    // tail never meets the live mic that now flows to TXA.
    player->setRefuseFn([stream, flush = b_.flushRackTail] {
        if (!stream->keyIntentOrMox()) return false;
        if (flush) flush();
        return true;
    });
    // Our own reference: the player may drop its copy on the cm thread.
    clipHold_ = samples;
    if (!player->play(std::move(samples), opt)) {
        player->setRefuseFn({});
        clipHold_.reset();
        setNote(tr("Could not start the loop."));
        emit changed();
        return;
    }

    looping_        = true;
    clipId_         = clipId;
    lastPass_       = 0;
    sessionProfile_ = profiles_ ? profiles_->activeName() : QString();
    // If the stream object goes away mid-loop, drop the guard that points at it.
    streamGone_ = connect(stream, &QObject::destroyed, this,
                          [this] { stopLoop(noteNoHl2()); });

    engine_->setPracticeActive(true);
    coach_->setPracticeMode(true);   // starts the first pass itself

    RackState a;
    if (storedRack(a)) {
        ab_.begin(a);
        setNote(QString());
    } else {
        setNote(noteNoAb());
    }
    tracker_.reset();
    tracker_.onPassStart(ab_.active() ? ab_.side() : RackAbSwitch::Side::B);

    poll_->start();
    emit changed();
}

void PracticeLoop::stop() {
    if (countdownSec_ > 0 || recording_) stopRecord();
    stopLoop(QString());
}

void PracticeLoop::stopLoop(const QString &note, bool restoreB) {
    if (!looping_) return;
    looping_ = false;
    disconnect(streamGone_);
    if (keyer_ && keyer_->player()) {
        // Stop first, then drop the guard: no block may play unguarded.
        keyer_->player()->stop();
        keyer_->player()->setRefuseFn({});
    }
    // The clip's reverb tail must not outlive the loop (the radio may key
    // next).  Consumed on the cm TX thread before the Plate's next block.
    if (b_.flushRackTail) b_.flushRackTail();
    clipHold_.reset();                            // freed here, on the GUI thread
    if (restoreB) ab_.end();                      // B back live
    else          ab_.abandon();                  // keep the live rack
    if (engine_) engine_->setPracticeActive(false);
    if (coach_)  coach_->setPracticeMode(false);
    tracker_.reset();
    lastPass_       = 0;
    sessionProfile_.clear();
    if (!recording_) poll_->stop();
    if (!note.isNull()) setNote(note);
    emit changed();
}

void PracticeLoop::onKeyIntent() {
    if (looping_) stopLoop(noteKeyed());
}

void PracticeLoop::stopForVox() {
    const bool was = looping_ || recording_ || countdownSec_ > 0;
    if (countdownSec_ > 0 || recording_) stopRecord();   // saved if >= 15 s
    stopLoop(QString());
    if (was) {
        setNote(noteVox());
        emit changed();
    }
}

void PracticeLoop::onVoxEnabled(bool on) {
    if (on) stopForVox();
}

void PracticeLoop::onCoachClosed() {
    const bool was = looping_ || recording_ || countdownSec_ > 0;
    if (countdownSec_ > 0 || recording_) stopRecord();   // saved if >= 15 s
    stopLoop(QString());
    if (was) {
        setNote(tr("Practice stopped — the coach panel was closed."));
        emit changed();
    }
}

void PracticeLoop::endPass() {
    const auto r = tracker_.onPassEnd();
    if (coach_) coach_->practicePassEnded(sideIndex(r.side), r.clean);
    const auto next = ab_.active() ? ab_.side() : RackAbSwitch::Side::B;
    tracker_.onPassStart(next);
    if (coach_) coach_->practicePassStarted();
}

void PracticeLoop::onPoll() {
    // VOX switched on by any path (the signal is the primary stop).
    if ((recording_ || looping_) && voxOn()) { stopForVox(); return; }
    if (recording_) {
        if (keyer_ && keyer_->recorder() && keyer_->recorder()->full()) {
            stopRecord();   // auto-stop + save at the 30 s cap
            return;
        }
        emit changed();     // recordMs
    }
    if (!looping_) return;

    ClipRecorderPlayer *player = keyer_ ? keyer_->player() : nullptr;
    if (!player) { stopLoop(noteNoHl2()); return; }
    // A loop never ends on its own: an inactive player was refused (keyed)
    // or stopped elsewhere (e.g. the voice keyer's Stop).  Either way tear
    // down now; the note says "keyed" whenever the key is still up.
    if (keyedNow()) { stopLoop(noteKeyed()); return; }
    if (!player->active()) {
        stopLoop(tr("Practice stopped — the clip player was stopped."));
        return;
    }
    if (!b_.stream || !b_.stream()) { stopLoop(noteNoHl2()); return; }
    if (!b_.canRun || !b_.canRun()) { stopLoop(noteCantRun()); return; }

    const unsigned n = player->passCount();
    while (lastPass_ != n) {
        ++lastPass_;
        endPass();
    }
    emit changed();         // progress / passes
}

// ── A/B ──

void PracticeLoop::flip() {
    if (!looping_ || !ab_.active()) return;
    ab_.flip();
    tracker_.onFlip();
    emit changed();
}

void PracticeLoop::noteRackEdit() {
    if (!looping_) return;
    if (ab_.noteEdit()) {
        tracker_.onEdit();
        if (coach_) coach_->clearPracticeSide(1);
        emit changed();
    }
}

void PracticeLoop::save() {
    if (!looping_ || !ab_.active() || !profiles_) return;
    if (profiles_->activeName().isEmpty()) {
        setNote(noteNoAb());
        emit changed();
        return;
    }
    // Save writes B: on A, put B back live first (counts as a flip, so the
    // pass in progress is discarded).
    returnToBForSave(ab_, tracker_);
    if (coach_) coach_->writePracticeReport();
    profiles_->saveActive();                 // re-emits activeChanged(same name)
    ab_.setA(b_.captureRack ? b_.captureRack() : RackState{});
    if (coach_) coach_->clearPracticeSide(0);
    emit changed();
}

} // namespace lyra::tx

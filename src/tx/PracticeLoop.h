// Lyra-cpp — eSSB practice loop: the controller (QML context property
// `Practice`).
//
// Design: docs/superpowers/specs/2026-10-27-essb-practice-loop-design.md.
//
// The operator records a 15–30 s clip from the selected mic source, then
// loops it UNKEYED through the native TX rack (Speech → EQ → Combinator →
// Plate).  The engine plays the post-rack monitor on the local output while
// practice is active, and the eSSB Coach graphs it: A = the active profile's
// saved rack, B = the live edits.  Flipping A/B swaps exactly the four rack
// blobs (RackAbSwitch); only whole passes played on one side with no flip or
// edit reach the graph (PracticePassTracker).
//
// SAFETY — the clip never reaches the air:
//   * the clip plays with ota = false (no key) and bypassDsp = false;
//   * the player's refuse fn (HL2Stream::keyIntentOrMox, lock-free) is
//     installed BEFORE play(): the injector goes Idle on the first TX block
//     where a key is requested or MOX is up;
//   * play() is refused while keyIntentOrMox() is already true;
//   * practice (record or loop) is refused while VOX is enabled, and turning
//     VOX on stops it: VOX could key on the mic picking up the loop, and
//     anti-VOX hears RX, not the practice monitor;
//   * every refusal and every stop asks for a Plate flush
//     (PracticeBindings::flushRackTail), so the clip's reverb tail is gone
//     before TXA starts (~65 ms after the key intent).  The flush is an
//     atomic request the cm TX thread consumes right before the Plate's next
//     block; nothing here touches the Plate's state;
//   * PracticeLoop keeps its own reference to the clip until the loop ends,
//     so the player dropping it on the cm thread never frees it there;
//   * onKeyIntent (HL2Stream::moxIntentPulse) and the 50 ms poll stop the
//     loop on the earliest key intent; any path where the player stopped on
//     its own runs stop(), which puts B back live (RackAbSwitch::end) and
//     clears WdspEngine::setPracticeActive(false) at once (the engine plays
//     the monitor on the headphones for as long as practice is active).
//
// Decoupled like ProfileManager/ProfileBindings: the collaborators are
// pointers handed in by MainWindow, and everything MainWindow-specific
// (which stream, mode, mic source, the four rack models) arrives through the
// PracticeBindings seams.  GUI-thread only.

#pragma once

#include "tx/PracticePassTracker.h"
#include "tx/RackAbSwitch.h"

#include <QObject>
#include <QPointer>
#include <QString>

#include <functional>
#include <memory>
#include <vector>

class QTimer;

namespace lyra::dsp     { class WdspEngine; }
namespace lyra::ipc     { class HL2Stream; }
namespace lyra::profile { class ProfileManager; }
namespace lyra::ui      { class EssbCoachModel; }

namespace lyra::tx {

class ClipBank;
class VoiceKeyer;

// MainWindow supplies these (Task 6).  Every one may be empty; an empty seam
// fails safe (no stream → unavailable, canRun → false, rack → no A/B).
struct PracticeBindings {
    // The live HL2 stream, or nullptr (no HL2 / a non-HL2 protocol).  Read
    // at every check, so a reconnect that replaces the stream is followed.
    std::function<lyra::ipc::HL2Stream *()> stream;
    // HL2 present, voice mode, radio streaming, not keyed.
    std::function<bool()> canRun;
    // The selected TX mic source ("mic1" / "tci" / "micpc" / "micpc2"),
    // shown in the clip label.
    std::function<QString()> micSource;
    // The four rack models' saveState() / loadState().
    std::function<RackState()> captureRack;
    std::function<void(const RackState &)> applyRack;
    // True while VOX is enabled (practice refuses to run with VOX on).
    std::function<bool()> voxEnabled;
    // Ask the TX Plate to clear its delay lines before its next block
    // (PlateModel::requestTxFlush).  Called from the GUI thread AND from the
    // cm TX thread (inside the refuse fn), so it must be lock-free and
    // allocation-free: one atomic store.
    std::function<void()> flushRackTail;
};

class PracticeLoop : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool    recording    READ recording    NOTIFY changed)
    Q_PROPERTY(int     recordMs     READ recordMs     NOTIFY changed)
    // Seconds left in the get-set countdown before recording (0 = none).
    Q_PROPERTY(int     countdownSec READ countdownSec NOTIFY changed)
    Q_PROPERTY(bool    looping      READ looping      NOTIFY changed)
    Q_PROPERTY(QString clipId       READ clipId       NOTIFY changed)
    Q_PROPERTY(int     side         READ side         NOTIFY changed)   // 0 A / 1 B
    Q_PROPERTY(bool    abAvailable  READ abAvailable  NOTIFY changed)
    Q_PROPERTY(QString note         READ note         NOTIFY changed)
    Q_PROPERTY(double  progress     READ progress     NOTIFY changed)
    Q_PROPERTY(int     passes       READ passes       NOTIFY changed)
public:
    static constexpr int kMinClipSec = 15;
    static constexpr int kMaxClipSec = 30;
    static constexpr int kPollMs     = 50;

    PracticeLoop(VoiceKeyer *keyer, ClipBank *bank,
                 lyra::profile::ProfileManager *profiles,
                 lyra::ui::EssbCoachModel *coach,
                 lyra::dsp::WdspEngine *engine,
                 PracticeBindings bindings,
                 QObject *parent = nullptr);
    ~PracticeLoop() override;

    bool    recording()    const { return recording_; }
    int     recordMs()     const;
    int     countdownSec() const { return countdownSec_; }
    bool    looping()      const { return looping_; }
    QString clipId()       const { return clipId_; }
    int     side()         const;
    bool    abAvailable()  const { return looping_ && ab_.active(); }
    QString note()         const { return note_; }
    double  progress()     const;
    int     passes()       const { return looping_ ? static_cast<int>(lastPass_) : 0; }

    // Record a practice clip (after the voice keyer's get-set countdown).
    // stopRecord saves it if it is at least kMinClipSec long; during the
    // countdown it cancels.  Auto-stops at kMaxClipSec.
    Q_INVOKABLE void startRecord();
    Q_INVOKABLE void stopRecord();
    // Loop `clipId` unkeyed through the rack.  stop() is idempotent: it ends
    // the loop (and a practice recording or countdown) and does nothing
    // when practice is idle — it never touches a voice-keyer playback.
    Q_INVOKABLE void play(const QString &clipId);
    Q_INVOKABLE void stop();
    // A/B: swap the live rack between the saved rack (A) and the edits (B).
    Q_INVOKABLE void flip();
    // Write the practice report, save the live rack into the active profile,
    // and make it the new A.
    Q_INVOKABLE void save();

public slots:
    // Connect to the rack models' change signals (DIRECT connections: the
    // A/B switch ignores the signals its own apply emits only while the
    // apply is on the stack).
    void noteRackEdit();
    // Connect to HL2Stream::moxIntentPulse: any key request stops the loop.
    void onKeyIntent();
    // The coach panel closed (EssbCoachModel::panelClosed, or an explicit
    // dock close): end the loop and any practice recording, with a note.
    void onCoachClosed();
    // Connect to HL2Stream::voxEnabledChanged: VOX on ends practice.
    void onVoxEnabled(bool on);

signals:
    void changed();

private:
    void onPoll();
    void onCountdownTick();
    void startRecordNow();
    void endPass();
    // The loop teardown behind stop(); `note` replaces the note when set.
    // `restoreB` false leaves the live rack as it is (a profile load: the
    // loaded profile replaced the operator's B and must stay live).
    void stopLoop(const QString &note, bool restoreB = true);
    // End a practice recording or countdown and the loop because VOX is on.
    void stopForVox();
    bool voxOn() const;
    void setNote(const QString &n);
    bool keyedNow() const;
    bool keyerBusy() const;
    // The active profile's saved rack; false when there is no active
    // profile or it carries no rack blobs.
    bool storedRack(RackState &out) const;

    QPointer<VoiceKeyer>                    keyer_;
    QPointer<ClipBank>                      bank_;
    QPointer<lyra::profile::ProfileManager> profiles_;
    QPointer<lyra::ui::EssbCoachModel>      coach_;
    QPointer<lyra::dsp::WdspEngine>         engine_;
    PracticeBindings                        b_;

    RackAbSwitch        ab_;
    PracticePassTracker tracker_;

    QTimer  *poll_      = nullptr;
    QTimer  *countdown_ = nullptr;

    bool     recording_    = false;
    int      countdownSec_ = 0;
    QString  recordLabel_;          // fixed when recording starts
    bool     looping_      = false;
    QString  clipId_;
    QString  note_;
    QString  sessionProfile_;       // active profile when the loop started
    QMetaObject::Connection streamGone_;   // the looping stream's destroyed()
    unsigned lastPass_     = 0;     // player passCount() already handled
    // The looping clip, held until the loop ends: the player's own reference
    // may be dropped on the cm TX thread (refuse path), and this one keeps
    // that drop from freeing the samples there.
    std::shared_ptr<const std::vector<float>> clipHold_;
};

} // namespace lyra::tx

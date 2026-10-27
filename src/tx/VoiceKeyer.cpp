// Lyra-cpp — #89 Voice keyer, Stage B (B4): panel controller.  See VoiceKeyer.h.

#include "tx/VoiceKeyer.h"

#include "tx/ClipBank.h"
#include "tx/ClipRecorder.h"
#include "tx/ClipRecorderPlayer.h"

#include <QAudioDevice>
#include <QAudioFormat>
#include <QAudioSink>
#include <QBuffer>
#include <QByteArray>
#include <QDesktopServices>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QMediaDevices>
#include <QSettings>
#include <QTimer>
#include <QUrl>

#include <algorithm>
#include <cmath>

namespace lyra::tx {

VoiceKeyer::VoiceKeyer(ClipBank *bank, QObject *parent)
    : QObject(parent), bank_(bank),
      player_(std::make_unique<ClipRecorderPlayer>()),
      recorder_(std::make_unique<ClipRecorder>()) {
    load();
    poll_ = new QTimer(this);
    poll_->setInterval(80);   // progress / record-elapsed poll while active
    connect(poll_, &QTimer::timeout, this, &VoiceKeyer::onPollTick);

    countdown_ = new QTimer(this);
    countdown_->setInterval(1000);   // 1 Hz pre-record "get set" countdown
    connect(countdown_, &QTimer::timeout, this, &VoiceKeyer::onCountdownTick);
}

int VoiceKeyer::recordMs() const {
    return recorder_ ? recorder_->durationMs() : 0;
}

VoiceKeyer::~VoiceKeyer() {
    if (player_) player_->stop();
    if (recorder_ && recorder_->recording()) recorder_->stop();
    if (reviewSink_) reviewSink_->stop();   // sink + buffer are this-parented
}

double VoiceKeyer::progress() const {
    if (reviewSink_ && reviewBuf_ && !reviewingId_.isEmpty()) {
        const qint64 totalSamples = reviewBuf_->size() / 2;   // int16 mono
        const double totalUs = static_cast<double>(totalSamples) * 1e6 / 48000.0;
        if (totalUs <= 0.0) return 0.0;
        return std::clamp(static_cast<double>(reviewSink_->processedUSecs()) / totalUs,
                          0.0, 1.0);
    }
    return player_ ? player_->progress() : 0.0;
}

void VoiceKeyer::setGainDb(double db) {
    db = std::clamp(db, -40.0, 20.0);
    if (std::abs(db - gainDb_) < 1e-9) return;
    gainDb_ = db;
    save();
    // Ride an in-progress OTA transmission live (not just on the next play).
    if (player_ && player_->playing() && !playingId_.isEmpty()) {
        const double clip = bank_ ? bank_->gainDbOf(playingId_) : 0.0;
        player_->setGain(std::pow(10.0, (gainDb_ + clip) / 20.0));
    }
    emit gainDbChanged();
}

void VoiceKeyer::setBypassDsp(bool on) {
    if (on == bypassDsp_) return;
    bypassDsp_ = on;
    save();
    emit bypassDspChanged();
}

void VoiceKeyer::setRecordMaxSec(int s) {
    s = std::clamp(s, 5, 300);
    if (s == recordMaxSec_) return;
    recordMaxSec_ = s;
    save();
    emit recordMaxSecChanged();
}

void VoiceKeyer::setRecordDelaySec(int s) {
    s = std::clamp(s, 0, 30);
    if (s == recordDelaySec_) return;
    recordDelaySec_ = s;
    save();
    emit recordDelaySecChanged();
}

void VoiceKeyer::setLive(bool on) {
    if (on == live_) return;
    live_ = on;
    save();
    emit liveChanged();
}

void VoiceKeyer::play(const QString &id, bool ota) {
    if (!live_ || !bank_ || !player_) return;   // gated on the operator opt-in
    if (lockout_ && lockout_()) return;         // practice owns the player
    if (!ota && !reviewReady()) return;         // local Review lands in Stage C
    auto samples = bank_->loadSamples(id);
    if (!samples || samples->empty()) return;

    const double clipGainDb = bank_->gainDbOf(id);
    ClipRecorderPlayer::PlayOptions opt;
    opt.ota       = ota;
    opt.bypassDsp = bypassDsp_;   // the voice keyer's single Bypass-TX-DSP toggle
    opt.gainLin   = std::pow(10.0, (gainDb_ + clipGainDb) / 20.0);

    if (!player_->play(std::move(samples), opt)) return;   // busy / key-blocked
    playingId_ = id;
    ota_       = ota;
    poll_->start();
    emit playingChanged();
    emit progressChanged();
}

void VoiceKeyer::stop() {
    if (player_) player_->stop();
    if (!playingId_.isEmpty()) {
        playingId_.clear();
        emit playingChanged();
    }
    stopReview();          // stops the local sink + clears reviewingId_ + manages poll
    emit progressChanged();
}

void VoiceKeyer::onPollTick() {
    // Auto-stop + save when the capture hits the operator's max-record length.
    if (recording_ && recorder_ && recorder_->full()) {
        stopRecord(QString());
        return;
    }
    bool active = false;
    if (recording_) { emit recordMsChanged(); active = true; }
    if (reviewSink_ && !reviewingId_.isEmpty()) { emit progressChanged(); active = true; }
    if (player_ && player_->playing()) { emit progressChanged(); active = true; }
    else if (!playingId_.isEmpty()) {   // clip finished / drained on its own
        playingId_.clear();
        emit playingChanged();
        emit progressChanged();
    }
    if (!active) poll_->stop();
}

// ── C3 — local Review: play a clip through a QAudioSink (default output).  No
// key, no TX, no injector — so it never touches the wire TX ring.  Applies the
// same global + per-clip gain as OTA. ──
void VoiceKeyer::reviewLocal(const QString &id) {
    if (!bank_) return;
    if (lockout_ && lockout_()) return;           // practice is playing / recording
    stopReview();                                 // restart cleanly if re-clicked
    auto samples = bank_->loadSamples(id);
    if (!samples || samples->empty()) return;

    const double gainLin = std::pow(10.0, (gainDb_ + bank_->gainDbOf(id)) / 20.0);

    // 48 kHz mono, 16-bit PCM.
    QByteArray pcm;
    pcm.resize(static_cast<int>(samples->size()) * 2);
    auto *out = reinterpret_cast<qint16 *>(pcm.data());
    for (std::size_t i = 0; i < samples->size(); ++i) {
        const double s = std::clamp(static_cast<double>((*samples)[i]) * gainLin, -1.0, 1.0);
        out[i] = static_cast<qint16>(s * 32767.0);
    }

    const QAudioDevice dev = QMediaDevices::defaultAudioOutput();
    if (dev.isNull()) return;

    QAudioFormat fmt;
    fmt.setSampleRate(48000);
    fmt.setChannelCount(1);
    fmt.setSampleFormat(QAudioFormat::Int16);

    reviewBuf_ = new QBuffer(this);
    reviewBuf_->setData(pcm);
    reviewBuf_->open(QIODevice::ReadOnly);

    reviewSink_ = new QAudioSink(dev, fmt, this);
    connect(reviewSink_, &QAudioSink::stateChanged, this, [this](QAudio::State st) {
        // Clip finished (Idle) or the device errored/stopped → tear down.
        if (st == QAudio::IdleState || st == QAudio::StoppedState)
            stopReview();
    });

    reviewingId_ = id;
    reviewSink_->start(reviewBuf_);
    poll_->start();
    emit playingChanged();
    emit progressChanged();
}

void VoiceKeyer::stopReview() {
    if (reviewSink_) {
        auto *s = reviewSink_;
        reviewSink_ = nullptr;                    // null first so re-entry is safe
        s->disconnect(this);                      // no stateChanged re-trigger on stop
        s->stop();
        s->deleteLater();
    }
    if (reviewBuf_) {
        reviewBuf_->close();
        reviewBuf_->deleteLater();
        reviewBuf_ = nullptr;
    }
    bool was = !reviewingId_.isEmpty();
    reviewingId_.clear();
    if (player_ && !player_->playing() && !recording_) poll_->stop();
    if (was) { emit playingChanged(); emit progressChanged(); }
}

// ── Record (Stage C).  kind 0 = Voice (mic), 1 = RX (needs the RX tap, C2). ──
// Runs the optional get-set countdown first; a second call while counting
// cancels it (the panel routes that here).
void VoiceKeyer::startRecord(int kind) {
    if (!recorder_ || recording_) return;
    if (lockout_ && lockout_()) return;   // practice owns the recorder
    if (counting_) { cancelCountdown(); return; }
    if (recordDelaySec_ > 0) {
        pendingKind_  = kind;
        countdownSec_ = recordDelaySec_;
        counting_     = true;
        countdown_->start();
        emit countingChanged();
        emit countdownChanged();
        return;
    }
    startRecordNow(kind);
}

void VoiceKeyer::startRecordNow(int kind) {
    if (!recorder_ || recording_) return;
    if (lockout_ && lockout_()) return;   // practice started during the countdown
    const int maxSamples = recordMaxSec_ * ClipRecorder::sampleRate();
    recorder_->start(kind == 1 ? ClipRecorder::Source::Rx : ClipRecorder::Source::Mic,
                     maxSamples);
    recording_ = true;
    poll_->start();
    emit recordingChanged();
    emit recordMsChanged();
}

void VoiceKeyer::onCountdownTick() {
    if (!counting_) return;
    if (--countdownSec_ <= 0) {
        countdown_->stop();
        counting_ = false;
        emit countingChanged();
        emit countdownChanged();
        startRecordNow(pendingKind_);
    } else {
        emit countdownChanged();
    }
}

void VoiceKeyer::cancelCountdown() {
    if (!counting_) return;
    countdown_->stop();
    counting_     = false;
    countdownSec_ = 0;
    emit countingChanged();
    emit countdownChanged();
}

void VoiceKeyer::stopRecord(const QString &label) {
    if (!recorder_ || !recording_) return;
    const ClipRecorder::Source src = recorder_->source();
    std::vector<float> samples = recorder_->stop();
    recording_ = false;
    if (player_ && !player_->playing()) poll_->stop();
    if (!samples.empty() && bank_) {
        const int kind = (src == ClipRecorder::Source::Rx) ? ClipBank::Rx : ClipBank::Voice;
        QString lbl = label.trimmed();
        if (lbl.isEmpty())
            lbl = tr("Message %1").arg(bank_->clips().size() + 1);
        bank_->addFromSamples(lbl, kind, samples);
    }
    emit recordingChanged();
    emit recordMsChanged();
}

// ── Clip-management dialogs (GUI thread) ──
void VoiceKeyer::importClipDialog() {
    if (!bank_) return;
    const QString path = QFileDialog::getOpenFileName(
        nullptr, tr("Import voice clip"), QString(),
        tr("Audio clips (*.wav *.WAV)"));
    if (path.isEmpty()) return;
    const QString label = QFileInfo(path).completeBaseName();
    bank_->importWav(label, ClipBank::Voice, path);   // normalised to 48k mono
}

void VoiceKeyer::openClipsFolder() const {
    if (!bank_) return;
    QDir().mkpath(bank_->clipsDir());
    QDesktopServices::openUrl(QUrl::fromLocalFile(bank_->clipsDir()));
}

void VoiceKeyer::changeClipsFolderDialog() {
    if (!bank_) return;
    const QString dir = QFileDialog::getExistingDirectory(
        nullptr, tr("Choose clips folder"), bank_->clipsDir());
    if (!dir.isEmpty()) bank_->setClipsDir(dir);
}

void VoiceKeyer::playByFkey(int fn) {
    if (!live_ || !bank_) return;
    const QString id = bank_->idForFkey(fn);
    if (!id.isEmpty()) playOta(id);
}

// ── persistence (QSettings clips/*) ──
void VoiceKeyer::load() {
    QSettings s;
    s.beginGroup(QStringLiteral("clips"));
    gainDb_    = std::clamp(s.value(QStringLiteral("playbackGainDb"), 0.0).toDouble(),
                            -40.0, 20.0);
    bypassDsp_ = s.value(QStringLiteral("bypassDsp"), false).toBool();
    live_      = s.value(QStringLiteral("txEnabled"), false).toBool();   // opt-in, default OFF
    recordMaxSec_ = std::clamp(s.value(QStringLiteral("recordMaxSec"), 300).toInt(), 5, 300);
    recordDelaySec_ = std::clamp(s.value(QStringLiteral("recordDelaySec"), 0).toInt(), 0, 30);
    s.endGroup();
}

void VoiceKeyer::save() const {
    QSettings s;
    s.beginGroup(QStringLiteral("clips"));
    s.setValue(QStringLiteral("playbackGainDb"), gainDb_);
    s.setValue(QStringLiteral("bypassDsp"), bypassDsp_);
    s.setValue(QStringLiteral("txEnabled"), live_);
    s.setValue(QStringLiteral("recordMaxSec"), recordMaxSec_);
    s.setValue(QStringLiteral("recordDelaySec"), recordDelaySec_);
    s.endGroup();
}

} // namespace lyra::tx

// Lyra — QSO state tracker (RX-side).
//
// A pure CONSUMER of decoded CW text: it taps the same WdspEngine decoded-text
// signals the CW Decoder panel shows (cwDecodedChar / cwNeuralText /
// cwAutoText), never the audio thread or the decode pipeline, so it cannot
// perturb any of the three decoders (Classic fldigi / DeepFist / Auto).
//
// Decoded text streams in character-by-character (or in short fragments); we
// accumulate it and treat a PAUSE in the copy (segmentTimer_) as the end of a
// "message".  Each complete message drives a small QSO state machine
//   Idle -> CqDetected -> Replied -> ExchangingReports -> Conversation
//           -> Closing -> Complete
// and fills the "current contact" row (their call / RST / name / QTH / DXCC),
// so the operator sees who they're working and where the QSO stands.  Ported
// in spirit from smartsdr-mcp's QsoTracker; the extraction heuristics are the
// same regex family (callsign, 3-digit RST, NAME/QTH keywords).
//
// Threading: everything here runs on the GUI thread — feedText() is called
// from the QML Connections that marshal WdspEngine's signals, so no locking is
// needed (unlike CwMacroModel there is no keyer to drive).

#pragma once

#include <QDateTime>
#include <QObject>
#include <QString>
#include <QStringList>

#include "dxcc.h"

class QTimer;

namespace lyra::ui {

class QsoTracker : public QObject {
    Q_OBJECT
    Q_PROPERTY(int     stage     READ stage     NOTIFY stageChanged)
    Q_PROPERTY(QString stageName READ stageName NOTIFY stageChanged)
    Q_PROPERTY(QString theirCall READ theirCall WRITE setTheirCall NOTIFY contactChanged)
    Q_PROPERTY(QString theirRst  READ theirRst  NOTIFY contactChanged)
    Q_PROPERTY(QString theirName READ theirName NOTIFY contactChanged)
    Q_PROPERTY(QString theirQth  READ theirQth  NOTIFY contactChanged)
    Q_PROPERTY(QString theirDxcc READ theirDxcc NOTIFY contactChanged)
    // The operator's own call — bound from QML to Prefs.callsign.  Used to tell
    // "CQ ... DE W1AW" (someone calling CQ) from "N9BC DE W1AW" (a reply to us).
    Q_PROPERTY(QString myCall    READ myCall    WRITE setMyCall NOTIFY myCallChanged)
public:
    // Kept in sync with the QML stage-pill order and stageName().
    enum Stage {
        Idle = 0,
        CqDetected,
        Replied,
        ExchangingReports,
        Conversation,
        Closing,
        Complete
    };
    Q_ENUM(Stage)

    explicit QsoTracker(QObject *parent = nullptr);

    int     stage() const { return int(stage_); }
    QString stageName() const;
    QString theirCall() const { return theirCall_; }
    QString theirRst()  const { return theirRst_; }
    QString theirName() const { return theirName_; }
    QString theirQth()  const { return theirQth_; }
    QString theirDxcc() const { return theirDxcc_; }
    QString myCall()    const { return myCall_; }

    void setMyCall(const QString &s);
    // Operator double-clicked a call in the decoder transcript — seed the
    // contact directly (and, from Idle, arm the machine at CqDetected).
    void setTheirCall(const QString &s);

    // Fed decoded text from any engine.  Appends to the message buffer and
    // (re)starts the pause timer; the buffered message is processed on timeout.
    Q_INVOKABLE void feedText(const QString &s);

    // Clear the contact + return to Idle (new QSO / the panel's Reset chip).
    Q_INVOKABLE void reset();

signals:
    void stageChanged();
    void contactChanged();
    void myCallChanged();

private:
    // Called when the pause timer fires: run the state machine on one message.
    void processMessage(const QString &message);
    // The state-machine transition for one received message (upper-cased).
    void advanceStage(const QString &upper);

    // ── extraction helpers (operate on upper-cased text) ──
    static QStringList extractCallsigns(const QString &upper);
    QString extractStationCall(const QString &upper) const;   // the OTHER call
    static bool    isCq(const QString &upper);
    // Does this message carry a signal report (RST)?  Gates the move into
    // ExchangingReports.  TODO(human) — see QsoTracker.cpp.
    bool    containsSignalReport(const QString &upper) const;
    static QString extractRst(const QString &upper);
    static QString extractName(const QString &upper);
    static QString extractQth(const QString &upper);

    void setStage(Stage s);
    void setContact(const QString &call, const QString &rst,
                    const QString &name, const QString &qth);

    Stage     stage_ = Idle;
    QString   theirCall_;
    QString   theirRst_;
    QString   theirName_;
    QString   theirQth_;
    QString   theirDxcc_;
    QString   myCall_;
    QDateTime startTime_;

    QString   buffer_;                 // the message being accumulated
    QTimer   *segmentTimer_ = nullptr; // a pause in the copy ends a message
    DxccLookup dxcc_;                  // own instance (leaf utility, cheap)
};

} // namespace lyra::ui

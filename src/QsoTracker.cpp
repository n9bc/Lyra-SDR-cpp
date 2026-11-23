// Lyra — QSO state tracker (RX-side).  See QsoTracker.h.

#include "QsoTracker.h"

#include <QRegularExpression>
#include <QTimer>

namespace lyra::ui {

namespace {
// A pause in the copy this long ends the current "message" and runs the state
// machine on it.  ~2.5 s is longer than a word gap at typical hand speeds but
// short enough that the panel keeps up with an over.
constexpr int kSegmentPauseMs = 2500;
} // namespace

QsoTracker::QsoTracker(QObject *parent) : QObject(parent) {
    segmentTimer_ = new QTimer(this);
    segmentTimer_->setSingleShot(true);
    segmentTimer_->setInterval(kSegmentPauseMs);
    connect(segmentTimer_, &QTimer::timeout, this, [this] {
        const QString msg = buffer_;
        buffer_.clear();
        processMessage(msg);
    });
}

QString QsoTracker::stageName() const {
    switch (stage_) {
    case Idle:              return QStringLiteral("Idle");
    case CqDetected:        return QStringLiteral("CQ detected");
    case Replied:           return QStringLiteral("Replied");
    case ExchangingReports: return QStringLiteral("Exchanging");
    case Conversation:      return QStringLiteral("Conversation");
    case Closing:           return QStringLiteral("Closing");
    case Complete:          return QStringLiteral("Complete");
    }
    return QString();
}

void QsoTracker::setMyCall(const QString &s) {
    const QString up = s.trimmed().toUpper();
    if (up == myCall_) return;
    myCall_ = up;
    emit myCallChanged();
}

void QsoTracker::setTheirCall(const QString &s) {
    const QString up = s.trimmed().toUpper();
    if (up.isEmpty()) return;
    setContact(up, QString(), QString(), QString());
    // Operator picked a call out of the copy — arm the QSO if it was idle.
    if (stage_ == Idle) {
        startTime_ = QDateTime::currentDateTimeUtc();
        setStage(CqDetected);
    }
}

void QsoTracker::feedText(const QString &s) {
    if (s.isEmpty()) return;
    buffer_ += s;
    segmentTimer_->start();   // (re)arm the pause timer
}

void QsoTracker::reset() {
    buffer_.clear();
    segmentTimer_->stop();
    theirCall_.clear();
    theirRst_.clear();
    theirName_.clear();
    theirQth_.clear();
    theirDxcc_.clear();
    startTime_ = QDateTime();
    emit contactChanged();
    setStage(Idle);
}

void QsoTracker::processMessage(const QString &message) {
    const QString upper = message.toUpper().simplified();
    if (upper.isEmpty()) return;
    advanceStage(upper);
}

void QsoTracker::advanceStage(const QString &upper) {
    const bool mentionsUs = !myCall_.isEmpty() && upper.contains(myCall_);

    switch (stage_) {
    case Idle:
        // A CQ, or our own call in the copy, starts a QSO.
        if (isCq(upper) || mentionsUs) {
            setContact(extractStationCall(upper), QString(), QString(), QString());
            startTime_ = QDateTime::currentDateTimeUtc();
            setStage(CqDetected);
        }
        break;

    case CqDetected:
    case Replied:
        // A signal report moves us into the exchange; otherwise just keep the
        // other station's call fresh as it's copied again.
        if (containsSignalReport(upper)) {
            setContact(extractStationCall(upper), extractRst(upper),
                       QString(), QString());
            setStage(ExchangingReports);
        } else {
            const QString call = extractStationCall(upper);
            if (!call.isEmpty())
                setContact(call, QString(), QString(), QString());
        }
        break;

    case ExchangingReports:
        // Reports done — pull any name/QTH and settle into ragchew.
        setContact(QString(), QString(), extractName(upper), extractQth(upper));
        setStage(Conversation);
        break;

    case Conversation:
        // Sign-off cues close the QSO; otherwise keep enriching name/QTH.
        if (upper.contains(QStringLiteral("73")) ||
            upper.contains(QStringLiteral("SK")) ||
            upper.contains(QStringLiteral("TU"))) {
            setStage(Closing);
        } else {
            setContact(QString(), QString(), extractName(upper), extractQth(upper));
        }
        break;

    case Closing:
        setStage(Complete);
        break;

    case Complete:
        break;
    }
}

// ── extraction helpers ──────────────────────────────────────────────────────

QStringList QsoTracker::extractCallsigns(const QString &upper) {
    static const QRegularExpression re(
        QStringLiteral("\\b(\\d?[A-Z]{1,2}\\d+[A-Z]{1,4})\\b"));
    QStringList out;
    auto it = re.globalMatch(upper);
    while (it.hasNext()) {
        const QString c = it.next().captured(1);
        if (c.size() >= 3 && c.size() <= 8 && !out.contains(c))
            out << c;
    }
    return out;
}

QString QsoTracker::extractStationCall(const QString &upper) const {
    QStringList calls = extractCallsigns(upper);
    if (!myCall_.isEmpty())
        calls.removeAll(myCall_);               // never report our own call back
    if (calls.isEmpty()) return QString();

    // Prefer the call right after "DE " (the sender identifying themselves).
    const int de = upper.indexOf(QStringLiteral("DE "));
    if (de >= 0) {
        const QStringList after = extractCallsigns(upper.mid(de + 3));
        for (const QString &c : after)
            if (c != myCall_) return c;
    }
    return calls.first();
}

bool QsoTracker::isCq(const QString &upper) {
    return upper.trimmed().startsWith(QStringLiteral("CQ"));
}

bool QsoTracker::containsSignalReport(const QString &upper) const {
    // A clean 3-digit RST (R 1-5, S/T 1-9, e.g. 599 / 579) is the strong
    // signal; the contest shorthand 5NN (N == 9 cut number) is the common
    // other form.  We require one of these two — not a bare "RST" keyword —
    // so a stray number in a QTH or a bare "73" doesn't trip the advance.
    static const QRegularExpression rst(QStringLiteral("\\b[1-5][1-9][1-9]\\b"));
    return rst.match(upper).hasMatch() ||
           upper.contains(QStringLiteral("5NN"));
}

QString QsoTracker::extractRst(const QString &upper) {
    static const QRegularExpression re(QStringLiteral("\\b[1-5][1-9][1-9]\\b"));
    const auto m = re.match(upper);
    return m.hasMatch() ? m.captured(0) : QString();
}

QString QsoTracker::extractName(const QString &upper) {
    static const QRegularExpression re(
        QStringLiteral("NAME\\s+(?:IS\\s+)?([A-Z]{2,})"));
    const auto m = re.match(upper);
    return m.hasMatch() ? m.captured(1) : QString();
}

QString QsoTracker::extractQth(const QString &upper) {
    static const QRegularExpression re(
        QStringLiteral("QTH\\s+(?:IS\\s+)?([A-Z]{2,})"));
    const auto m = re.match(upper);
    return m.hasMatch() ? m.captured(1) : QString();
}

// ── state / contact mutation ────────────────────────────────────────────────

void QsoTracker::setStage(Stage s) {
    if (s == stage_) return;
    stage_ = s;
    emit stageChanged();
}

void QsoTracker::setContact(const QString &call, const QString &rst,
                            const QString &name, const QString &qth) {
    bool changed = false;
    if (!call.isEmpty() && call != theirCall_) {
        theirCall_ = call;
        theirDxcc_ = dxcc_.isoOf(call);   // "" if unknown
        changed = true;
    }
    if (!rst.isEmpty()  && rst  != theirRst_)  { theirRst_  = rst;  changed = true; }
    if (!name.isEmpty() && name != theirName_) { theirName_ = name; changed = true; }
    if (!qth.isEmpty()  && qth  != theirQth_)  { theirQth_  = qth;  changed = true; }
    if (changed) emit contactChanged();
}

} // namespace lyra::ui

// Lyra — VFO tuning core.  See freqdisplay.h.

#include "freqdisplay.h"
#include "vfo_digit_hit.h"
#include "vfo_snap.h"
#include "wheel_steps.h"

#include <QCursor>
#include <QHoverEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QWheelEvent>

#include <algorithm>

namespace lyra::ui {

namespace {
int placeStep(int idx) {   // 10^idx, idx in [0, 9]
    int s = 1;
    for (int i = 0; i < idx; ++i) s *= 10;
    return s;
}

// Steps for a wheel event with no scroll phase (QML WheelHandler / HID):
// whole notches of 120, else one step in the delta's direction.
int wheelTicks(int angleDeltaY, int pixelDeltaY) {
    if (angleDeltaY <= -120 || angleDeltaY >= 120)
        return angleDeltaY / 120;
    if (angleDeltaY != 0)
        return angleDeltaY > 0 ? 1 : -1;
    if (pixelDeltaY != 0)
        return pixelDeltaY > 0 ? 1 : -1;
    return 0;
}

FreqDisplay *g_ledUnderMouse = nullptr;
} // namespace

FreqDisplay *FreqDisplay::ledUnderMouse() {
    return g_ledUnderMouse;
}

FreqDisplay::FreqDisplay(QQuickItem *parent) : QQuickItem(parent) {
    setAcceptedMouseButtons(Qt::LeftButton);
    setAcceptHoverEvents(true);
    setFlag(ItemAcceptsInputMethod, false);
}

FreqDisplay::~FreqDisplay() {
    if (g_ledUnderMouse == this)
        g_ledUnderMouse = nullptr;
}

void FreqDisplay::setFreqHz(int hz) {
    hz = std::clamp(hz, 0, kMaxHz);
    if (hz == freqHz_) {
        return;
    }
    freqHz_ = hz;
    emit freqHzChanged();           // NOTE: no freqEdited — external set
}

void FreqDisplay::setExternalStepHz(int hz) {
    hz = std::max(0, hz);
    if (hz == externalStepHz_) {
        return;
    }
    externalStepHz_ = hz;
    emit externalStepHzChanged();
}

void FreqDisplay::setStickyWheel(bool on) {
    if (on == stickyWheel_) {
        return;
    }
    stickyWheel_ = on;
    emit stickyWheelChanged();
}

void FreqDisplay::setDigitRects(const QVariantList &rects) {
    if (rects == digitRectsVar_) {
        return;
    }
    digitRectsVar_ = rects;
    rects_ = digitRectsFromVariant(rects, kNDigits);
    emit digitRectsChanged();
}

void FreqDisplay::setSelected(int place) {
    if (place == selected_) {
        return;
    }
    selected_ = place;
    emit selectedDigitChanged();
}

void FreqDisplay::changeFreq(int deltaHz) {
    const int nf = std::clamp(freqHz_ + deltaHz, 0, kMaxHz);
    if (nf == freqHz_) {
        return;
    }
    freqHz_ = nf;
    emit freqHzChanged();
    emit freqEdited(nf);            // user tuned — host pushes to Stream
}

int FreqDisplay::parseFreqInput(const QString &text) const {
    QString s = text;
    s.remove(' ');
    if (s.isEmpty()) {
        return -1;
    }
    // 2+ separators (any mix of , and .) = thousands separators → Hz.
    if ((s.count(QLatin1Char(',')) + s.count(QLatin1Char('.'))) > 1) {
        QString digits = s;
        digits.remove(QLatin1Char(',')).remove(QLatin1Char('.'));
        bool ok = false;
        const qlonglong v = digits.toLongLong(&ok);
        if (!ok) return -1;
        return static_cast<int>(std::clamp(v, qlonglong(0),
                                           qlonglong(FreqDisplay::kMaxHz)));
    }
    // Single separator = decimal point (MHz); comma is the Euro decimal.
    s.replace(QLatin1Char(','), QLatin1Char('.'));
    if (s.contains(QLatin1Char('.'))) {
        bool ok = false;
        const double mhz = s.toDouble(&ok);
        if (!ok) return -1;
        const qlonglong hz = qRound64(mhz * 1.0e6);
        return static_cast<int>(std::clamp(hz, qlonglong(0),
                                           qlonglong(FreqDisplay::kMaxHz)));
    }
    bool ok = false;
    const qlonglong n = s.toLongLong(&ok);
    if (!ok) {
        return -1;
    }
    qlonglong hz = n;
    if (n < 100)        hz = n * 1'000'000;   // MHz
    else if (n < 100'000) hz = n * 1'000;     // kHz
    return static_cast<int>(std::clamp(hz, qlonglong(0),
                                       qlonglong(FreqDisplay::kMaxHz)));
}

void FreqDisplay::mousePressEvent(QMouseEvent *e) {
    if (e->button() != Qt::LeftButton) {
        e->ignore();
        return;
    }
    g_ledUnderMouse = this;
    const int place = digitPlaceAt(rects_, e->position());
    if (place >= 0) {
        setSelected(place);
    }
    forceActiveFocus();
    e->accept();
}

void FreqDisplay::mouseDoubleClickEvent(QMouseEvent *e) {
    if (e->button() == Qt::LeftButton) {
        emit editRequested();
        e->accept();
        return;
    }
    e->ignore();
}

void FreqDisplay::hoverEnterEvent(QHoverEvent *e) {
    g_ledUnderMouse = this;
    QQuickItem::hoverEnterEvent(e);
}

void FreqDisplay::hoverLeaveEvent(QHoverEvent *e) {
    if (g_ledUnderMouse == this)
        g_ledUnderMouse = nullptr;
    QQuickItem::hoverLeaveEvent(e);
}

void FreqDisplay::handleWheel(int angleDeltaY, int pixelDeltaY, qreal x, qreal y) {
    g_ledUnderMouse = this;
    applyWheelAt(wheelTicks(angleDeltaY, pixelDeltaY), QPointF(x, y));
}

void FreqDisplay::nudgeByTicks(int ticks) {
    applyWheelAt(ticks, mapFromGlobal(QCursor::pos()));
}

void FreqDisplay::wheelEvent(QWheelEvent *e) {
    g_ledUnderMouse = this;
#if defined(Q_OS_MACOS)
    constexpr bool kNotchIsOneStep = true;
#else
    constexpr bool kNotchIsOneStep = false;
#endif
    const int units = wheelDigitSteps(e->angleDelta().y(), e->phase(),
                                      kNotchIsOneStep, wheelAccum_);
    if (units == 0) {
        e->ignore();
        return;
    }
    applyWheelAt(units, e->position());
    e->accept();
}

// Over a digit: step that place.  Elsewhere: this VFO's Tuning Step, snapped
// to its grid when stickyWheel is on.
void FreqDisplay::applyWheelAt(int ticks, QPointF pos) {
    if (ticks == 0) {
        return;
    }
    const int hover = digitPlaceAt(rects_, pos);
    if (hover >= 0) {
        setSelected(hover);
        changeFreq(ticks * placeStep(hover));
        return;
    }
    if (externalStepHz_ <= 0) {
        return;
    }
    const int next = nextWheelHz(freqHz_, externalStepHz_, ticks, stickyWheel_);
    changeFreq(next - freqHz_);
}

void FreqDisplay::keyPressEvent(QKeyEvent *e) {
    const int step = placeStep(std::max(0, selected_));
    switch (e->key()) {
    case Qt::Key_Up:    changeFreq(step);  break;
    case Qt::Key_Down:  changeFreq(-step); break;
    case Qt::Key_Left:  setSelected(std::min(kNDigits - 1, selected_ + 1)); break;
    case Qt::Key_Right: setSelected(std::max(0, selected_ - 1)); break;
    default:            QQuickItem::keyPressEvent(e); return;
    }
    e->accept();
}

} // namespace lyra::ui

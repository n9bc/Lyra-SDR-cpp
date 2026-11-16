// Lyra — manual-ATU tuning memory (Tuner panel).
//
// Up to 3 named antennas, each with a frequency-keyed table of manual
// tuner settings (Input / Output / Inductor + a note).  Tracks the live
// dial and surfaces the matching — or nearest — stored point so the
// operator can re-set a manual tuner without paper sheets, the way the
// 3rd-party "Tuner Reminder" (TCI) app does, but native: Lyra already
// knows the band / frequency / antenna, so there's no loopback.
//
// Pure UI + QSettings persistence; no DSP / wire involvement.  Exposed to
// QML (TunerPanel.qml) as the `Tuner` context property.  All native C++23.

#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>

namespace lyra::ipc { class HL2Stream; }

namespace lyra::ui {

class TunerMemory : public QObject {
    Q_OBJECT
    // The 3 antenna names (operator-renamable).
    Q_PROPERTY(QStringList antennaNames READ antennaNames NOTIFY antennasChanged)
    // Which antenna is active (0..2) — manual select; each has its own table.
    Q_PROPERTY(int activeAntenna READ activeAntenna WRITE setActiveAntenna
               NOTIFY activeChanged)
    // The active antenna's stored points, sorted by frequency.  Each entry is
    // a map { band, freqHz, freqText, input, output, inductor, note }.
    Q_PROPERTY(QVariantList points READ points NOTIFY pointsChanged)
    // Live match of the current dial against the active antenna:
    Q_PROPERTY(bool   matchValid   READ matchValid   NOTIFY matchChanged)
    Q_PROPERTY(bool   matchExact   READ matchExact   NOTIFY matchChanged)
    Q_PROPERTY(int    matchIndex   READ matchIndex   NOTIFY matchChanged)
    Q_PROPERTY(double matchFreqHz  READ matchFreqHz  NOTIFY matchChanged)
    Q_PROPERTY(double matchDeltaHz READ matchDeltaHz NOTIFY matchChanged)
    Q_PROPERTY(QString matchInput    READ matchInput    NOTIFY matchChanged)
    Q_PROPERTY(QString matchOutput   READ matchOutput   NOTIFY matchChanged)
    Q_PROPERTY(QString matchInductor READ matchInductor NOTIFY matchChanged)
    Q_PROPERTY(QString matchNote     READ matchNote     NOTIFY matchChanged)
    // Live dial (Hz) + its band label + formatted text.
    Q_PROPERTY(double  currentFreqHz READ currentFreqHz NOTIFY currentChanged)
    Q_PROPERTY(QString currentBand   READ currentBand   NOTIFY currentChanged)
    Q_PROPERTY(QString currentFreqText READ currentFreqText NOTIFY currentChanged)
    // Collapsed (basics-only) vs expanded (full table) — operator toggle.
    Q_PROPERTY(bool collapsed READ collapsed WRITE setCollapsed
               NOTIFY collapsedChanged)
    // Match window (Hz): within this of a stored point counts as an "exact"
    // (green) match; beyond it the nearest is shown amber with the delta.
    // Operator-configurable in Settings → Tuner.  Default 1000 Hz.
    Q_PROPERTY(double matchToleranceHz READ matchToleranceHz
               WRITE setMatchToleranceHz NOTIFY matchToleranceChanged)
    // Auto-select: switch to the best antenna whose band coverage includes
    // the current dial frequency when it leaves the active antenna's range.
    Q_PROPERTY(bool autoSelect READ autoSelect WRITE setAutoSelect
               NOTIFY autoSelectChanged)
    // Whether the active antenna covers the current dial frequency.
    Q_PROPERTY(bool activeCovers READ activeCovers NOTIFY matchChanged)

public:
    explicit TunerMemory(lyra::ipc::HL2Stream *stream,
                         QObject *parent = nullptr);

    QStringList antennaNames() const;
    int  activeAntenna() const { return active_; }
    void setActiveAntenna(int i);
    QVariantList points() const;
    bool   matchValid() const { return matchIdx_ >= 0; }
    bool   matchExact() const;
    int    matchIndex() const { return matchIdx_; }
    double matchFreqHz() const;
    double matchDeltaHz() const;
    QString matchInput() const;
    QString matchOutput() const;
    QString matchInductor() const;
    QString matchNote() const;
    double  currentFreqHz() const { return curHz_; }
    QString currentBand() const { return bandLabel(curHz_); }
    QString currentFreqText() const { return fmtFreq(curHz_); }
    bool collapsed() const { return collapsed_; }
    void setCollapsed(bool v);
    double matchToleranceHz() const { return matchToleranceHz_; }
    void   setMatchToleranceHz(double hz);
    bool   autoSelect() const { return autoSelect_; }
    void   setAutoSelect(bool on);
    bool   activeCovers() const;

    // Set the live dial (Hz); recomputes the match.  Driven from
    // HL2Stream::rx1FreqChanged, but Q_INVOKABLE so QML can drive it too.
    Q_INVOKABLE void setCurrentFreqHz(double hz);
    Q_INVOKABLE void renameAntenna(int i, const QString &name);
    Q_INVOKABLE void setBandCoverage(int i, double loHz, double hiHz);
    Q_INVOKABLE double antennaBandLo(int i) const;
    Q_INVOKABLE double antennaBandHi(int i) const;
    Q_INVOKABLE bool antennaCoversFreq(int i, double hz) const;
    // Insert or overwrite (within tolerance) a point at freqHz for the active
    // antenna.  Empty fields are allowed (operator fills them in later).
    Q_INVOKABLE void storePoint(double freqHz, const QString &input,
                                const QString &output, const QString &inductor,
                                const QString &note);
    // Edit an existing point's settings in place (active antenna, by row).
    Q_INVOKABLE void updatePoint(int index, const QString &input,
                                 const QString &output, const QString &inductor,
                                 const QString &note);
    // Full edit incl. the frequency (re-sorts) — used by the Settings editor.
    Q_INVOKABLE void editPoint(int index, double freqHz, const QString &input,
                               const QString &output, const QString &inductor,
                               const QString &note);
    Q_INVOKABLE void deletePoint(int index);
    // Clear every stored point for the active antenna.
    Q_INVOKABLE void clearActiveAntenna();
    // Point count for the active antenna (convenience for editors).
    Q_INVOKABLE int  pointCount() const;

    // Ham-band label for a frequency ("10 M", "40 M", …) or "" if unknown.
    Q_INVOKABLE static QString bandLabel(double freqHz);
    // Group a frequency as MHz.kHz.Hz — 28550774 -> "28.550.774".
    Q_INVOKABLE static QString fmtFreq(double freqHz);

signals:
    void antennasChanged();
    void activeChanged();
    void pointsChanged();
    void matchChanged();
    void currentChanged();
    void collapsedChanged();
    void matchToleranceChanged();
    void autoSelectChanged();
    void bandCoverageChanged();

private:
    struct Point {
        double  freqHz = 0.0;
        QString band, input, output, inductor, note;
    };
    struct Antenna {
        QString name;
        QVector<Point> points;
        double bandLoHz = 0.0;   // 0 = no coverage defined
        double bandHiHz = 0.0;
        bool coversFreq(double hz) const {
            return bandLoHz > 0 && bandHiHz > 0 && hz >= bandLoHz && hz <= bandHiHz;
        }
    };

    void recomputeMatch();
    void sortAntenna(int i);
    void save() const;
    void load();

    void autoSelectAntenna();
    QVector<Antenna> ant_;          // exactly kNumAntennas (4)
    int    active_   = 0;
    double curHz_    = 0.0;
    int    matchIdx_ = -1;          // nearest point in ant_[active_], or -1
    bool   collapsed_ = false;
    double matchToleranceHz_ = 1000.0;   // operator-set exact-match window
    bool   autoSelect_ = true;          // auto-switch antenna on band change

    // Two stored points closer than this are treated as the SAME point (a
    // re-store overwrites rather than adding a near-duplicate).  Fixed +
    // small + independent of the display match window, so the operator can
    // still keep distinct points a few kHz apart with a wide match window.
    static constexpr double kSameFreqHz = 100.0;
};

} // namespace lyra::ui

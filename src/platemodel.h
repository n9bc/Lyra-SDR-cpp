// Lyra — Plate model (#52).  The "model" half of the Plate model/view:
// owns a lyra::dsp::Plate engine and exposes it to QML (PlatePanel.qml) as
// the `Plate` context property.  Mirrors the EqModel/CombinatorModel idiom:
// Q_PROPERTY controls (shared paramsChanged NOTIFY) + a static txProcessCb /
// s_txEngine bridge (registered in main.cpp at Stage 3) + a W5UDX / N8SDR
// preset loader.  Default stage OFF (reverb on SSB is opt-in).

#pragma once

#include <QObject>
#include <QString>
#include <QJsonObject>

#include <atomic>

#include "dsp/Plate.h"

namespace lyra::ui {

class PlateModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool bypass READ bypass WRITE setBypass NOTIFY bypassChanged)
    Q_PROPERTY(double preDelayMs READ preDelayMs WRITE setPreDelayMs NOTIFY paramsChanged)
    Q_PROPERTY(double decayS READ decayS WRITE setDecayS NOTIFY paramsChanged)
    Q_PROPERTY(double damp READ damp WRITE setDamp NOTIFY paramsChanged)
    Q_PROPERTY(double size READ size WRITE setSize NOTIFY paramsChanged)
    Q_PROPERTY(double density READ density WRITE setDensity NOTIFY paramsChanged)
    Q_PROPERTY(double diff READ diff WRITE setDiff NOTIFY paramsChanged)
    Q_PROPERTY(double bassDb READ bassDb WRITE setBassDb NOTIFY paramsChanged)
    Q_PROPERTY(double trebDb READ trebDb WRITE setTrebDb NOTIFY paramsChanged)
    Q_PROPERTY(double mix READ mix WRITE setMix NOTIFY paramsChanged)

public:
    explicit PlateModel(QObject *parent = nullptr);
    ~PlateModel() override;

    static void txProcessCb(int nSamples, double *iqPairs);
    // Flush the TX plate's delay lines at the start of its next TX block
    // (Plate::requestReset).  Lock-free, allocation-free: callable from the
    // GUI or the cm TX thread.  No-op before the model exists.
    static void requestTxFlush() noexcept;

    // Live single instance (#49 profile capture/apply bridge).
    static PlateModel *instance() { return s_self; }

    bool   bypass()     const { return bypass_; }
    double preDelayMs() const { return preDelayMs_; }
    double decayS()     const { return decayS_; }
    double damp()       const { return damp_; }
    double size()       const { return size_; }
    double density()    const { return density_; }
    double diff()       const { return diff_; }
    double bassDb()     const { return bassDb_; }
    double trebDb()     const { return trebDb_; }
    double mix()        const { return mix_; }

    void setBypass(bool on);
    void setPreDelayMs(double ms);
    void setDecayS(double s);
    void setDamp(double v);
    void setSize(double v);
    void setDensity(double v);
    void setDiff(double v);
    void setBassDb(double db);
    void setTrebDb(double db);
    void setMix(double frac);

    // Load a locked preset (0 = W5UDX, 1 = N8SDR).  Sets the 8 reverb params
    // and leaves MIX alone (personal wet-level, not part of the capture).
    Q_INVOKABLE void loadPreset(int idx);
    Q_INVOKABLE QString presetName(int idx) const;

    lyra::dsp::Plate *engine() { return &plate_; }

    // Profile bundle (#49): serialize / restore the full plate state.
    QJsonObject saveState() const;
    void        loadState(const QJsonObject &o);

signals:
    void bypassChanged();
    void paramsChanged();

private:
    static std::atomic<lyra::dsp::Plate *> s_txEngine;
    static PlateModel *s_self;

    lyra::dsp::Plate plate_;

    bool   bypass_     = true;     // default OFF
    double preDelayMs_ = 10.0;
    double decayS_     = 1.542;    // N8SDR
    double damp_       = 15.0;
    double size_       = 10.0;
    double density_    = 20.0;
    double diff_       = 20.0;
    double bassDb_     = -16.0;
    double trebDb_     = 16.0;
    double mix_        = 0.07;     // 7 % — operator's personal wet level
};

}  // namespace lyra::ui

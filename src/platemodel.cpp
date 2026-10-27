// Lyra — PlateModel implementation.  See platemodel.h.

#include "platemodel.h"

namespace lyra::ui {

std::atomic<lyra::dsp::Plate *> PlateModel::s_txEngine{nullptr};
PlateModel *PlateModel::s_self = nullptr;

PlateModel::PlateModel(QObject *parent) : QObject(parent) {
    plate_.setSampleRate(48000.0);
    // Push the cached N8SDR default preset into the engine.
    plate_.setPreDelayS(preDelayMs_ / 1000.0);
    plate_.setDecayS(decayS_);
    plate_.setDamp(damp_);
    plate_.setSize(size_);
    plate_.setDensity(density_);
    plate_.setDiff(diff_);
    plate_.setBassDb(bassDb_);
    plate_.setTrebDb(trebDb_);
    plate_.setMix(mix_);
    plate_.setBypass(bypass_);     // default OFF

    s_txEngine.store(&plate_, std::memory_order_release);
    s_self = this;
}

PlateModel::~PlateModel() {
    s_txEngine.store(nullptr, std::memory_order_release);
    if (s_self == this) s_self = nullptr;
}

void PlateModel::txProcessCb(int nSamples, double *iqPairs) {
    auto *e = s_txEngine.load(std::memory_order_acquire);
    if (e) e->processInterleaved(iqPairs, nSamples);
}

void PlateModel::requestTxFlush() noexcept {
    auto *e = s_txEngine.load(std::memory_order_acquire);
    if (e) e->requestReset();
}

void PlateModel::setBypass(bool on) {
    if (on == bypass_) return;
    bypass_ = on; plate_.setBypass(on); emit bypassChanged();
}
void PlateModel::setPreDelayMs(double ms) {
    if (ms == preDelayMs_) return;
    preDelayMs_ = ms; plate_.setPreDelayS(ms / 1000.0); emit paramsChanged();
}
void PlateModel::setDecayS(double s) {
    if (s == decayS_) return;
    decayS_ = s; plate_.setDecayS(s); emit paramsChanged();
}
void PlateModel::setDamp(double v) {
    if (v == damp_) return;
    damp_ = v; plate_.setDamp(v); emit paramsChanged();
}
void PlateModel::setSize(double v) {
    if (v == size_) return;
    size_ = v; plate_.setSize(v); emit paramsChanged();
}
void PlateModel::setDensity(double v) {
    if (v == density_) return;
    density_ = v; plate_.setDensity(v); emit paramsChanged();
}
void PlateModel::setDiff(double v) {
    if (v == diff_) return;
    diff_ = v; plate_.setDiff(v); emit paramsChanged();
}
void PlateModel::setBassDb(double db) {
    if (db == bassDb_) return;
    bassDb_ = db; plate_.setBassDb(db); emit paramsChanged();
}
void PlateModel::setTrebDb(double db) {
    if (db == trebDb_) return;
    trebDb_ = db; plate_.setTrebDb(db); emit paramsChanged();
}
void PlateModel::setMix(double frac) {
    if (frac == mix_) return;
    mix_ = frac; plate_.setMix(frac); emit paramsChanged();
}

void PlateModel::loadPreset(int idx) {
    // 8 captured reverb params; MIX deliberately left at the operator's value.
    if (idx == 0) {            // W5UDX (Greg)
        preDelayMs_ = 10.0; decayS_ = 2.358; damp_ = 10.0; size_ = 33.0;
        density_ = 32.0; diff_ = 20.0; bassDb_ = -16.0; trebDb_ = 16.0;
    } else {                   // N8SDR personal
        preDelayMs_ = 10.0; decayS_ = 1.542; damp_ = 15.0; size_ = 10.0;
        density_ = 20.0; diff_ = 20.0; bassDb_ = -16.0; trebDb_ = 16.0;
    }
    plate_.setPreDelayS(preDelayMs_ / 1000.0);
    plate_.setDecayS(decayS_);
    plate_.setDamp(damp_);
    plate_.setSize(size_);
    plate_.setDensity(density_);
    plate_.setDiff(diff_);
    plate_.setBassDb(bassDb_);
    plate_.setTrebDb(trebDb_);
    emit paramsChanged();
}

QString PlateModel::presetName(int idx) const {
    return idx == 0 ? QStringLiteral("W5UDX") : QStringLiteral("N8SDR");
}

QJsonObject PlateModel::saveState() const {
    QJsonObject o;
    o["bypass"]     = bypass_;
    o["preDelayMs"] = preDelayMs_;
    o["decayS"]     = decayS_;
    o["damp"]       = damp_;
    o["size"]       = size_;
    o["density"]    = density_;
    o["diff"]       = diff_;
    o["bassDb"]     = bassDb_;
    o["trebDb"]     = trebDb_;
    o["mix"]        = mix_;
    return o;
}

void PlateModel::loadState(const QJsonObject &o) {
    if (o.isEmpty()) return;
    if (o.contains("preDelayMs")) setPreDelayMs(o["preDelayMs"].toDouble(preDelayMs_));
    if (o.contains("decayS"))     setDecayS(o["decayS"].toDouble(decayS_));
    if (o.contains("damp"))       setDamp(o["damp"].toDouble(damp_));
    if (o.contains("size"))       setSize(o["size"].toDouble(size_));
    if (o.contains("density"))    setDensity(o["density"].toDouble(density_));
    if (o.contains("diff"))       setDiff(o["diff"].toDouble(diff_));
    if (o.contains("bassDb"))     setBassDb(o["bassDb"].toDouble(bassDb_));
    if (o.contains("trebDb"))     setTrebDb(o["trebDb"].toDouble(trebDb_));
    if (o.contains("mix"))        setMix(o["mix"].toDouble(mix_));
    if (o.contains("bypass"))     setBypass(o["bypass"].toBool(bypass_));
}

}  // namespace lyra::ui

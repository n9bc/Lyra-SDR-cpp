// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md

#include "dsp/deepfist/DeepFistModel.h"

#include <algorithm>
#include <array>
#include <fstream>
#include <sstream>

#include <onnxruntime_cxx_api.h>

#include "dsp/deepfist/DeepFistCtc.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace lyra::dsp {

// ONNX Runtime handles kept out of the header.
struct DeepFistModel::Impl {
    Ort::Env      env{ORT_LOGGING_LEVEL_WARNING, "deepfist"};
    Ort::SessionOptions opts;
    std::unique_ptr<Ort::Session> session;
};

namespace {

// The canonical 48-token table (DeepFist sidecar order).  Used as a fallback if
// the sidecar can't be read; the sidecar is still the runtime source of truth.
std::vector<std::string> fallbackTokens() {
    std::vector<std::string> t = {"", " "};   // blank rendered empty, then space
    const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890.,?/=+-@";
    for (const char* p = chars; *p; ++p) t.emplace_back(1, *p);
    t.emplace_back("<SK>");
    t.emplace_back("<KN>");
    // 48 total: blank + space + A-Z(26) + digits(10) + ". , ? / = + - @"(8) + <SK> + <KN>
    return t;
}

// DeepCW's published 42-class table (deepcw-engine model.onnx.json "chars",
// blank_index 41), in model class order.  Fallback if the sidecar is missing.
std::vector<std::string> fallbackDeepCwChars() {
    std::vector<std::string> t;
    const char* chars = ",./0123456789?ABCDEFGHIJKLMNOPQRSTUVWXYZ ";
    for (const char* p = chars; *p; ++p) t.emplace_back(1, *p);
    return t;
}

std::string readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Minimal parse of a sidecar `"<key>": [...]` array of quoted strings.
// Avoids pulling a JSON lib into this DSP path; the format is fixed + simple.
// (No escape handling: neither model's tables contain quotes or backslashes.)
std::vector<std::string> parseSidecarTokens(const std::string& s,
                                            const char* keyName = "tokens") {
    if (s.empty()) return {};
    const std::string key = std::string("\"") + keyName + "\"";
    size_t k = s.find(key);
    if (k == std::string::npos) return {};
    size_t lb = s.find('[', k);
    size_t rb = s.find(']', lb == std::string::npos ? k : lb);
    if (lb == std::string::npos || rb == std::string::npos || rb < lb) return {};

    std::vector<std::string> out;
    size_t i = lb + 1;
    while (i < rb) {
        size_t q1 = s.find('"', i);
        if (q1 == std::string::npos || q1 >= rb) break;
        size_t q2 = s.find('"', q1 + 1);
        if (q2 == std::string::npos || q2 > rb) break;
        std::string tok = s.substr(q1 + 1, q2 - q1 - 1);
        if (tok == "<blank>") tok.clear();   // blank -> empty (never emitted)
        out.push_back(tok);
        i = q2 + 1;
    }
    return out;
}

// Minimal parse of a sidecar `"<key>": <int>`; `def` if absent.
int parseSidecarInt(const std::string& s, const char* keyName, int def) {
    const std::string key = std::string("\"") + keyName + "\"";
    const size_t k = s.find(key);
    if (k == std::string::npos) return def;
    const size_t colon = s.find(':', k + key.size());
    if (colon == std::string::npos) return def;
    try {
        return std::stoi(s.substr(colon + 1));
    } catch (const std::exception&) {
        return def;
    }
}

#ifdef _WIN32
std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}
#endif

}  // namespace

DeepFistModel::DeepFistModel() : impl_(std::make_unique<Impl>()) {}
DeepFistModel::~DeepFistModel() = default;

bool DeepFistModel::load(const std::string& modelDir,
                         const NeuralModelProfile& profile) {
    ready_ = false;
    lastError_.clear();
    profile_ = profile;

    const std::string onnx    = modelDir + "/" + profile.fileStem + ".onnx";
    const std::string sidecar = readFile(onnx + ".json");

    if (profile.timeMajor) {
        // DeepCW: "chars" maps class -> text for the non-blank classes (the
        // published table has blank last, at "blank_index" 41).  Rebuild as
        // blank-first ids (the CTC, commit and rescorer code all assume
        // blank == id 0); infer() moves the logit columns to match.
        std::vector<std::string> chars = parseSidecarTokens(sidecar, "chars");
        if (chars.size() < 2) chars = fallbackDeepCwChars();
        blankIndex_ = parseSidecarInt(sidecar, "blank_index",
                                      static_cast<int>(chars.size()));
        if (blankIndex_ < 0 || blankIndex_ > static_cast<int>(chars.size())) {
            lastError_ = std::string(profile.name) + " sidecar: bad blank_index";
            return false;
        }
        tokens_.assign(1, std::string());
        for (int c = 0; c < static_cast<int>(chars.size()); ++c)
            if (c != blankIndex_) tokens_.push_back(chars[static_cast<size_t>(c)]);
    } else {
        blankIndex_ = 0;
        // tokens: sidecar first, fallback to the built-in table
        tokens_ = parseSidecarTokens(sidecar);
        if (tokens_.size() < 2) tokens_ = fallbackTokens();

        // Display prosigns in fldigi-style angle notation.  The model emits the
        // aliased punctuation tokens "=" / "+" for BT / AR (that's how they're
        // written in CW); relabel them to <BT>/<AR> so the copy matches the classic
        // decoder and operator expectation (consistent with <SK>/<KN>).  Display
        // only — a MISREAD prosign still shows whatever the model actually decoded.
        for (std::string& t : tokens_) {
            if (t == "=") t = "<BT>";
            else if (t == "+") t = "<AR>";
        }
    }

    try {
        impl_->opts.SetIntraOpNumThreads(1);
        impl_->opts.SetGraphOptimizationLevel(ORT_ENABLE_ALL);
#ifdef _WIN32
        impl_->session = std::make_unique<Ort::Session>(
            impl_->env, widen(onnx).c_str(), impl_->opts);
#else
        impl_->session = std::make_unique<Ort::Session>(
            impl_->env, onnx.c_str(), impl_->opts);
#endif
    } catch (const Ort::Exception& e) {
        lastError_ = std::string("ONNX load failed: ") + e.what();
        return false;
    } catch (const std::exception& e) {
        lastError_ = std::string("model load failed: ") + e.what();
        return false;
    }

    ready_ = true;
    return true;
}

bool DeepFistModel::infer(const float* audio, int n,
                          std::vector<float>& logits, int& T, int& C) {
    T = 0; C = 0;
    logits.clear();
    if (!ready_ || !audio || n <= 0) return false;

    // fldigi-style conditioner FIRST (exp14+ models are trained on conditioned,
    // single-signal, 600 Hz-centred, level-normalised audio — train==inference).
    // DeepCW is trained on raw audio, so its profile skips it.
    const float* condAudio = audio;
    if (profile_.conditioner) {
        condScratch_ = cond_.condition(audio, n);
        if (!condScratch_.empty()) condAudio = condScratch_.data();
    }

    int specT = 0;
    fe_.compute(condAudio, n, specScratch_, specT,   // [65 * specT] row-major
                profile_.standardize);
    if (specT == 0 || specScratch_.empty()) return false;

    // Time-major models (DeepCW) take [1,1,T,F]: transpose the freq-major tile.
    constexpr int F = DeepFistSpectrogram::kFreqBins;
    const float* in = specScratch_.data();
    if (profile_.timeMajor) {
        tmScratch_.resize(specScratch_.size());
        for (int f = 0; f < F; ++f)
            for (int t = 0; t < specT; ++t)
                tmScratch_[static_cast<size_t>(t) * F + f] =
                    specScratch_[static_cast<size_t>(f) * specT + t];
        in = tmScratch_.data();
    }

    try {
        Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator, OrtMemTypeDefault);
        const std::array<int64_t, 4> inShape = profile_.timeMajor
            ? std::array<int64_t, 4>{1, 1, specT, F}
            : std::array<int64_t, 4>{1, 1, F, specT};
        Ort::Value input = Ort::Value::CreateTensor<float>(
            mem, const_cast<float*>(in), specScratch_.size(),
            inShape.data(), inShape.size());

        const char* inNames[]  = {"spectrogram"};
        const char* outNames[] = {"log_probs"};
        auto outputs = impl_->session->Run(
            Ort::RunOptions{nullptr}, inNames, &input, 1, outNames, 1);

        auto info = outputs[0].GetTensorTypeAndShapeInfo();
        auto oshape = info.GetShape();   // [t_out, 1, class] or [1, t_out, class]
        if (oshape.size() != 3) return false;
        T = static_cast<int>(profile_.timeMajor ? oshape[1] : oshape[0]);
        C = static_cast<int>(oshape[2]);
        if (blankIndex_ != 0 && C != static_cast<int>(tokens_.size())) {
            lastError_ = std::string(profile_.name) + ": model has "
                       + std::to_string(C) + " classes, sidecar "
                       + std::to_string(tokens_.size());
            return false;
        }
        const float* logp = outputs[0].GetTensorData<float>();
        // Either layout is row-major [t_out][class] for batch 1.
        logits.assign(logp, logp + static_cast<size_t>(T) * C);
        if (blankIndex_ != 0) {
            // Move the blank column to class 0 and shift the classes before it
            // up by one, matching the blank-first tokens_ built in load().
            for (int t = 0; t < T; ++t) {
                float* row = logits.data() + static_cast<size_t>(t) * C;
                std::rotate(row, row + blankIndex_, row + blankIndex_ + 1);
            }
        }
        return true;
    } catch (const Ort::Exception& e) {
        lastError_ = std::string("inference failed: ") + e.what();
        return false;
    }
}

std::string DeepFistModel::decode3200(const float* audio, int n) {
    std::vector<float> logits;
    int T = 0, C = 0;
    if (!infer(audio, n, logits, T, C)) return {};
    return greedyCtcDecode(logits.data(), T, C, tokens_);
}

}  // namespace lyra::dsp

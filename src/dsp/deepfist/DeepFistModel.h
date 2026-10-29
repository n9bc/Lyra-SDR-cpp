// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Brent Crier (N9BC) - part of Lyra (GPLv3+) per NOTICE.md
//
// Lyra — DeepFist neural CW decoder: ONNX model engine.
//
// C++ mirror of the verified Rust reference `CwEngine` (diddle
// src-tauri/src/dsp/cw_neural.rs): owns the ONNX Runtime session + token table
// + spectrogram front-end, and decodes a window of 3200 Hz audio to text.
//
// This is the ONLY DeepFist file that depends on ONNX Runtime; the rest of the
// pipeline (resampler, spectrogram, CTC) is plain C++.  ONNX Runtime is MIT
// (Microsoft); the model is DeepFist (MIT, © Brent Crier, N9BC).  No AGPL code.
// The same engine can also run the separately-licensed, operator-supplied
// DeepCW model (see NeuralModelProfile) — this file contains none of its code.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "dsp/deepfist/DeepFistConditioner.h"
#include "dsp/deepfist/DeepFistSpectrogram.h"

namespace lyra::dsp {

// Which CW-CTC ONNX model a DeepFistModel runs, and how to feed it.  Both
// supported models share the 3200 Hz / n_fft 256 / hop 48 / 65-bin
// 400-1200 Hz log1p front-end; they differ only in what is done around it.
//   DeepFist — conditioned audio, standardized tile, input [1,1,F,T], output
//              [T,1,C], blank = class 0, tokens from the sidecar "tokens".
//   DeepCW   — e04/deepcw-engine (AGPL-3.0-only, © e04; NOT bundled — the
//              operator drops deepcw.onnx + deepcw.onnx.json into models/).
//              Raw audio, log1p only, input [1,1,T,F], output [1,T,C], blank =
//              sidecar "blank_index" (41), tokens from sidecar "chars".
//              Only the model's published metadata is used; no DeepCW code.
struct NeuralModelProfile {
    const char* name;          // for log / error text
    const char* fileStem;      // loads <stem>.onnx + <stem>.onnx.json
    bool conditioner;          // run DeepFistConditioner before the STFT
    bool standardize;          // global standardize after log1p
    bool timeMajor;            // [1,1,T,F] in / [1,T,C] out (else [1,1,F,T] / [T,1,C])
    bool wordSpaceFilter;      // drop spaces in letter-length gaps (NeuralCwDecoder);
                               // DeepFist only — it splits loose fists into letters,
                               // and its space timing is what the filter assumes
    bool despike;              // blank impulse crashes before the conditioner
                               // (DeepFist's tci_decode does; ARRL crash CER 15.1->9.7%)
    bool stripPunct;           // drop decoded ',' and '.' — DeepFist emits them
                               // as gap noise on real audio (tci_decode strip_punct)

    static NeuralModelProfile deepFist() { return {"DeepFist", "deepfist", true,  true,  false, true,  true,  true};  }
    static NeuralModelProfile deepCw()   { return {"DeepCW",   "deepcw",   false, false, true,  false, false, false}; }
};

class DeepFistModel {
public:
    DeepFistModel();
    ~DeepFistModel();

    DeepFistModel(const DeepFistModel&)            = delete;
    DeepFistModel& operator=(const DeepFistModel&) = delete;

    // Load <stem>.onnx (+ <stem>.onnx.json sidecar) from `modelDir`, per
    // `profile`.  Returns false on any failure (missing file, bad model); the
    // caller can then report "model not found" and stay on the classic engine.
    bool load(const std::string& modelDir,
              const NeuralModelProfile& profile = NeuralModelProfile::deepFist());

    bool ready() const { return ready_; }
    const NeuralModelProfile& profile() const { return profile_; }

    // Decode one window of mono audio already at 3200 Hz.  Returns the decoded
    // text (may be empty).  Safe to call only when ready().
    std::string decode3200(const float* audio, int n);

    // Run the model on a 3200 Hz window and expose the raw CTC log-probs
    // (row-major [T][C], one batch, blank always at class 0 — a model whose
    // blank sits elsewhere has its classes reordered to match tokens()).  Lets the streaming decoder do its own
    // frame-timed commit.  Returns false on failure.  Safe only when ready().
    bool infer(const float* audio, int n,
               std::vector<float>& logits, int& T, int& C);

    // Keying-activity ratio (p90/p10) of the window at the auto-locked tone.
    // The streamer gates on this so the model doesn't hallucinate on dead air /
    // steady carriers (see DeepFistConditioner::keyingRatio).
    float keyingRatio(const float* audio, int n) const {
        return cond_.keyingRatio(audio, n, cond_.detectTone(audio, n));
    }

    // Baseband envelope of the window at the tone keyingRatio() last locked to
    // (call keyingRatio first in the same tick).  One value per sample.
    std::vector<float> keyingEnvelope(const float* audio, int n) const {
        return cond_.keyingEnvelope(audio, n, cond_.lockedTone());
    }

    // Estimated CW speed (WPM) of the window, 0 if indeterminate.
    int keyingWpm(const float* audio, int n) const {
        const float w = cond_.estimateWpm(audio, n, cond_.detectTone(audio, n));
        return static_cast<int>(w + 0.5f);
    }

    const std::vector<std::string>& tokens() const { return tokens_; }
    const std::string& lastError() const { return lastError_; }

private:
    struct Impl;                        // hides the ONNX Runtime types
    std::unique_ptr<Impl> impl_;

    mutable DeepFistConditioner cond_;   // fldigi-style front-end (exp14+ models)
    DeepFistSpectrogram      fe_;
    NeuralModelProfile       profile_ = NeuralModelProfile::deepFist();
    std::vector<std::string> tokens_;   // id -> text, blank ("") at id 0
    int                      blankIndex_ = 0;  // the model's own blank class
    std::vector<float>       despikeScratch_;
    std::vector<float>       condScratch_;
    std::vector<float>       specScratch_;
    std::vector<float>       tmScratch_;  // time-major copy of the tile (DeepCW)
    bool                     ready_ = false;
    std::string              lastError_;
};

}  // namespace lyra::dsp

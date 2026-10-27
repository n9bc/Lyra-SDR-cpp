// Lyra-cpp — #89 Voice keyer / clip playback-OTA: the injector core.
//
// Design: docs/architecture/voice_keyer_design.md (Build 1, Stage A).
//
// Reference: openHPSDR Thetis Console/clsAudioRecordPlayback.cs plays a
// recorded clip back at the MIC INPUT with MOX asserted (MoxOnPlayback), so
// the clip flows the full TX DSP chain exactly like live mic audio — which
// is why PureSignal survives.  Lyra does the same: this player is a TX-audio
// SOURCE that feeds the mic-input funnel (the point Hl2Ep6MicSource::Consumer
// hands 48 kHz mono {I=sample, Q=0} pairs to the TX DSP), so the clip runs
// EQ/Comp/Combinator/PHROT/Leveler/ALC/modulator and PS taps it post-gain.
//
// This class (Stage A) is the PLAYER core only — record lands in Stages B/C.
// It is deliberately Qt-free and DSP-free with injected seams so it unit-
// tests without hardware / WDSP / Qt:
//   * KeyFn      — real impl calls HL2Stream::requestMox(on, PttSource::Keyer)
//   * BlockedFn  — real impl reads HL2Stream::pttSource() to honour own-key
//                  discipline (never override a Manual / HwPtt key).
//
// PULL model (no new timer, no cadence risk): the mic-input injection adapter
// asks the player for the next block each TX tick while a clip is playing,
// feeding clip samples INSTEAD of live mic.  Reuses the existing 48 kHz EP2
// pump cadence.
//
// SAFETY (see the design doc §5): this player only produces AUDIO.  It cannot
// bypass the modulator — the ALC limiter + TX bandpass live inside WDSP TXA
// (downstream), always on.  Own-key discipline: OTA keys via PttSource::Keyer
// and releases ONLY its own key; a manual key or stop() aborts.  IDs / TX-
// timeout are enforced by the FSM the KeyFn funnels through.

#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

namespace lyra::tx {

class ClipRecorderPlayer {
public:
    // Options locked at play() time.
    struct PlayOptions {
        bool   ota       = true;   // true = Transmit (assert MOX via KeyFn);
                                   // false = Review (local monitor, no key).
        bool   bypassDsp = false;  // Carried on the active clip for the
                                   // injection adapter to consult (Stage B
                                   // routes it to the TX-DSP bypass); the
                                   // player itself does not process audio.
        double gainLin   = 1.0;    // Linear gain applied to played samples,
                                   // ahead of the modulator (ALC still caps).
        bool   loop      = false;  // Wrap to the clip start seamlessly (no
                                   // gap, no Draining, no key) — eSSB practice
                                   // loop.  Never allowed with ota: play()
                                   // refuses loop && ota.
    };

    // Keying seam.  on=true → assert the key (PttSource::Keyer); on=false →
    // release it.  Called OUTSIDE the internal mutex.
    using KeyFn = std::function<void(bool on)>;
    // Own-key guard.  Returns true if a HIGHER-priority source (Manual /
    // HwPtt) currently owns the key, in which case the keyer must not play /
    // must abort.  May be empty (treated as "not blocked").
    using BlockedFn = std::function<bool()>;
    // Practice-loop air guard.  Returns true if a key is requested / MOX is
    // active, in which case a NON-OTA clip must never run: fillBlock() goes
    // Idle (no key toggle) and returns false BEFORE writing any sample, so the
    // adapter keeps live mic in the buffer.  Ignored for OTA clips (they keep
    // their own BlockedFn discipline).  May be empty.  Called under the mutex
    // from the TX thread — must be cheap and non-blocking (e.g. atomic reads).
    using RefuseFn = std::function<bool()>;

    ClipRecorderPlayer() = default;

    void setKeyFn(KeyFn fn)        { std::lock_guard<std::mutex> lk(mtx_); keyFn_ = std::move(fn); }
    void setBlockedFn(BlockedFn f) { std::lock_guard<std::mutex> lk(mtx_); blockedFn_ = std::move(f); }
    void setRefuseFn(RefuseFn f)   { std::lock_guard<std::mutex> lk(mtx_); refuseFn_ = std::move(f); }

    // Begin playing a mono 48 kHz clip.  Returns false (no-op) if a clip is
    // already playing, `mono` is null/empty, `loop && ota`, or (OTA) a
    // higher-priority source owns the key.  On OTA it asserts the key immediately; samples
    // then flow as fillBlock() is pumped.
    bool play(std::shared_ptr<const std::vector<float>> mono, PlayOptions opt);

    // Abort/stop: releases our key if held, goes Idle.  Idempotent + safe
    // from any thread.
    void stop();

    // Live playback gain (linear) — fillBlock reads this EACH block, so the
    // operator can ride the level up/down DURING an OTA transmission (not just
    // at play() time).  play() seeds it from PlayOptions::gainLin.  Lock-free.
    void setGain(double lin) { gainLin_.store(lin, std::memory_order_relaxed); }

    bool playing() const { std::lock_guard<std::mutex> lk(mtx_); return state_ != State::Idle; }
    // Lock-free "a clip is active" hint for the TX-funnel injection adapter's
    // hot path (Ep6 thread): lets it skip the mutex + fillBlock() entirely on
    // every datagram while idle (the common case).  Authoritative state is
    // still state_ (mutex-guarded); this only gates whether fillBlock is worth
    // calling.  True while Playing OR Draining, false when Idle.
    bool active() const noexcept { return active_.load(std::memory_order_acquire); }
    // True while we hold the wire key (OTA transmit in progress).
    bool keyed()   const { std::lock_guard<std::mutex> lk(mtx_); return keyHeld_; }
    // Playback position in [0, 1]; 0 when idle.
    double progress() const;
    // Loop passes completed since play() (0 at play(), +1 per wrap).  Atomic,
    // lock-free: safe for a GUI poll while the TX thread pumps fillBlock.
    unsigned passCount() const noexcept { return passCount_.load(std::memory_order_relaxed); }
    // Length of the active clip in samples; 0 when idle.
    std::size_t clipSamples() const { std::lock_guard<std::mutex> lk(mtx_); return clip_ ? clip_->size() : 0; }
    // The bypass flag of the clip currently playing (for the injection
    // adapter to route to the TX-DSP bypass).  false when idle.
    bool activeBypassDsp() const { std::lock_guard<std::mutex> lk(mtx_); return state_ != State::Idle && opt_.bypassDsp; }

    // ── TX-funnel producer hook (pull) ──
    // Called by the mic-input injection adapter each TX tick WHILE playing.
    // Fills `n_pairs` interleaved {I = sample*gain, Q = 0.0} doubles from the
    // clip (matches Hl2Ep6MicSource::Consumer shape).  Returns true while the
    // player is still active (clip audio or the post-clip silence drain that
    // lets the FSM keyup fade ride silence, not a chop / not live mic); when
    // the drain completes it goes Idle and returns false (adapter reverts to
    // live mic).  On clip-exhaustion it requests keyup (KeyFn(false)) once.
    bool fillBlock(int n_pairs, double *out_iq_pairs);

    static constexpr int sampleRate() { return 48000; }
    // Silence tail fed after the clip ends, covering the FSM keyup fade so it
    // rides silence instead of chopping the clip or leaking live mic.
    // ~60 ms @ 48 kHz — comfortably past MoxEdgeFade's ~50 ms fade + settle.
    static constexpr int kDrainTailSamples = 48000 * 60 / 1000;

private:
    enum class State { Idle, Playing, Draining };

    void releaseKey_locked_(bool &wantKeyUp);   // marks keyHeld_ false, sets wantKeyUp if we held it

    mutable std::mutex mtx_;
    State       state_ = State::Idle;
    std::shared_ptr<const std::vector<float>> clip_;
    std::size_t pos_        = 0;    // next clip sample index
    std::size_t drainLeft_  = 0;    // silence samples remaining in the drain
    PlayOptions opt_{};
    bool        keyHeld_ = false;
    std::atomic<bool>   active_{false};   // Playing || Draining (lock-free hint)
    std::atomic<double> gainLin_{1.0};    // live playback gain (rideable during OTA)
    std::atomic<unsigned> passCount_{0};  // loop wraps since play()
    KeyFn       keyFn_;
    BlockedFn   blockedFn_;
    RefuseFn    refuseFn_;
};

} // namespace lyra::tx

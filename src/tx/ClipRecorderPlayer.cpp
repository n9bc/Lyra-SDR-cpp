// Lyra-cpp — #89 Voice keyer / clip playback-OTA: the injector core (Stage A).
// See ClipRecorderPlayer.h + docs/architecture/voice_keyer_design.md.

#include "tx/ClipRecorderPlayer.h"

#include <algorithm>

namespace lyra::tx {

bool ClipRecorderPlayer::play(std::shared_ptr<const std::vector<float>> mono,
                              PlayOptions opt) {
    KeyFn keyFnCopy;
    bool  doKeyDown = false;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (state_ != State::Idle) return false;          // already playing
        if (!mono || mono->empty()) return false;         // nothing to play
        if (opt.loop && opt.ota) return false;            // never loop onto the air
        // Own-key discipline: never key over a Manual / HwPtt hold.
        if (opt.ota && blockedFn_ && blockedFn_()) return false;

        clip_      = std::move(mono);
        pos_       = 0;
        drainLeft_ = 0;
        passCount_.store(0, std::memory_order_relaxed);
        opt_       = opt;
        gainLin_.store(opt.gainLin, std::memory_order_relaxed);   // seed live gain
        state_     = State::Playing;
        active_.store(true, std::memory_order_release);
        keyHeld_   = false;

        if (opt_.ota) {
            keyHeld_  = true;
            doKeyDown = true;
            keyFnCopy = keyFn_;
        }
    }
    if (doKeyDown && keyFnCopy) keyFnCopy(true);           // assert key OUTSIDE the lock
    return true;
}

void ClipRecorderPlayer::stop() {
    KeyFn keyFnCopy;
    bool  wantKeyUp = false;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (state_ == State::Idle) return;                 // idempotent
        state_ = State::Idle;
        active_.store(false, std::memory_order_release);
        clip_.reset();
        pos_ = 0;
        drainLeft_ = 0;
        if (keyHeld_) { keyHeld_ = false; wantKeyUp = true; keyFnCopy = keyFn_; }
    }
    if (wantKeyUp && keyFnCopy) keyFnCopy(false);           // release OUR key OUTSIDE the lock
}

double ClipRecorderPlayer::progress() const {
    std::lock_guard<std::mutex> lk(mtx_);
    if (state_ == State::Idle || !clip_ || clip_->empty()) return 0.0;
    if (state_ == State::Draining) return 1.0;
    const double p = static_cast<double>(pos_) / static_cast<double>(clip_->size());
    return p < 0.0 ? 0.0 : (p > 1.0 ? 1.0 : p);
}

bool ClipRecorderPlayer::fillBlock(int n_pairs, double *out_iq_pairs) {
    if (n_pairs <= 0 || out_iq_pairs == nullptr) return playing();

    KeyFn keyFnCopy;
    bool  wantKeyUp = false;
    bool  ret       = true;
    {
        std::lock_guard<std::mutex> lk(mtx_);

        // Defensive: not playing → silence, tell the caller to revert to mic.
        if (state_ == State::Idle) {
            std::fill(out_iq_pairs, out_iq_pairs + 2 * n_pairs, 0.0);
            return false;
        }

        // Practice-loop air guard: a non-OTA clip must never run while a key is
        // requested / MOX is active.  Go Idle WITHOUT touching the key and
        // WITHOUT writing the buffer, so live mic in the caller's buffer flows.
        if (!opt_.ota && refuseFn_ && refuseFn_()) {
            state_ = State::Idle;
            active_.store(false, std::memory_order_release);
            clip_.reset();
            pos_ = 0; drainLeft_ = 0; keyHeld_ = false;
            return false;
        }

        // Own-key abort: a higher-priority source (Manual / HwPtt) grabbed the
        // key mid-clip.  Stop feeding immediately.  Do NOT toggle the key — the
        // higher-priority source now owns it; releasing here would drop THEIR
        // key.  (The primary abort path is HL2Stream calling stop() on the
        // Manual-key edge; this is the belt-and-suspenders net.)
        if (blockedFn_ && blockedFn_()) {
            state_ = State::Idle;
            active_.store(false, std::memory_order_release);
            clip_.reset();
            pos_ = 0; drainLeft_ = 0; keyHeld_ = false;
            std::fill(out_iq_pairs, out_iq_pairs + 2 * n_pairs, 0.0);
            return false;
        }

        if (state_ == State::Playing) {
            const double g = gainLin_.load(std::memory_order_relaxed);   // live (rideable)
            const std::size_t sz = clip_ ? clip_->size() : 0;
            int i = 0;
            for (; i < n_pairs && pos_ < sz; ++i) {
                out_iq_pairs[2 * i + 0] = static_cast<double>((*clip_)[pos_]) * g;
                out_iq_pairs[2 * i + 1] = 0.0;
                if (++pos_ >= sz && opt_.loop) {          // seamless wrap
                    pos_ = 0;
                    passCount_.fetch_add(1, std::memory_order_relaxed);
                }
            }
            if (pos_ >= sz) {
                // Clip exhausted (this block or exactly filled).  Silence the
                // remainder of THIS block, request keyup so the FSM fade rides
                // silence, and enter the silence drain that covers the fade.
                for (; i < n_pairs; ++i) {
                    out_iq_pairs[2 * i + 0] = 0.0;
                    out_iq_pairs[2 * i + 1] = 0.0;
                }
                state_     = State::Draining;
                drainLeft_ = static_cast<std::size_t>(kDrainTailSamples);
                if (keyHeld_) { keyHeld_ = false; wantKeyUp = true; keyFnCopy = keyFn_; }
            }
            ret = true;
        } else {  // Draining — feed silence until the fade window elapses.
            std::fill(out_iq_pairs, out_iq_pairs + 2 * n_pairs, 0.0);
            const std::size_t np = static_cast<std::size_t>(n_pairs);
            drainLeft_ = (drainLeft_ > np) ? (drainLeft_ - np) : 0;
            if (drainLeft_ == 0) {
                state_ = State::Idle;
                active_.store(false, std::memory_order_release);
                clip_.reset(); pos_ = 0;
            }
            ret = true;   // this block's silence is valid; adapter reverts next tick
        }
    }
    if (wantKeyUp && keyFnCopy) keyFnCopy(false);            // OUTSIDE the lock
    return ret;
}

} // namespace lyra::tx

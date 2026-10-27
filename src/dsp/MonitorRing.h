// Lyra — #90 TX-monitor SPSC ring.
//
// Lock-free single-producer / single-consumer ring of mono doubles for the
// TX audio monitor.  Producer = the cm_main TX pump (CMaster xcmaster case 1,
// via the TxMonitorTap cb) capturing the post-rack mic; consumer = the audio
// thread (WdspEngine::dispatchAudioFrame) draining it onto the HL2 jack while
// MOX is up and MON is on.  Free-running unsigned head/tail counters (modular
// subtraction yields the fill level); power-of-two capacity for a cheap mask.
// Overflow drops the NEWEST samples so a stalled/absent consumer can never
// block the real-time TX thread.  In steady state the producer and consumer
// both run at 48 k mono, so the ring stays near-empty and only absorbs jitter.

#pragma once

#include <atomic>
#include <cstddef>
#include <vector>

namespace lyra::dsp {

class MonitorRing {
public:
    // capacityPow2 MUST be a power of two (the mask depends on it).
    explicit MonitorRing(std::size_t capacityPow2 = 16384)
        : buf_(capacityPow2, 0.0), mask_(capacityPow2 - 1) {}

    // Producer (cm_main TX thread): append n mono samples; drop newest if full.
    void push(const double *src, std::size_t n) noexcept {
        const std::size_t cap  = mask_ + 1;
        std::size_t       head = head_.load(std::memory_order_relaxed);
        const std::size_t tail = tail_.load(std::memory_order_acquire);
        std::size_t       used = head - tail;
        for (std::size_t i = 0; i < n; ++i) {
            if (used >= cap) break;            // full -> drop the rest (newest)
            buf_[head & mask_] = src[i];
            ++head;
            ++used;
        }
        head_.store(head, std::memory_order_release);
    }

    // Consumer (audio thread): pop up to n samples; returns count delivered.
    std::size_t pop(double *dst, std::size_t n) noexcept {
        std::size_t       tail  = tail_.load(std::memory_order_relaxed);
        const std::size_t head  = head_.load(std::memory_order_acquire);
        const std::size_t avail = head - tail;
        const std::size_t k     = (n < avail) ? n : avail;
        for (std::size_t i = 0; i < k; ++i) {
            dst[i] = buf_[tail & mask_];
            ++tail;
        }
        tail_.store(tail, std::memory_order_release);
        return k;
    }

    // Consumer, jitter-buffered (eSSB practice loop).  The producer runs in
    // bursts that follow the radio's packets, so a plain pop() settles on a
    // ~10 ms cushion and an occasional late burst empties it mid-block (a
    // 5 ms dropout).  While !primed this pops nothing until `prime` samples
    // are queued; once primed it pops like pop().  A block that finds fewer
    // than n samples delivers what there is and clears `primed`, so the
    // cushion re-fills before playback resumes.  `primed` is consumer state.
    std::size_t popPrimed(double *dst, std::size_t n, std::size_t prime,
                          bool &primed) noexcept {
        const std::size_t avail = available();
        if (!primed) {
            if (avail < prime) return 0;
            primed = true;
        }
        if (avail < n) primed = false;
        return pop(dst, n);
    }

    std::size_t available() const noexcept {
        return head_.load(std::memory_order_acquire)
             - tail_.load(std::memory_order_acquire);
    }

    // Consumer-side flush (MON off / MOX edge) — discard everything pending.
    void clear() noexcept {
        tail_.store(head_.load(std::memory_order_acquire),
                    std::memory_order_release);
    }

private:
    std::vector<double>      buf_;
    std::size_t              mask_;
    std::atomic<std::size_t> head_{0};   // producer writes
    std::atomic<std::size_t> tail_{0};   // consumer reads
};

}  // namespace lyra::dsp

/* Concurrency harness for WDSP impulse_cache.c (included directly so the list can be audited).
   Threads call the REAL fir_bandpass() concurrently with keys drawn by a deterministic per-thread
   xorshift RNG; each returned impulse is compared bit-exactly with a reference computed with the
   cache disabled.  After the run the bucket list is walked for cycles / count mismatch. */
#include "impulse_cache.c"
#include <stdatomic.h>
#include <time.h>

#ifndef NKEYS
#define NKEYS 64
#endif
#define NTAPS 1024
static double* ref[NKEYS];
static atomic_long mismatches, calls, nulls;
static long iters_per_thread;
static double key_lo(int k){ return -3000.0 + 10.0*k; }
static double key_hi(int k){ return  3000.0 + 7.0*k; }

static void* worker(void* arg){
    uint64_t s = 0x9E3779B97F4A7C15ULL * (uint64_t)((intptr_t)arg + 1);
    for (long it = 0; it < iters_per_thread; it++){
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        int k = (int)(s % NKEYS);
        double* imp = fir_bandpass(NTAPS, key_lo(k), key_hi(k), 48000.0, 1, 1, 1.0/NTAPS);
        atomic_fetch_add(&calls, 1);
        if (!imp){ atomic_fetch_add(&nulls,1); continue; }
        if (memcmp(imp, ref[k], NTAPS*sizeof(complex))) atomic_fetch_add(&mismatches, 1);
        _aligned_free(imp);
    }
    return NULL;
}

int main(int argc, char** argv){
    int nthreads = argc > 1 ? atoi(argv[1]) : 4;
    iters_per_thread = argc > 2 ? atol(argv[2]) : 20000;
    init_impulse_cache(0);                 /* references: cache off */
    for (int k = 0; k < NKEYS; k++) ref[k] = fir_bandpass(NTAPS, key_lo(k), key_hi(k), 48000.0, 1, 1, 1.0/NTAPS);
    use_impulse_cache(1);
    pthread_t th[64];
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < nthreads; i++) pthread_create(&th[i], NULL, worker, (void*)(intptr_t)i);
    for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    /* audit FIR bucket */
    size_t walked = 0; int cycle = 0, dups = 0; int seen[NKEYS] = {0}; long unknown = 0;
    for (cache_entry* e = _cache_heads[FIR_CACHE]; e; e = e->next){
        if (++walked > 10u*1000*1000){ cycle = 1; break; }
        int found = -1;
        for (int k = 0; k < NKEYS; k++) if (!memcmp(e->impulse, ref[k], NTAPS*sizeof(complex))) { found = k; break; }
        if (found < 0) unknown++; else if (seen[found]++) dups++;
    }
    double secs = (t1.tv_sec-t0.tv_sec) + 1e-9*(t1.tv_nsec-t0.tv_nsec);
    printf("threads=%d iters/thr=%ld keys=%d max_entries=%d calls=%ld mismatches=%ld nulls=%ld "
           "list_walked=%zu count_field=%zu cycle=%d duplicate_entries=%d corrupt_entries=%ld time=%.3fs\n",
        nthreads, iters_per_thread, NKEYS, MAX_CACHE_ENTRIES, (long)calls, (long)mismatches, (long)nulls,
        walked, _cache_counts[FIR_CACHE], cycle, dups, unknown, secs);
    return 0;
}

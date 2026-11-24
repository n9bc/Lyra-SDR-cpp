#include "comm.h"
void* malloc0(int size) { void* p = _aligned_malloc((size_t)size, 16); if (p) memset(p, 0, (size_t)size); return p; }
uint64_t fnv1a_hash64(const void* data, size_t len) { const unsigned char* d = data; uint64_t h = 1469598103934665603ULL; for (size_t i = 0; i < len; i++) { h ^= d[i]; h *= 1099511628211ULL; } return h; }
double* get_impulse_cache_entry(size_t b, HASH_T h, int N) { (void)b; (void)h; (void)N; return NULL; }
void add_impulse_to_cache(size_t b, HASH_T h, int N, double* imp) { (void)b; (void)h; (void)N; (void)imp; }
void recalc_bpsnba_filter(BPSNBA a, int u) { (void)a; (void)u; }
void RXAbpsnbaCheck(int c, int m, int r) { (void)c; (void)m; (void)r; }
void RXAbpsnbaSet(int c) { (void)c; }
struct _rxa_stub rxa[4];
struct _ch_stub ch[4];

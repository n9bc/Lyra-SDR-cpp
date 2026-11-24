#include "comm.h"
void *malloc0 (int size){ void* p=_aligned_malloc(size,16); if(p) memset(p,0,size); return p; }
uint32_t fnv1a_hash32(const void* data, size_t len){const uint8_t*d=data;uint32_t h=2166136261u;for(size_t i=0;i<len;i++){h^=d[i];h*=16777619u;}return h;}
double* get_impulse_cache_entry(size_t b, HASH_T h, int N){(void)b;(void)h;(void)N;return NULL;}
void add_impulse_to_cache(size_t b, HASH_T h, int N, double* imp){(void)b;(void)h;(void)N;(void)imp;}

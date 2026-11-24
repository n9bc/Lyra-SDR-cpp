#ifndef WINSHIM_H
#define WINSHIM_H
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef pthread_mutex_t CRITICAL_SECTION, *LPCRITICAL_SECTION;
static inline int InitializeCriticalSectionAndSpinCount(CRITICAL_SECTION *c, int n){(void)n;return pthread_mutex_init(c,NULL)==0;}
static inline void EnterCriticalSection(CRITICAL_SECTION *c){pthread_mutex_lock(c);}
static inline void LeaveCriticalSection(CRITICAL_SECTION *c){pthread_mutex_unlock(c);}
static inline void DeleteCriticalSection(CRITICAL_SECTION *c){pthread_mutex_destroy(c);}
#define InterlockedAnd(p,v) __atomic_fetch_and((p),(v),__ATOMIC_SEQ_CST)
#define InterlockedExchange(p,v) __atomic_exchange_n((p),(v),__ATOMIC_SEQ_CST)
#define Sleep(ms) usleep((ms)*1000)
#define __declspec(x)
static inline void *_aligned_malloc(size_t n, size_t al){void*p=NULL; if(posix_memalign(&p,al<sizeof(void*)?sizeof(void*):al,n?n:1))return NULL; return p;}
static inline void _aligned_free(void*p){free(p);}
#endif

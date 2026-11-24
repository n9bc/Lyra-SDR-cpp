#ifndef WINSHIM_H
#define WINSHIM_H
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef pthread_mutex_t CRITICAL_SECTION;
static inline int InitializeCriticalSectionAndSpinCount(CRITICAL_SECTION* c, int n){(void)n;pthread_mutex_init(c,NULL);return 1;}
#define EnterCriticalSection(c) pthread_mutex_lock(c)
#define LeaveCriticalSection(c) pthread_mutex_unlock(c)
#define DeleteCriticalSection(c) pthread_mutex_destroy(c)
#define InterlockedAnd(p,v) __atomic_fetch_and((p),(v),__ATOMIC_SEQ_CST)
#define InterlockedExchange(p,v) __atomic_exchange_n((p),(v),__ATOMIC_SEQ_CST)
#define Sleep(ms) usleep((ms)*1000)
#define __declspec(x)
static inline void* _aligned_malloc(size_t sz, size_t al){void* p=NULL; if(al<16)al=16; if(posix_memalign(&p,al,sz?sz:al))return NULL; return p;}
#define _aligned_free(p) free(p)
#endif

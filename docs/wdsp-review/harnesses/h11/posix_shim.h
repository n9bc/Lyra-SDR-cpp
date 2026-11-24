#ifndef POSIX_SHIM_H
#define POSIX_SHIM_H
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef pthread_mutex_t CRITICAL_SECTION;
static inline void InitializeCriticalSection(CRITICAL_SECTION* c){ pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(c,&a); pthread_mutexattr_destroy(&a);}
static inline int InitializeCriticalSectionAndSpinCount(CRITICAL_SECTION* c, unsigned s){ (void)s; InitializeCriticalSection(c); return 1; }
#define EnterCriticalSection(c) pthread_mutex_lock(c)
#define LeaveCriticalSection(c) pthread_mutex_unlock(c)
#define DeleteCriticalSection(c) pthread_mutex_destroy(c)
#define InterlockedAnd(p,v) __atomic_fetch_and((p),(v),__ATOMIC_SEQ_CST)
#define InterlockedExchange(p,v) __atomic_exchange_n((p),(v),__ATOMIC_SEQ_CST)
#define Sleep(ms) usleep((ms)*1000)
#define __declspec(x)
static inline void* _aligned_malloc(size_t n, size_t al){ void* p=NULL; if(posix_memalign(&p, al<sizeof(void*)?sizeof(void*):al, n?n:1)) return NULL; return p; }
#define _aligned_free free
#endif

/* Minimal POSIX shim for the WDSP analyzer harness (macOS arm64). */
#pragma once
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
typedef int32_t LONG;
typedef uint32_t DWORD;
typedef void* HANDLE;
typedef pthread_mutex_t CRITICAL_SECTION;
#define WINAPI
#define __cdecl
#define __declspec(x)
#define TEXT(x) x
#define INFINITE 0xFFFFFFFF
static inline int InitializeCriticalSectionAndSpinCount(CRITICAL_SECTION* c, DWORD n){ pthread_mutexattr_t at; (void)n; pthread_mutexattr_init(&at); pthread_mutexattr_settype(&at, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(c,&at); return 1; }
#define EnterCriticalSection(c) pthread_mutex_lock(c)
#define LeaveCriticalSection(c) pthread_mutex_unlock(c)
#define DeleteCriticalSection(c) pthread_mutex_destroy(c)
#define InterlockedAnd(p,v) __atomic_fetch_and((p),(v),__ATOMIC_SEQ_CST)
#define _InterlockedAnd(p,v) __atomic_fetch_and((p),(v),__ATOMIC_SEQ_CST)
#define InterlockedIncrement(p) __atomic_add_fetch((p),1,__ATOMIC_SEQ_CST)
#define InterlockedDecrement(p) __atomic_sub_fetch((p),1,__ATOMIC_SEQ_CST)
#define InterlockedBitTestAndSet(p,b) ((__atomic_fetch_or((p),(1<<(b)),__ATOMIC_SEQ_CST)>>(b))&1)
#define InterlockedBitTestAndReset(p,b) ((__atomic_fetch_and((p),~(1<<(b)),__ATOMIC_SEQ_CST)>>(b))&1)
#define Sleep(ms) usleep((ms)*1000)
static inline HANDLE CreateEvent(void* a,int b,int c,const char* d){(void)a;(void)b;(void)c;(void)d;return (HANDLE)1;}
static inline int SetEvent(HANDLE h){(void)h;return 1;}
static inline DWORD WaitForSingleObject(HANDLE h,DWORD t){(void)h;(void)t;return 0;}
static inline int CloseHandle(HANDLE h){(void)h;return 1;}
/* thread pool not exercised by this harness: stubs abort if reached */
static inline uintptr_t _beginthread(void (*f)(void*), unsigned s, void* a){(void)f;(void)s;(void)a;fprintf(stderr,"_beginthread stub reached\n");abort();}
static inline void _endthread(void){}
static inline int QueueUserWorkItem(DWORD (*f)(void*), void* a, int fl){(void)f;(void)a;(void)fl;fprintf(stderr,"QueueUserWorkItem stub reached\n");abort();}
static inline void* _aligned_malloc(size_t n,size_t al){void* p=0; if(posix_memalign(&p,al<16?16:al,n))return 0; return p;}
#define _aligned_free(p) free(p)
static inline void* malloc0(int size){void* p=_aligned_malloc((size_t)size,16); if(p) memset(p,0,(size_t)size); return p;}
#ifndef min
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#endif
#define FALSE 0
#define TRUE 1
static inline int ResetEvent(HANDLE h){(void)h;return 1;}

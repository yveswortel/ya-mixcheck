#include "PreviewGain.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

_Static_assert(sizeof(float)==4,"Preview gain requires 32-bit float");
struct QCGain {
    _Atomic uint64_t targets;
    _Atomic int rendered;
    // All remaining fields belong exclusively to the render thread.
    uint64_t observed;
    uint32_t duration, remaining;
    double a, b;
    float targetA, targetB;
};
static float safe_gain(float value) {
    return !isfinite(value) ? 0 : fmaxf(0,fminf(1,value));
}
static uint64_t pack(float a,float b) {
    uint32_t x,y;memcpy(&x,&a,sizeof(x));memcpy(&y,&b,sizeof(y));
    return ((uint64_t)y<<32)|x;
}
static void unpack(uint64_t bits,float* a,float* b) {
    uint32_t x=(uint32_t)bits,y=(uint32_t)(bits>>32);
    memcpy(a,&x,sizeof(x));memcpy(b,&y,sizeof(y));
}
QCGain* qcg_create(double rate,double fadeSeconds) {
    double frames=rate*fadeSeconds;
    if (!isfinite(rate)||rate<=0||!isfinite(fadeSeconds)||fadeSeconds<=0||
        !isfinite(frames)||frames>UINT32_MAX) return NULL;
    QCGain* s=calloc(1,sizeof(*s));if(!s)return NULL;
    atomic_init(&s->targets,0);
    atomic_init(&s->rendered,0);
    if(!atomic_is_lock_free(&s->targets)||!atomic_is_lock_free(&s->rendered)){free(s);return NULL;}
    s->duration=(uint32_t)fmax(1,round(frames));return s;
}
void qcg_destroy(QCGain* s){free(s);}
void qcg_set_rendered(QCGain* s,int rendered) {
    if(s)atomic_store_explicit(&s->rendered,rendered!=0,memory_order_release);
}
int qcg_has_rendered(QCGain* s) {
    return s ? atomic_load_explicit(&s->rendered,memory_order_acquire):0;
}
void qcg_set_targets(QCGain* s,float a,float b) {
    if(s)atomic_store_explicit(&s->targets,pack(safe_gain(a),safe_gain(b)),memory_order_relaxed);
}
void qcg_next(QCGain* s,uint32_t frames,QCGainRamp* ramp) {
    if(!ramp)return;
    *ramp=(QCGainRamp){0};if(!s)return;
    ramp->startA=ramp->endA=s->a;ramp->startB=ramp->endB=s->b;
    if(!frames)return;
    // The packed atomic contains every published field, so no auxiliary memory
    // needs ordering. A render block can never see half of an A/B target pair.
    uint64_t target=atomic_load_explicit(&s->targets,memory_order_relaxed);
    if(target!=s->observed){
        s->observed=target;unpack(target,&s->targetA,&s->targetB);
        s->remaining=s->duration;
    }
    ramp->targetA=s->targetA;ramp->targetB=s->targetB;
    ramp->remainingFrames=s->remaining;
    uint32_t count=frames<s->remaining ? frames:s->remaining;
    if(count){
        if(count==s->remaining){s->a=s->targetA;s->b=s->targetB;}
        else {
            double amount=(double)count/(double)s->remaining;
            s->a+=(s->targetA-s->a)*amount;s->b+=(s->targetB-s->b)*amount;
        }
        s->remaining-=count;
    }
    ramp->endA=s->a;ramp->endB=s->b;ramp->rampFrames=count;
}

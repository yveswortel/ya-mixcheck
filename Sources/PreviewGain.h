#ifndef YA_PREVIEW_GAIN_H
#define YA_PREVIEW_GAIN_H
#include <stdint.h>
typedef struct QCGain QCGain;
typedef struct {
    float startA, startB, endA, endB;
    float targetA, targetB;
    uint32_t rampFrames, remainingFrames;
} QCGainRamp;
// Create/destroy on the control thread, while no render callback uses the state.
QCGain* qcg_create(double rate, double fadeSeconds);
void qcg_destroy(QCGain* state);
// Publish both endpoints together. No allocation or locks.
void qcg_set_targets(QCGain* state, float a, float b);
// Single render-thread owner; variable/zero-size buffers are supported.
void qcg_next(QCGain* state, uint32_t frames, QCGainRamp* ramp);
// Set true from a completed post-render callback; reset only with rendering stopped.
void qcg_set_rendered(QCGain* state, int rendered);
int qcg_has_rendered(QCGain* state);
#endif

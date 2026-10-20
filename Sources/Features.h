#ifndef YA_FEATURES_H
#define YA_FEATURES_H
#include <stdint.h>
typedef struct QCT QCT;
QCT* qct_create(int rate,int channels,int64_t frames);
void qct_destroy(QCT* q);
int qct_push(QCT* q,const float* samples,int frames);
int qct_count(QCT* q);
// 0 RMS dBFS, 1..8 band power dBFS, 9 low-envelope max/mean dB,
// 10 mono low-energy ratio dB, 11 duration seconds, 12 FFT window count.
double qct_value(QCT* q,int window,int metric);
#endif

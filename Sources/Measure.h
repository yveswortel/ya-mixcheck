#ifndef YA_MEASURE_H
#define YA_MEASURE_H
#include <stdint.h>
#include "Features.h"
#define QC_WAVE 2048
#define QC_BANDS 120
#define QC_EVENTS 512
// Indices are stable in schema 1. Unavailable results are NaN, sanitized at JSON boundary.
enum { QC_I, QC_M, QC_S, QC_LRA, QC_TP, QC_PEAK, QC_RMS_L, QC_RMS_R,
       QC_CREST_L, QC_CREST_R, QC_CORR, QC_MONO, QC_DC_L, QC_DC_R, QC_METRICS };
typedef struct QC QC;
typedef struct { int64_t start, end; int channel; } QCEvent;
QC* qc_create(int rate, int channels, int64_t expected);
void qc_destroy(QC* q);
int qc_push(QC* q, const float* interleaved, int frames);
int qc_finish(QC* q);
double qc_value(QC* q, int index);
const float* qc_wave(QC* q);
const double* qc_spectrum(QC* q);
double qc_frequency(int index);
const double* qc_low_bands(QC* q);
const QCEvent* qc_events(QC* q);
int qc_event_count(QC* q);
int64_t qc_over_samples(QC* q);
int64_t qc_frames(QC* q);
// Configure before pushing. 0 means floating or lossy source: PCM rail test unavailable.
void qc_set_pcm_bits(QC* q, int bits);
int64_t qc_rail_samples(QC* q);
int64_t qc_flat_samples(QC* q);
int64_t qc_low_flat_samples(QC* q);
int64_t qc_flat_longest(QC* q);
int64_t qc_flat_runs(QC* q);
const QCEvent* qc_flat_events(QC* q);
int qc_flat_event_count(QC* q);
// Full-track per-channel sample counts in QC_WAVE time bins. 0=plateau, 1=PCM rail, 2=overrange.
const int64_t* qc_timeline(QC* q, int kind);
typedef struct QCMP3 QCMP3;
QCMP3* qc_mp3_open(const char* path);
void qc_mp3_close(QCMP3* m);
int qc_mp3_rate(QCMP3* m);
int qc_mp3_channels(QCMP3* m);
int64_t qc_mp3_frames(QCMP3* m);
int qc_mp3_has_gapless(QCMP3* m);
int qc_mp3_read(QCMP3* m, float* out, int frames);
int qc_mp3_seek(QCMP3* m, int64_t frame);
typedef struct QCFLAC QCFLAC;
QCFLAC* qc_flac_open(const char* path);
void qc_flac_close(QCFLAC* f);
int qc_flac_rate(QCFLAC* f);
int qc_flac_channels(QCFLAC* f);
int qc_flac_bits(QCFLAC* f);
int64_t qc_flac_frames(QCFLAC* f);
int qc_flac_read(QCFLAC* f, float* out, int frames);
int qc_flac_seek(QCFLAC* f, int64_t frame);
typedef struct QCPreviewMeter QCPreviewMeter;
QCPreviewMeter* qcp_create(int rate,int channels);
void qcp_destroy(QCPreviewMeter* m);
int qcp_push(QCPreviewMeter* m,const float* x,int frames);
int qcp_finish(QCPreviewMeter* m,double* loudness,double* peakDB);
#endif

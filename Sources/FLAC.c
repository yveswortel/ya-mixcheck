#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_OGG
#include "dr_libs/dr_flac.h"
#include "Measure.h"
struct QCFLAC { drflac* decoder; };
QCFLAC* qc_flac_open(const char* path) {
    drflac* d=drflac_open_file(path,NULL);
    if(!d)return NULL;
    if(d->channels<1 || d->channels>2 || !d->totalPCMFrameCount || d->bitsPerSample>24) {drflac_close(d);return NULL;}
    QCFLAC* f=calloc(1,sizeof(*f));if(!f){drflac_close(d);return NULL;}f->decoder=d;return f;
}
void qc_flac_close(QCFLAC* f){if(f){drflac_close(f->decoder);free(f);}}
int qc_flac_rate(QCFLAC* f){return f->decoder->sampleRate;}
int qc_flac_channels(QCFLAC* f){return f->decoder->channels;}
int qc_flac_bits(QCFLAC* f){return f->decoder->bitsPerSample;}
int64_t qc_flac_frames(QCFLAC* f){return (int64_t)f->decoder->totalPCMFrameCount;}
int qc_flac_read(QCFLAC* f,float* out,int frames){if(frames<=0||frames>65536)return -1;return (int)drflac_read_pcm_frames_f32(f->decoder,frames,out);}
int qc_flac_seek(QCFLAC* f,int64_t frame){return frame>=0 && drflac_seek_to_pcm_frame(f->decoder,(drflac_uint64)frame) ? 0:-1;}

#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_IMPLEMENTATION
#include "minimp3/minimp3_ex.h"
#include "Measure.h"
struct QCMP3 { mp3dec_ex_t dec; };
QCMP3* qc_mp3_open(const char* path) {
 QCMP3* m=calloc(1,sizeof(*m));if(!m)return NULL;
 if(mp3dec_ex_open(&m->dec,path,MP3D_SEEK_TO_SAMPLE)){free(m);return NULL;}
 if(m->dec.info.layer!=3||m->dec.info.channels<1||m->dec.info.channels>2||!m->dec.samples){qc_mp3_close(m);return NULL;}
 return m;
}
void qc_mp3_close(QCMP3* m){if(m){mp3dec_ex_close(&m->dec);free(m);}}
int qc_mp3_rate(QCMP3* m){return m->dec.info.hz;}
int qc_mp3_channels(QCMP3* m){return m->dec.info.channels;}
int64_t qc_mp3_frames(QCMP3* m){return m->dec.samples/m->dec.info.channels;}
int qc_mp3_has_gapless(QCMP3* m){return m->dec.start_delay>0;}
int qc_mp3_read(QCMP3* m,float* out,int frames){
 if(frames<=0||frames>65536)return -1;
 size_t n=mp3dec_ex_read(&m->dec,out,(size_t)frames*m->dec.info.channels);
 if(m->dec.last_error||n%m->dec.info.channels)return -1;
 return (int)(n/m->dec.info.channels);
}

int qc_mp3_seek(QCMP3* m,int64_t frame){if(frame<0)return -1;return mp3dec_ex_seek(&m->dec,(uint64_t)frame*m->dec.info.channels);}

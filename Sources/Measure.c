#include "Measure.h"
#include "ebur128.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
struct QC {
 int rate,ch,hop,tick,n,fftHop,finished,error,pcmBits;
 double positiveRail, previous[2];
 int64_t timeline[3][QC_WAVE];
 int64_t rails,flatSamples,flatLongest,flatRuns,flatLength[2];
 QCEvent flatEvents[QC_EVENTS]; int flatCount,flatOpen[2];
 // Low-level plateau candidates are accepted only after observing both edges.
 int64_t lowLength[2],lowSamples;
 double lowBefore[2];
 int64_t fftFill;
 int64_t frames,expected,over;
 ebur128_state *loud,*peak;
 double out[QC_METRICS],sum[2],sq[2],max[2],cross;
 float wave[QC_WAVE];
 double spec[QC_BANDS],low[5],*ring,*win,*re,*im,windowEnergy;
 int ringPos,fftCount;
 double *shorts; size_t shortCount,shortCap;
 QCEvent events[QC_EVENTS]; int eventCount,open[2];
};
static int timebin(QC* q,int64_t frame){return (int)(frame*QC_WAVE/q->expected);}
static double db(double x) { return x>0 ? 20*log10(x) : NAN; }
static void fft(double* r,double* im,int n) {
 for(int i=1,j=0;i<n;i++){int b=n>>1;for(;j&b;b>>=1)j^=b;j^=b;if(i<j){double t=r[i];r[i]=r[j];r[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
 for(int len=2;len<=n;len<<=1){double a=-2*M_PI/len,cr=cos(a),ci=sin(a);
  for(int i=0;i<n;i+=len){double wr=1,wi=0;for(int j=0;j<len/2;j++){int u=i+j,v=u+len/2;double vr=r[v]*wr-im[v]*wi,vi=r[v]*wi+im[v]*wr;r[v]=r[u]-vr;im[v]=im[u]-vi;r[u]+=vr;im[u]+=vi;double t=wr*cr-wi*ci;wi=wr*ci+wi*cr;wr=t;}}}
}
double qc_frequency(int i){return 20*pow(1000.0,(i+0.5)/QC_BANDS);}
static void spectrum(QC* q) {
 const double edges[6]={0,20,60,120,250,500};
 for(int c=0;c<q->ch;c++){
  for(int i=0;i<q->n;i++){q->re[i]=q->ring[((q->ringPos+i)%q->n)*q->ch+c]*q->win[i];q->im[i]=0;}
  fft(q->re,q->im,q->n);
  for(int k=0;k<=q->n/2;k++){
   double f=(double)k*q->rate/q->n;
   double power=(q->re[k]*q->re[k]+q->im[k]*q->im[k])/(q->n*q->windowEnergy*q->ch);
   if(k>0&&k<q->n/2)power*=2;
   double df=(double)q->rate/q->n, binLo=fmax(0,f-df/2), binHi=fmin(q->rate/2.0,f+df/2), width=binHi-binLo;
   for(int b=0;b<5;b++){double overlap=fmax(0,fmin(binHi,edges[b+1])-fmax(binLo,edges[b]));q->low[b]+=power*overlap/width;}
   if(binHi>20&&binLo<20000){
    int first=(int)floor(log(fmax(20,binLo)/20)/log(1000)*QC_BANDS);
    int last=(int)floor(log(fmin(20000,binHi)/20)/log(1000)*QC_BANDS);
    if(first<0)first=0;if(last>=QC_BANDS)last=QC_BANDS-1;
    for(int b=first;b<=last;b++){double lo=20*pow(1000.0,(double)b/QC_BANDS),hi=20*pow(1000.0,(double)(b+1)/QC_BANDS);double overlap=fmax(0,fmin(binHi,hi)-fmax(binLo,lo));q->spec[b]+=power*overlap/width;}
   }
  }
 }
 q->fftCount++;
}
QC* qc_create(int rate,int ch,int64_t expected) {
 if(ch<1||ch>2||rate<44100||rate>192000||expected<=0)return NULL;
 QC* q=calloc(1,sizeof(*q));if(!q)return NULL;
 q->rate=rate;q->ch=ch;q->expected=expected;q->hop=rate/100;
 q->n=1;while(q->n<rate/10.0)q->n*=2;q->fftHop=q->n/4;
 for(int i=0;i<QC_METRICS;i++)q->out[i]=NAN;
 q->open[0]=q->open[1]=-1; q->flatOpen[0]=q->flatOpen[1]=-1;
 q->loud=ebur128_init(ch,rate,EBUR128_MODE_I|EBUR128_MODE_S);
 q->peak=ebur128_init(ch,rate,EBUR128_MODE_TRUE_PEAK);
 q->ring=calloc(q->n*ch,sizeof(double));q->win=calloc(q->n,sizeof(double));q->re=calloc(q->n,sizeof(double));q->im=calloc(q->n,sizeof(double));
 if(!q->loud||!q->peak||!q->ring||!q->win||!q->re||!q->im){qc_destroy(q);return NULL;}
 for(int i=0;i<q->n;i++){q->win[i]=0.5-0.5*cos(2*M_PI*i/q->n);q->windowEnergy+=q->win[i]*q->win[i];}
 return q;
}
void qc_destroy(QC* q){if(!q)return;if(q->loud)ebur128_destroy(&q->loud);if(q->peak)ebur128_destroy(&q->peak);free(q->ring);free(q->win);free(q->re);free(q->im);free(q->shorts);free(q);}
static void max_value(double *p,double v){if(isfinite(v)&&(!isfinite(*p)||v>*p))*p=v;}
// Supplemental evidence below the old absolute threshold. Require a local flat
// extremum with two resolved edges; reject silence/DC and ordinary PCM rounding.
// No global-peak normalization: an unrelated louder transient must not hide it.
static void finish_low_plateau(QC* q,int c,int64_t end,double after) {
 int64_t length=q->lowLength[c];double v=q->previous[c],a=fabs(v);
 if(length<3 || a<1e-4 || a>=0.8)return;
 double sign=v>0?1:-1;
 double step=fmax(a*1e-6,1e-9);
 if(q->pcmBits)step=fmax(step,2*ldexp(1.0,1-q->pcmBits));
 if(sign*(v-q->lowBefore[c])<=step || sign*(v-after)<=step)return;
 q->flatRuns++;q->flatSamples+=length;q->lowSamples+=length;
 if(length>q->flatLongest)q->flatLongest=length;
 int64_t start=end-length+1;
 // Add counts per bin, not per sample: bounded work even for a long flat run.
 int first=timebin(q,start),last=timebin(q,end);
 for(int b=first;b<=last;b++){
  int64_t lo=((int64_t)b*q->expected+QC_WAVE-1)/QC_WAVE;
  int64_t hi=((int64_t)(b+1)*q->expected+QC_WAVE-1)/QC_WAVE-1;
  int64_t from=start>lo?start:lo,to=end<hi?end:hi;
  if(to>=from)q->timeline[0][b]+=to-from+1;
 }
 if(q->flatCount<QC_EVENTS)q->flatEvents[q->flatCount++]=(QCEvent){start,end,c};
}
int qc_push(QC* q,const float* in,int frames){
 if(!q||q->finished||frames<0||q->error)return 1;
 for(int i=0;i<frames*q->ch;i++)if(!isfinite(in[i]))return q->error=2;
 if(q->frames+frames>q->expected)return q->error=3;
 int offset=0;
 while(offset<frames){
  int count=q->hop-q->tick;if(count>frames-offset)count=frames-offset;
  const float* x=in+offset*q->ch;
  if(ebur128_add_frames_float(q->loud,x,count)||ebur128_add_frames_float(q->peak,x,count))return q->error=4;
  for(int i=0;i<count;i++){
   int64_t index=q->frames+i;int wb=timebin(q,index);if(wb>=QC_WAVE)wb=QC_WAVE-1;
   for(int c=0;c<q->ch;c++){
    double v=x[i*q->ch+c],a=fabs(v);q->sum[c]+=v;q->sq[c]+=v*v;if(a>q->max[c])q->max[c]=a;if(a>q->wave[wb])q->wave[wb]=(float)a;
    q->ring[q->ringPos*q->ch+c]=v;
    if(q->pcmBits && (v>=q->positiveRail || v<=-1)){q->rails++;q->timeline[1][wb]++;}
    // Exact plateau evidence; NOT a classification of audible damage. Counts cross chunk boundaries.
    if(a>=0.8){
     if(v==q->previous[c])q->flatLength[c]++;else {q->flatLength[c]=1;q->flatOpen[c]=-1;}
     if(q->flatLength[c]>=3){
      if(q->flatLength[c]==3){q->flatRuns++;q->flatSamples+=3;
       for(int back=0;back<3;back++)q->timeline[0][timebin(q,index-back)]++;
       if(q->flatCount<QC_EVENTS){q->flatOpen[c]=q->flatCount++;q->flatEvents[q->flatOpen[c]]=(QCEvent){index-2,index,c};}}
      else {q->flatSamples++;q->timeline[0][wb]++;if(q->flatOpen[c]>=0)q->flatEvents[q->flatOpen[c]].end=index;}
      if(q->flatLength[c]>q->flatLongest)q->flatLongest=q->flatLength[c];
     }
    }else{q->flatLength[c]=0;q->flatOpen[c]=-1;}
    if(v!=q->previous[c]){
     finish_low_plateau(q,c,index-1,v);
     q->lowBefore[c]=index==0 ? v : q->previous[c];q->lowLength[c]=1;
    }else q->lowLength[c]++;
    q->previous[c]=v;

    // |x| > 1 is float overrange, not evidence of permanent clipping.
    if(a>1){q->over++;q->timeline[2][wb]++;if(q->open[c]<0){if(q->eventCount<QC_EVENTS){q->open[c]=q->eventCount++;q->events[q->open[c]]=(QCEvent){index,index,c};}}else q->events[q->open[c]].end=index;}
    else q->open[c]=-1;
   }
   if(q->ch==2)q->cross+=(double)x[i*2]*x[i*2+1];
   q->ringPos=(q->ringPos+1)%q->n;q->fftFill++;
   if(q->fftFill>=q->n&&(q->fftFill-q->n)%q->fftHop==0)spectrum(q);
  }
  q->frames+=count;q->tick+=count;offset+=count;
  if(q->tick==q->hop){
   q->tick=0;double v;
   if(q->frames>=q->rate*0.4&&ebur128_loudness_momentary(q->loud,&v)==0)max_value(&q->out[QC_M],v);
   if(q->frames>=q->rate*3&&q->frames%(q->hop*10)==0&&ebur128_loudness_shortterm(q->loud,&v)==0){
    max_value(&q->out[QC_S],v);
    if(isfinite(v)&&v>=-70){
     if(q->shortCount==q->shortCap){size_t cap=q->shortCap?q->shortCap*2:1024;double* p=realloc(q->shorts,cap*sizeof(double));if(!p)return q->error=4;q->shorts=p;q->shortCap=cap;}
     q->shorts[q->shortCount++]=v;
    }
   }
  }
 }
 return 0;
}
static int compare(const void* a,const void* b){double x=*(double*)a,y=*(double*)b;return(x>y)-(x<y);}
int qc_finish(QC* q){
 if(!q||q->error||q->frames!=q->expected)return 1;if(q->finished)return 0;q->finished=1;
 double v;
 if(q->frames>=q->rate*0.4&&ebur128_loudness_global(q->loud,&v)==0&&isfinite(v))q->out[QC_I]=v;
 // Flush only the independent peak state. Never pad loudness or the source duration.
 float zeros[128]={0};if(ebur128_add_frames_float(q->peak,zeros,64))return 1;
 double tp=0;
 for(int c=0;c<q->ch;c++){ebur128_true_peak(q->peak,c,&v);if(v>tp)tp=v;q->out[QC_RMS_L+c]=db(sqrt(q->sq[c]/q->frames));q->out[QC_CREST_L+c]=q->sq[c]>0?db(q->max[c])-q->out[QC_RMS_L+c]:NAN;q->out[QC_DC_L+c]=q->sum[c]/q->frames;}
 q->out[QC_TP]=db(tp);q->out[QC_PEAK]=db(fmax(q->max[0],q->max[1]));
 if(q->ch==2){double a=q->sq[0]-q->sum[0]*q->sum[0]/q->frames,b=q->sq[1]-q->sum[1]*q->sum[1]/q->frames,c=q->cross-q->sum[0]*q->sum[1]/q->frames;
  if(a/q->frames>1e-12&&b/q->frames>1e-12)q->out[QC_CORR]=fmax(-1,fmin(1,c/sqrt(a*b)));
  double total=q->sq[0]+q->sq[1],mono=(total+2*q->cross)/2;
  if(total/q->frames>1e-12)q->out[QC_MONO]=mono>0?10*log10(mono/total):-INFINITY;
 }
 if(q->shortCount){double energy=0;for(size_t i=0;i<q->shortCount;i++)energy+=pow(10,q->shorts[i]/10);double gate=10*log10(energy/q->shortCount)-20;size_t n=0;for(size_t i=0;i<q->shortCount;i++)if(q->shorts[i]>=gate)q->shorts[n++]=q->shorts[i];qsort(q->shorts,n,sizeof(double),compare);if(n)q->out[QC_LRA]=q->shorts[(size_t)round((n-1)*0.95)]-q->shorts[(size_t)round((n-1)*0.1)];}
 // Short files have no reliable spectrum: do not invent a zero-padded full window.
 if(q->fftCount){for(int b=0;b<QC_BANDS;b++){double lo=20*pow(1000.0,(double)b/QC_BANDS),hi=20*pow(1000.0,(double)(b+1)/QC_BANDS);q->spec[b]/=q->fftCount*(hi-lo);}for(int b=0;b<5;b++)q->low[b]/=q->fftCount;}
 return 0;
}
double qc_value(QC* q,int i){return i>=0&&i<QC_METRICS?q->out[i]:NAN;}
const float* qc_wave(QC* q){return q->wave;}
const double* qc_spectrum(QC* q){return q->spec;}
const double* qc_low_bands(QC* q){return q->low;}
const QCEvent* qc_events(QC* q){return q->events;}
int qc_event_count(QC* q){return q->eventCount;}
int64_t qc_over_samples(QC* q){return q->over;}
int64_t qc_frames(QC* q){return q->frames;}

void qc_set_pcm_bits(QC* q,int bits){if(q && !q->frames && bits>=8 && bits<=24){q->pcmBits=bits;q->positiveRail=1-ldexp(1.0,1-bits);}}
int64_t qc_rail_samples(QC* q){return q->rails;}
int64_t qc_flat_samples(QC* q){return q->flatSamples;}
int64_t qc_flat_longest(QC* q){return q->flatLongest;}
int64_t qc_flat_runs(QC* q){return q->flatRuns;}
const QCEvent* qc_flat_events(QC* q){return q->flatEvents;}
int qc_flat_event_count(QC* q){return q->flatCount;}

const int64_t* qc_timeline(QC* q,int kind){return kind>=0 && kind<3 ? q->timeline[kind] : NULL;}

int64_t qc_low_flat_samples(QC* q){return q->lowSamples;}

// Preview-only meter: same loudness/true-peak backend, without diagnostic FFTs,
// waveform, clipping, arrangement or dynamics analysis. Feed rendered float samples.
struct QCPreviewMeter { ebur128_state *loud,*peak; int channels; };
QCPreviewMeter* qcp_create(int rate,int channels) {
 if(rate<=0 || channels<1 || channels>2)return NULL;
 QCPreviewMeter* m=calloc(1,sizeof(*m));if(!m)return NULL;
 m->channels=channels;m->loud=ebur128_init(channels,rate,EBUR128_MODE_I);
 m->peak=ebur128_init(channels,rate,EBUR128_MODE_TRUE_PEAK);
 if(!m->loud || !m->peak){qcp_destroy(m);return NULL;}return m;
}
void qcp_destroy(QCPreviewMeter* m){if(!m)return;if(m->loud)ebur128_destroy(&m->loud);if(m->peak)ebur128_destroy(&m->peak);free(m);}
int qcp_push(QCPreviewMeter* m,const float* x,int frames){return !m || frames<0 || ebur128_add_frames_float(m->loud,x,frames) || ebur128_add_frames_float(m->peak,x,frames);}
int qcp_finish(QCPreviewMeter* m,double* loudness,double* peakDB){
 if(!m)return 1;float zeros[128]={0};double v=0,peak=0;
 if(ebur128_add_frames_float(m->peak,zeros,64))return 1;
 if(ebur128_loudness_global(m->loud,loudness))return 1;
 for(int c=0;c<m->channels;c++){if(ebur128_true_peak(m->peak,c,&v))return 1;if(v>peak)peak=v;}
 *peakDB=peak>0?20*log10(peak):-INFINITY;return 0;
}

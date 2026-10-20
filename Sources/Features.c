#include "Features.h"
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
typedef struct {double square,power[8],lowmax,lowmono;int64_t samples;int spectra;} Slice;
struct QCT {int rate,ch,n,hop,pos,count;int64_t expected,frames;double *ring,*win,*re,*im,*leftre,*leftim,we;Slice *slices;};
static double decibel(double p){return p>1e-30 ? 10*log10(p):NAN;}
static void transform(double*r,double*im,int n){
 for(int i=1,j=0;i<n;i++){int b=n>>1;for(;j&b;b>>=1)j^=b;j^=b;if(i<j){double t=r[i];r[i]=r[j];r[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
 for(int len=2;len<=n;len<<=1){double a=-2*M_PI/len,cr=cos(a),ci=sin(a);for(int i=0;i<n;i+=len){double wr=1,wi=0;for(int j=0;j<len/2;j++){int u=i+j,v=u+len/2;double vr=r[v]*wr-im[v]*wi,vi=r[v]*wi+im[v]*wr;r[v]=r[u]-vr;im[v]=im[u]-vi;r[u]+=vr;im[u]+=vi;double t=wr*cr-wi*ci;wi=wr*ci+wi*cr;wr=t;}}}
}
QCT* qct_create(int rate,int ch,int64_t frames){
 if(rate<44100||rate>192000||ch<1||ch>2||frames<=0||frames>(int64_t)rate*86400)return NULL;
 QCT*q=calloc(1,sizeof(*q));if(!q)return NULL;q->rate=rate;q->ch=ch;q->expected=frames;q->n=1;while(q->n<rate/2.0)q->n*=2;q->hop=q->n/2;
 q->count=(int)((frames+2*(int64_t)rate-1)/(2*(int64_t)rate));q->slices=calloc(q->count,sizeof(Slice));
 q->ring=calloc(q->n*ch,sizeof(double));q->win=calloc(q->n,sizeof(double));q->re=calloc(q->n,sizeof(double));q->im=calloc(q->n,sizeof(double));q->leftre=calloc(q->n,sizeof(double));q->leftim=calloc(q->n,sizeof(double));
 if(!q->slices||!q->ring||!q->win||!q->re||!q->im||!q->leftre||!q->leftim){qct_destroy(q);return NULL;}
 for(int i=0;i<q->n;i++){q->win[i]=0.5-0.5*cos(2*M_PI*i/q->n);q->we+=q->win[i]*q->win[i];}return q;
}
void qct_destroy(QCT*q){if(!q)return;free(q->slices);free(q->ring);free(q->win);free(q->re);free(q->im);free(q->leftre);free(q->leftim);free(q);}
static void spectral(QCT*q){
 const double edge[9]={20,60,120,250,500,2000,5000,10000,20000};
 int index=(int)((q->frames-q->n/2)/(2*(int64_t)q->rate));Slice*s=&q->slices[index];double low=0,mono=0;
 for(int c=0;c<q->ch;c++){
  for(int i=0;i<q->n;i++){q->re[i]=q->ring[((q->pos+i)%q->n)*q->ch+c]*q->win[i];q->im[i]=0;}
  transform(q->re,q->im,q->n);
  for(int k=0;k<=q->n/2;k++){
   double factor=(k>0&&k<q->n/2?2.0:1.0)/(q->n*q->we*q->ch);
   double power=(q->re[k]*q->re[k]+q->im[k]*q->im[k])*factor;
   double df=(double)q->rate/q->n,f=k*df,lo=fmax(0,f-df/2),hi=fmin(q->rate/2.0,f+df/2),width=hi-lo;
   for(int b=0;b<8;b++){double overlap=fmax(0,fmin(hi,edge[b+1])-fmax(lo,edge[b]));s->power[b]+=power*overlap/width;}
   double overlap=fmax(0,fmin(hi,120)-fmax(lo,20))/width;low+=power*overlap;
   if(c==0){q->leftre[k]=q->re[k];q->leftim[k]=q->im[k];}
   else{double r=q->re[k]+q->leftre[k],im=q->im[k]+q->leftim[k];mono+=(r*r+im*im)*factor*0.5*overlap;}
  }
 }
 s->spectra++;s->lowmono+=q->ch==1 ? low:mono;if(low>s->lowmax)s->lowmax=low;
}
int qct_push(QCT*q,const float*x,int count){
 if(!q||count<0||q->frames+count>q->expected)return 1;
 for(int i=0;i<count*q->ch;i++)if(!isfinite(x[i]))return 2;
 for(int i=0;i<count;i++){
  Slice*s=&q->slices[q->frames/(2*(int64_t)q->rate)];
  for(int c=0;c<q->ch;c++){double v=x[i*q->ch+c];s->square+=v*v;s->samples++;q->ring[q->pos*q->ch+c]=v;}
  q->pos=(q->pos+1)%q->n;q->frames++;
  if(q->frames>=q->n&&(q->frames-q->n)%q->hop==0)spectral(q);
 }return 0;
}
int qct_count(QCT*q){return q?q->count:0;}
double qct_value(QCT*q,int w,int m){
 if(!q||w<0||w>=q->count)return NAN;Slice*s=&q->slices[w];
 if(m==0)return s->samples?decibel(s->square/s->samples):NAN;
 if(m==11)return (double)s->samples/(q->rate*q->ch);
 if(m==12)return s->spectra;
 if(!s->spectra)return NAN;
 if(m>=1&&m<=8)return decibel(s->power[m-1]/s->spectra);
 double low=s->power[0]+s->power[1];
 if(m==9)return low>1e-25?decibel(s->lowmax*s->spectra/low):NAN;
 if(m==10)return low>1e-25?10*log10(fmax(1e-12,s->lowmono/low)):NAN;
 return NAN;
}

#import "Audio.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <unistd.h>
#import <math.h>

NSString *const bandTitles[BandCount]={@"Bass",@"250 Hz",@"1 kHz",@"4 kHz",@"Treble"};
static const double frequencies[BandCount]={120,250,1000,4000,8000};
static NSString *const displayPairUID=@"local.dual-studio-display-speakers";
typedef struct { double b0,b1,b2,a1,a2,z1[2],z2[2]; } Filter;
typedef struct {
    Filter filters[BandCount];
    atomic_int requested[BandCount];
    int applied[BandCount];
    double rate;
    UInt32 stereo[2][2];
    atomic_ullong signal;
    atomic_bool badLayout;
} Processing;

// RBJ shelving filters for bass and treble, peaking filters for the three middle bands.
static void tune(Filter *f,int band,int gain,double rate) {
    double A=pow(10,gain/40.0), w=2*M_PI*frequencies[band]/rate;
    double c=cos(w), s=sin(w), alpha=s/2, a0;
    if(band==0 || band==BandCount-1) {
        double sign=band==0 ? 1 : -1;
        double p=A+1,m=A-1,r=s*sqrt(2*A);
        f->b0=A*(p-sign*m*c+r); f->b1=2*A*(sign*m-p*c); f->b2=A*(p-sign*m*c-r);
        a0=p+sign*m*c+r; f->a1=-2*(sign*m+p*c); f->a2=p+sign*m*c-r;
    } else {
        f->b0=1+alpha*A; f->b1=-2*c; f->b2=1-alpha*A;
        a0=1+alpha/A; f->a1=-2*c; f->a2=1-alpha/A;
    }
    f->b0/=a0; f->b1/=a0; f->b2/=a0; f->a1/=a0; f->a2/=a0;
}
static OSStatus render(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *in,
 const AudioTimeStamp *inputTime,AudioBufferList *out,const AudioTimeStamp *outputTime,void *ctx) {
    Processing *p=ctx;
    for(UInt32 j=0;j<out->mNumberBuffers;j++) if(out->mBuffers[j].mData)
        memset(out->mBuffers[j].mData,0,out->mBuffers[j].mDataByteSize);
    if(in->mNumberBuffers!=1 || in->mBuffers[0].mNumberChannels!=2 || out->mNumberBuffers!=2) {
        atomic_store(&p->badLayout,true); return noErr;
    }
    const float *input=in->mBuffers[0].mData;
    if(!input) return noErr;
    UInt32 frames=in->mBuffers[0].mDataByteSize/(2*sizeof(float));
    for(int j=0;j<2;j++){
        const AudioBuffer *buf=&out->mBuffers[j];
        if(!buf->mData) return noErr;
        if(MAX(p->stereo[j][0],p->stereo[j][1])>=buf->mNumberChannels){
            atomic_store(&p->badLayout,true);return noErr;
        }
        frames=MIN(frames,buf->mDataByteSize/(sizeof(float)*buf->mNumberChannels));
    }
    for(int b=0;b<BandCount;b++){
        int gain=atomic_load(&p->requested[b]);
        if(gain!=p->applied[b]){tune(&p->filters[b],b,gain,p->rate);p->applied[b]=gain;}
    }
    BOOL signal=NO;
    for(UInt32 i=0;i<frames;i++) for(int ch=0;ch<2;ch++){
        double x=input[2*i+ch];
        for(int b=0;b<BandCount;b++){
            Filter *f=&p->filters[b];
            double y=f->b0*x+f->z1[ch]; f->z1[ch]=f->b1*x-f->a1*y+f->z2[ch];
            f->z2[ch]=f->b2*x-f->a2*y; x=y;
        }
        float sample=fmin(1,fmax(-1,x));
        if(fabs(sample)>0.00001) signal=YES;
        for(int j=0;j<2;j++) {
            AudioBuffer *buf=&out->mBuffers[j];
            ((float *)buf->mData)[i*buf->mNumberChannels+p->stereo[j][ch]]=sample;
        }
    }
    if(signal) atomic_fetch_add(&p->signal,1);
    return noErr;
}
static AudioObjectPropertyAddress property(UInt32 sel,UInt32 scope){
    return (AudioObjectPropertyAddress){sel,scope,kAudioObjectPropertyElementMain};
}
static OSStatus readProp(UInt32 device,UInt32 sel,UInt32 scope,void *value,UInt32 bytes){
    AudioObjectPropertyAddress a=property(sel,scope);
    return AudioObjectGetPropertyData(device,&a,0,NULL,&bytes,value);
}
static NSString *stringProp(UInt32 id,UInt32 sel){
    CFStringRef value=NULL;
    if(readProp(id,sel,kAudioObjectPropertyScopeGlobal,&value,sizeof(value)))return nil;
    return CFBridgingRelease(value);
}
static BOOL floatStreams(UInt32 id,UInt32 scope,double rate,NSUInteger count){
    AudioObjectPropertyAddress a=property(kAudioDevicePropertyStreams,scope);
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,NULL,&size)||size!=count*sizeof(UInt32))return NO;
    UInt32 streams[2]={0};
    if(AudioObjectGetPropertyData(id,&a,0,NULL,&size,streams))return NO;
    for(NSUInteger i=0;i<count;i++){
        AudioStreamBasicDescription f={0};
        if(readProp(streams[i],kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,&f,sizeof(f)) ||
           f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) ||
           f.mBytesPerFrame!=4*f.mChannelsPerFrame || f.mSampleRate!=rate)return NO;
    }
    return YES;
}
@implementation DisplayAudio {
    AudioObjectID _pair,_members[2],_tap,_route;
    AudioDeviceIOProcID _proc;
    Processing _dsp;
    NSString *_issue, *_lastCorrection;
    NSDate *_correctionTime;
    NSTimeInterval _settlingUntil;
}
@synthesize available=_available,volume=_volume,muted=_muted,issue=_issue;
- (BOOL)processing{return _proc!=NULL;}
- (unsigned long long)signalBlocks{return atomic_load(&_dsp.signal);}
- (void)setBand:(NSInteger)b decibels:(int)gain{if(b>=0&&b<BandCount)atomic_store(&_dsp.requested[b],MAX(-12,MIN(12,gain)));}
- (void)refresh{
    UInt32 output=0, members[2]={0}; UInt32 global=kAudioObjectPropertyScopeGlobal;
    readProp(1,kAudioHardwarePropertyDefaultOutputDevice,global,&output,4);
    UInt32 n=sizeof(members); AudioObjectPropertyAddress a=property(kAudioAggregateDevicePropertyActiveSubDeviceList,global);
    _available=[stringProp(output,kAudioDevicePropertyDeviceUID) isEqual:displayPairUID] &&
       !AudioObjectGetPropertyData(output,&a,0,NULL,&n,members)&&n==sizeof(members);
    for(int j=0;_available&&j<2;j++)_available=[stringProp(members[j],kAudioObjectPropertyName) isEqual:@"Studio Display Speakers"];
    if(!_available||memcmp(_members,members,n>sizeof(members)?sizeof(members):n)||atomic_load(&_dsp.badLayout)){
        if(atomic_load(&_dsp.badLayout))_issue=@"Audio layout changed. EQ bypassed.";
        [self stopEQ];
    }
    if(!_available)return;
    _pair=output;memcpy(_members,members,sizeof(members));
    UInt32 mute[2]={0};float levels[2]={0};
    for(int j=0;j<2;j++){
        if(readProp(members[j],kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput,&levels[j],4)||
           readProp(members[j],kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput,&mute[j],4)){
            _available=NO;[self stopEQ];return;
        }
    }
    // The two USB devices can restore different levels independently after waking.
    // Bring the louder speaker down without raising the listening level.
    NSString *first=mute[0]?@"Muted":[NSString stringWithFormat:@"%ld%%",lroundf(100*levels[0])];
    NSString *second=mute[1]?@"Muted":[NSString stringWithFormat:@"%ld%%",lroundf(100*levels[1])];
    _speakerLevels=[NSString stringWithFormat:@"Display 1   %@       Display 2   %@",first,second];
    float shared=MIN(levels[0],levels[1]);
    BOOL drift=fabsf(levels[0]-levels[1])>0.005f;
    if(mute[0]!=mute[1])_matchStatus=@"One display is muted";
    else if(drift)_matchStatus=@"Matching speaker levels…";
    else if(_correctionTime && -[_correctionTime timeIntervalSinceNow]<60)_matchStatus=_lastCorrection;
    else _matchStatus=@"Levels matched";
    if(drift){
        if(NSProcessInfo.processInfo.systemUptime<_settlingUntil)return;
        AudioObjectPropertyAddress vol=property(kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput);
        UInt32 louder=levels[0]>levels[1]?members[0]:members[1];
        if(AudioObjectSetPropertyData(louder,&vol,0,NULL,sizeof(shared),&shared)){
            _issue=@"Could not match speaker volumes.";return;
        }
        _correctionTime=NSDate.date;
        _lastCorrection=[NSString stringWithFormat:@"Auto-matched · Display %d lowered from %ld%% to %ld%%",
            louder==members[0]?1:2,lroundf(100*MAX(levels[0],levels[1])),lroundf(100*shared)];
    }
    _volume=shared;_muted=mute[0]&&mute[1];
}
- (BOOL)setLevel:(float)value muted:(BOOL)muted{
    [self refresh];if(!_available)return NO;
    AudioObjectPropertyAddress vol=property(kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput);
    AudioObjectPropertyAddress mute=property(kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput);
    float before[2];UInt32 prior[2], flag=muted;
    for(int j=0;j<2;j++) if(readProp(_members[j],vol.mSelector,vol.mScope,&before[j],4)||
        readProp(_members[j],mute.mSelector,mute.mScope,&prior[j],4))return NO;
    value=fminf(1,fmaxf(0,value));
    for(int j=0;j<2;j++)if(AudioObjectSetPropertyData(_members[j],&vol,0,NULL,4,&value)||
        AudioObjectSetPropertyData(_members[j],&mute,0,NULL,4,&flag)){
        for(int k=0;k<=j;k++){AudioObjectSetPropertyData(_members[k],&vol,0,NULL,4,&before[k]);
            AudioObjectSetPropertyData(_members[k],&mute,0,NULL,4,&prior[k]);}
        _issue=@"Could not update both speakers.";return NO;
    }
    _settlingUntil=NSProcessInfo.processInfo.systemUptime+0.8;
    _volume=value;_muted=muted;return YES;
}
// Creates the "Both Studio Displays" multi-output device if needed and makes it the system output.
- (BOOL)combineDisplays{
    AudioObjectPropertyAddress a=property(kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal);
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(1,&a,0,NULL,&size)){_issue=@"Could not list audio devices.";return NO;}
    AudioObjectID devices[size/sizeof(AudioObjectID)];
    if(AudioObjectGetPropertyData(1,&a,0,NULL,&size,devices)){_issue=@"Could not list audio devices.";return NO;}
    NSMutableArray *members=[NSMutableArray array];
    AudioObjectID pair=0;
    for(unsigned i=0;i<size/sizeof(AudioObjectID);i++){
        NSString *uid=stringProp(devices[i],kAudioDevicePropertyDeviceUID);
        if([uid isEqual:displayPairUID])pair=devices[i];
        else if(uid&&[stringProp(devices[i],kAudioObjectPropertyName) isEqual:@"Studio Display Speakers"])
            [members addObject:@{@"uid":uid,@"drift":@(members.count>0)}];
    }
    if(!pair&&members.count!=2){_issue=@"Connect two Studio Displays to combine them.";return NO;}
    if(!pair){
        NSDictionary *config=@{@"uid":displayPairUID,@"name":@"Both Studio Displays",@"stacked":@1,@"private":@0,
            @"master":members[0][@"uid"],@"subdevices":members};
        OSStatus err=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&pair);
        if(err){_issue=[NSString stringWithFormat:@"Could not combine displays (%d)",(int)err];return NO;}
    }
    UInt32 outputs[2]={kAudioHardwarePropertyDefaultOutputDevice,kAudioHardwarePropertyDefaultSystemOutputDevice};
    for(int i=0;i<2;i++){
        a=property(outputs[i],kAudioObjectPropertyScopeGlobal);
        AudioObjectSetPropertyData(1,&a,0,NULL,sizeof(pair),&pair);
    }
    _issue=nil;[self refresh];return YES;
}
- (void)stopEQ{
    if(_proc){AudioDeviceStop(_route,_proc);AudioDeviceDestroyIOProcID(_route,_proc);_proc=NULL;}
    if(_route){AudioHardwareDestroyAggregateDevice(_route);_route=0;}
    if(_tap){AudioHardwareDestroyProcessTap(_tap);_tap=0;}
    atomic_store(&_dsp.badLayout,false);
}
- (BOOL)fail:(NSString *)step status:(OSStatus)status{
    _issue=[NSString stringWithFormat:@"%@ (%d)",step,(int)status];[self stopEQ];return NO;
}
- (BOOL)startEQ{
    [self refresh];if(!_available)return NO;if(_proc)return YES;
    _issue=nil; UInt32 global=kAudioObjectPropertyScopeGlobal, out=kAudioDevicePropertyScopeOutput;
    double rate=0; if(readProp(_pair,kAudioDevicePropertyNominalSampleRate,global,&rate,sizeof(rate))||rate<32000)return [self fail:@"Unsupported sample rate" status:-1];
    _dsp.rate=rate; atomic_store(&_dsp.signal,0);
    NSMutableArray *members=[NSMutableArray array];
    for(int j=0;j<2;j++){
        NSString *uid=stringProp(_members[j],kAudioDevicePropertyDeviceUID);if(!uid)return [self fail:@"Display disconnected" status:-1];
        [members addObject:@{@"uid":uid,@"drift":@(j!=0)}];
        UInt32 channels[2]={1,2};readProp(_members[j],kAudioDevicePropertyPreferredChannelsForStereo,out,channels,sizeof(channels));
        for(int ch=0;ch<2;ch++)_dsp.stereo[j][ch]=channels[ch]-1;
    }
    // Scope capture to the public stereo pair. Our output goes directly to the two physical devices.
    pid_t pid=getpid(); AudioObjectID selfProcess=0; UInt32 bytes=sizeof(selfProcess);
    AudioObjectPropertyAddress lookup=property(kAudioHardwarePropertyTranslatePIDToProcessObject,global);
    OSStatus found=AudioObjectGetPropertyData(1,&lookup,sizeof(pid),&pid,&bytes,&selfProcess);
    if(found||!selfProcess)return [self fail:@"Could not isolate app playback" status:found];
    CATapDescription *desc=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[@(selfProcess)]];
    desc.deviceUID=displayPairUID;desc.name=@"Display Sound EQ";desc.privateTap=YES;desc.muteBehavior=CATapMutedWhenTapped;
    OSStatus err=AudioHardwareCreateProcessTap(desc,&_tap);if(err)return [self fail:@"System audio access needed" status:err];
    NSDictionary *config=@{@"name":@"Display Sound EQ",@"uid":NSUUID.UUID.UUIDString,@"private":@1,
        @"master":members[0][@"uid"],@"subdevices":members,@"taps":@[@{@"uid":desc.UUID.UUIDString,@"drift":@1}],@"tapautostart":@0};
    err=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&_route);
    if(err)return [self fail:@"Could not create EQ output" status:err];
    BOOL ready=NO;
    for(int attempt=0;attempt<30 && !ready;attempt++){
        ready=floatStreams(_route,out,rate,2)&&floatStreams(_route,kAudioDevicePropertyScopeInput,rate,1);
        if(!ready)usleep(20000);
    }
    if(!ready)return [self fail:@"Incompatible display streams" status:-1];
    memset(_dsp.filters,0,sizeof(_dsp.filters));
    for(int b=0;b<BandCount;b++)_dsp.applied[b]=INT_MIN;
    err=AudioDeviceCreateIOProcID(_route,render,&_dsp,&_proc);
    if(!err)err=AudioDeviceStart(_route,_proc);
    if(err)return [self fail:@"Could not start EQ" status:err];
    return YES;
}
@end

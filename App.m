#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import "Audio.h"

@interface Controls : NSObject <NSApplicationDelegate,NSWindowDelegate>
@property(strong) DisplayAudio *audio;
@property(strong) NSStatusItem *item;
@property(strong) NSPanel *panel;
@property(strong) NSSlider *level;
@property(strong) NSButton *mute,*eq,*keyboard,*combine;
@property(strong) NSTextField *percentage,*status,*speakers,*match;
@property(strong) NSMutableArray<NSTextField *> *readouts;
@property(strong) NSMutableArray<NSSlider *> *bands;
@property(strong) NSPanel *hud;
@property(strong) NSImageView *speaker;
@property(strong) NSView *fill;
@property(strong) NSTextField *hudValue;
@property(strong) NSTimer *hudTimer;
@property BOOL sawPair;
- (void)showVolumeIndicator;
@property CFMachPortRef keys;
@property CFRunLoopSourceRef keySource;
@end

static CGEventRef mediaKey(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context){
    Controls *app=(__bridge Controls *)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        CGEventTapEnable(app.keys,true);return event;
    }
    NSEvent *key=[NSEvent eventWithCGEvent:event];
    if(key.subtype!=8)return event;
    int code=(key.data1>>16)&0xffff;
    if(code!=NX_KEYTYPE_SOUND_UP&&code!=NX_KEYTYPE_SOUND_DOWN&&code!=NX_KEYTYPE_MUTE)return event;
    [app.audio refresh];if(!app.audio.available)return event;
    BOOL down=((key.data1>>8)&0xff)==NX_KEYDOWN;
    if(down){
        float volume=app.audio.volume;BOOL mute=NO;
        if(code==NX_KEYTYPE_MUTE){
            if(key.data1&1)return NULL;
            mute=!app.audio.muted;
        } else volume+=(code==NX_KEYTYPE_SOUND_UP?1:-1)/16.0;
        if(![app.audio setLevel:volume muted:mute])return event;
        [app showVolumeIndicator];
    }
    return NULL;
}
@implementation Controls
- (void)showVolumeIndicator{
    if(!_hud){
        NSRect bounds=NSMakeRect(0,0,208,44);
        _hud=[[NSPanel alloc] initWithContentRect:bounds styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        _hud.title=@"Display Sound Volume";
        _hud.level=NSStatusWindowLevel;
        _hud.opaque=NO;_hud.backgroundColor=NSColor.clearColor;
        _hud.hasShadow=YES;_hud.ignoresMouseEvents=YES;_hud.hidesOnDeactivate=NO;
        _hud.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *surface=[[NSVisualEffectView alloc] initWithFrame:bounds];
        surface.material=NSVisualEffectMaterialHUDWindow;
        surface.blendingMode=NSVisualEffectBlendingModeBehindWindow;
        surface.state=NSVisualEffectStateActive;
        surface.wantsLayer=YES;surface.layer.cornerRadius=22;surface.layer.masksToBounds=YES;
        _hud.contentView=surface;
        _speaker=[[NSImageView alloc] initWithFrame:NSMakeRect(14,11,24,22)];
        _speaker.contentTintColor=NSColor.labelColor;
        [surface addSubview:_speaker];
        NSView *track=[[NSView alloc] initWithFrame:NSMakeRect(49,19,106,6)];
        track.wantsLayer=YES;track.layer.cornerRadius=3;
        track.layer.backgroundColor=[NSColor.secondaryLabelColor colorWithAlphaComponent:0.3].CGColor;
        [surface addSubview:track];
        _fill=[[NSView alloc] initWithFrame:track.bounds];_fill.wantsLayer=YES;
        _fill.layer.cornerRadius=3;_fill.layer.backgroundColor=NSColor.labelColor.CGColor;
        [track addSubview:_fill];
        _hudValue=[NSTextField labelWithString:@""];
        _hudValue.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
        _hudValue.alignment=NSTextAlignmentRight;_hudValue.frame=NSMakeRect(159,13,36,17);
        [surface addSubview:_hudValue];
    }
    float volume=_audio.muted?0:_audio.volume;
    NSString *symbol=volume==0?@"speaker.slash.fill":volume<0.34?@"speaker.wave.1.fill":volume<0.67?@"speaker.wave.2.fill":@"speaker.wave.3.fill";
    _speaker.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:_audio.muted?@"Muted":@"Volume"];
    _hudValue.stringValue=[NSString stringWithFormat:@"%d%%",(int)lround(volume*100)];
    [_fill setFrameSize:NSMakeSize(round(volume*106),6)];
    NSRect screen=(NSScreen.mainScreen?:NSScreen.screens.firstObject).visibleFrame;
    [_hud setFrameTopLeftPoint:NSMakePoint(NSMaxX(screen)-224,NSMaxY(screen)-12)];
    _hud.alphaValue=1;[_hud orderFrontRegardless];
    [_hudTimer invalidate];
    _hudTimer=[NSTimer scheduledTimerWithTimeInterval:1.15 target:self selector:@selector(fadeIndicator:) userInfo:nil repeats:NO];
}
- (void)fadeIndicator:(NSTimer *)timer{
    // A new key press cancels this timer, including a fade already in progress.
    [timer invalidate];
    if(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion){[_hud orderOut:nil];return;}
    _hudTimer=[NSTimer scheduledTimerWithTimeInterval:0.025 repeats:YES block:^(NSTimer *fade){
        self.hud.alphaValue=MAX(0,self.hud.alphaValue-0.15);
        if(self.hud.alphaValue<0.01){[fade invalidate];[self.hud orderOut:nil];}
    }];
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame{
    NSTextField *label=[NSTextField labelWithString:text];label.frame=frame;
    [_panel.contentView addSubview:label];return label;
}
- (NSButton *)button:(NSString *)text action:(SEL)action frame:(NSRect)frame{
    NSButton *b=[NSButton buttonWithTitle:text target:self action:action];
    b.frame=frame;[_panel.contentView addSubview:b];return b;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note{
    _audio=[DisplayAudio new];_readouts=[NSMutableArray new];_bands=[NSMutableArray new];
    _item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.button.image=[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Display Sound"];
    _item.button.toolTip=@"Display Sound";_item.button.target=self;_item.button.action=@selector(show:);
    _panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,365,412) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _panel.title=@"Display Sound";_panel.releasedWhenClosed=NO;_panel.hidesOnDeactivate=NO;
    [_panel center];
    NSTextField *title=[self label:@"Both Studio Displays" frame:NSMakeRect(20,364,280,30)];
    title.font=[NSFont boldSystemFontOfSize:19];
    _speakers=[self label:@"" frame:NSMakeRect(20,338,330,20)];
    _speakers.font=[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _match=[self label:@"" frame:NSMakeRect(20,315,330,20)];
    _match.font=[NSFont systemFontOfSize:12];_match.textColor=NSColor.secondaryLabelColor;
    [self label:@"Volume" frame:NSMakeRect(20,280,65,20)];
    _level=[NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    _level.frame=NSMakeRect(93,279,170,22);[_panel.contentView addSubview:_level];
    _percentage=[self label:@"" frame:NSMakeRect(279,280,66,20)];
    _mute=[self button:@"Mute" action:@selector(mute:) frame:NSMakeRect(16,244,85,28)];
    _eq=[NSButton checkboxWithTitle:@"Shared equalizer" target:self action:@selector(toggleEQ:)];
    _eq.frame=NSMakeRect(117,247,180,24);[_panel.contentView addSubview:_eq];
    for(int i=0;i<BandCount;i++){
        CGFloat y=210-i*29;
        [self label:bandTitles[i] frame:NSMakeRect(20,y,70,20)];
        NSString *key=[NSString stringWithFormat:@"gain%d",i];
        int gain=(int)MAX(-12,MIN(12,[NSUserDefaults.standardUserDefaults integerForKey:key]));
        NSSlider *slider=[NSSlider sliderWithValue:gain minValue:-12 maxValue:12 target:self action:@selector(band:)];
        slider.tag=i;slider.frame=NSMakeRect(93,y,170,22);[_panel.contentView addSubview:slider];[_bands addObject:slider];
        [_readouts addObject:[self label:[NSString stringWithFormat:@"%+d dB",gain] frame:NSMakeRect(279,y,70,20)]];
        [_audio setBand:i decibels:gain];
    }
    _status=[self label:@"" frame:NSMakeRect(20,49,330,39)];_status.maximumNumberOfLines=2;
    _status.font=[NSFont systemFontOfSize:11];_status.textColor=NSColor.secondaryLabelColor;
    _keyboard=[self button:@"Enable volume keys…" action:@selector(authorize:) frame:NSMakeRect(15,9,168,31)];
    _combine=[self button:@"Use both displays" action:@selector(combine:) frame:NSMakeRect(15,9,168,31)];
    [self button:@"Quit" action:@selector(quit:) frame:NSMakeRect(274,9,75,31)];
    [self update:nil];
    if(!_keys)[self show:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(update:) userInfo:nil repeats:YES];
}
- (void)applicationDidBecomeActive:(NSNotification *)note{if(_panel)[self update:nil];}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible{[self show:nil];return NO;}
- (void)show:(id)sender{[NSApp activateIgnoringOtherApps:YES];[_panel makeKeyAndOrderFront:nil];}
- (void)combine:(id)sender{[_audio combineDisplays];[self update:nil];}
- (void)quit:(id)sender{[NSApp terminate:nil];}
- (void)authorize:(id)sender{
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
    [self update:nil];
}
- (void)update:(id)sender{
    [_audio refresh];
    if(_audio.available&&!_sawPair&&[NSUserDefaults.standardUserDefaults boolForKey:@"equalizer"])[_audio startEQ];
    _sawPair=_audio.available;
    if(!_keys&&AXIsProcessTrusted()){
        _keys=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
                CGEventMaskBit(NSEventTypeSystemDefined),mediaKey,(__bridge void *)self);
        if(_keys){_keySource=CFMachPortCreateRunLoopSource(NULL,_keys,0);
            CFRunLoopAddSource(CFRunLoopGetMain(),_keySource,kCFRunLoopCommonModes);CGEventTapEnable(_keys,true);}
    }
    _combine.hidden=_audio.available;
    _keyboard.hidden=_keys!=NULL||!_audio.available;
    _level.enabled=_mute.enabled=_eq.enabled=_audio.available;
    _speakers.stringValue=_audio.available?_audio.speakerLevels?:@"":@"";
    _match.stringValue=_audio.available?_audio.matchStatus?:@"":@"";
    _level.floatValue=_audio.volume;
    _percentage.stringValue=_audio.available?[NSString stringWithFormat:@"%d%%",(int)lround(100*_audio.volume)]:@"—";
    _mute.title=_audio.muted?@"Unmute":@"Mute";_eq.state=_audio.processing;
    for(NSSlider *band in _bands)band.enabled=_audio.processing;
    NSString *keys=_keys?@"Volume keys on":@"Volume keys need Accessibility";
    NSString *eq=_audio.processing?(_audio.signalBlocks?@"EQ processing audio":@"EQ waiting for audio"):@"EQ bypassed";
    _status.stringValue=!_audio.available?(_audio.issue?:@"Play through both Studio Displays as one stereo pair."):(_audio.issue?:[NSString stringWithFormat:@"%@ · %@",keys,eq]);
}
- (void)volumeChanged:(NSSlider *)sender{[_audio setLevel:sender.floatValue muted:NO];[self update:nil];}
- (void)mute:(id)sender{[_audio setLevel:_audio.volume muted:!_audio.muted];[self update:nil];}
- (void)toggleEQ:(id)sender{
    if(_eq.state)[_audio startEQ];else [_audio stopEQ];
    [NSUserDefaults.standardUserDefaults setBool:_audio.processing forKey:@"equalizer"];[self update:nil];
}
- (void)band:(NSSlider *)sender{
    int gain=(int)lround(sender.doubleValue);sender.integerValue=gain;NSInteger i=sender.tag;
    [_audio setBand:i decibels:gain];_readouts[i].stringValue=[NSString stringWithFormat:@"%+d dB",gain];
    [NSUserDefaults.standardUserDefaults setInteger:gain forKey:[NSString stringWithFormat:@"gain%ld",(long)i]];
}
- (void)applicationWillTerminate:(NSNotification *)note{
    [_audio stopEQ];
    if(_keys){CFMachPortInvalidate(_keys);CFRelease(_keySource);CFRelease(_keys);}
}
@end
int main(void){@autoreleasepool{
    NSApplication *app=NSApplication.sharedApplication;Controls *delegate=[Controls new];
    app.delegate=delegate;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];[app run];
    (void)delegate;return 0;
}}

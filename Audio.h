#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <stdatomic.h>

#define BandCount 5
extern NSString *const bandTitles[BandCount];
@interface DisplayAudio : NSObject
@property(readonly) BOOL available, processing, muted;
@property(readonly) float volume;
@property(readonly, copy) NSString *speakerLevels, *matchStatus;
@property(readonly) unsigned long long signalBlocks;
@property(readonly, copy) NSString *issue;
- (void)refresh;
- (BOOL)combineDisplays;
- (BOOL)setLevel:(float)value muted:(BOOL)muted;
- (BOOL)startEQ;
- (void)stopEQ;
- (void)setBand:(NSInteger)band decibels:(int)gain;
@end

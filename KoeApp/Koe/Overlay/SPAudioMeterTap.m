#import "SPAudioCaptureManager.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <math.h>

// Lightweight audio-level tap for the recorder overlay.
//
// The existing capture path delivers 16 kHz mono PCM Int16 frames to Rust in
// ~200 ms chunks. Rather than opening a second microphone stream, this file
// wraps that existing callback, derives four 50 ms RMS samples from each frame,
// and feeds them to the overlay at 20 Hz. The extra work is one linear pass over
// audio that is already in memory (~16k samples/sec), which is negligible.

NSString * const SPAudioLevelDidUpdateNotification = @"SPAudioLevelDidUpdateNotification";
NSString * const SPAudioLevelValueKey = @"level";

static float SPClamp01(float value) {
    return fminf(1.0f, fmaxf(0.0f, value));
}

static float SPNormalizeRMS(const int16_t *samples, NSUInteger count) {
    if (!samples || count == 0) return 0.0f;

    double sumSquares = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        double s = (double)samples[i] / 32768.0;
        sumSquares += s * s;
    }

    double rms = sqrt(sumSquares / (double)count);
    double db = 20.0 * log10(fmax(rms, 1.0e-5));

    // Speech tends to live roughly between -50 dBFS and -8 dBFS. Compress the
    // visual range slightly so quiet speech remains legible without making the
    // meter feel jumpy at normal speaking levels.
    float normalized = SPClamp01((float)((db + 50.0) / 42.0));
    return powf(normalized, 0.72f);
}

static void SPPostAudioLevel(float level, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:SPAudioLevelDidUpdateNotification
                          object:nil
                        userInfo:@{SPAudioLevelValueKey: @(level)}];
    });
}

static void SPEmitLevelsFromPCM(const void *buffer, uint32_t length) {
    if (!buffer || length < sizeof(int16_t)) return;

    const int16_t *samples = (const int16_t *)buffer;
    NSUInteger sampleCount = length / sizeof(int16_t);

    // Split the 200 ms ASR frame into four meter slices. If a provider ever
    // changes the frame size, degrade gracefully instead of assuming 3200.
    NSUInteger sliceCount = MIN((NSUInteger)4, MAX((NSUInteger)1, sampleCount / 400));
    NSUInteger samplesPerSlice = sampleCount / sliceCount;
    if (samplesPerSlice == 0) return;

    for (NSUInteger i = 0; i < sliceCount; i++) {
        NSUInteger start = i * samplesPerSlice;
        NSUInteger count = (i == sliceCount - 1) ? (sampleCount - start) : samplesPerSlice;
        float level = SPNormalizeRMS(samples + start, count);
        SPPostAudioLevel(level, (NSTimeInterval)i * 0.05);
    }
}

@implementation SPAudioCaptureManager (SPRecorderMeterTap)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self,
            @selector(startCaptureWithAudioCallback:includePreRoll:));
        Method replacement = class_getInstanceMethod(self,
            @selector(sp_recorder_startCaptureWithAudioCallback:includePreRoll:));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

- (BOOL)sp_recorder_startCaptureWithAudioCallback:(SPAudioFrameCallback)callback
                                    includePreRoll:(BOOL)includePreRoll {
    SPAudioFrameCallback wrapped = ^(const void *buffer, uint32_t length, uint64_t timestamp) {
        SPEmitLevelsFromPCM(buffer, length);
        if (callback) callback(buffer, length, timestamp);
    };

    // After method_exchangeImplementations, this selector invokes the original
    // SPAudioCaptureManager implementation.
    return [self sp_recorder_startCaptureWithAudioCallback:wrapped
                                             includePreRoll:includePreRoll];
}

@end

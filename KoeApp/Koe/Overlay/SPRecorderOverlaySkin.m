#import "SPOverlayPanel.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

extern NSString * const SPAudioLevelDidUpdateNotification;
extern NSString * const SPAudioLevelValueKey;

typedef NS_ENUM(NSInteger, SPRecorderVisualState) {
    SPRecorderVisualStateListening = 0,
    SPRecorderVisualStateTranscribing,
    SPRecorderVisualStateComplete,
    SPRecorderVisualStateError,
};

// Compact, accessory-scale geometry. The goal is closer to Aqua / Monologue:
// visible when useful, never visually dominant.
static const CGFloat kListeningWidth = 304.0;
static const CGFloat kListeningHeight = 46.0;
static const CGFloat kExpandedWidth = 432.0;
static const CGFloat kExpandedHeight = 48.0;
static const CGFloat kBottomMargin = 14.0;
static const NSInteger kWaveBarCount = 11;
static const void *kRecorderViewKey = &kRecorderViewKey;

static void SPSetEllipsePath(CAShapeLayer *layer) {
    CGPathRef path = CGPathCreateWithEllipseInRect(layer.bounds, NULL);
    layer.path = path;
    CGPathRelease(path);
}

static void SPSetRoundedPath(CAShapeLayer *layer, CGFloat radius) {
    CGPathRef path = CGPathCreateWithRoundedRect(layer.bounds, radius, radius, NULL);
    layer.path = path;
    CGPathRelease(path);
}

@interface SPRecorderBarView : NSView
@property (nonatomic, assign) SPRecorderVisualState visualState;
@property (nonatomic, copy) NSString *transcript;
@property (nonatomic, strong) NSDate *recordingStartedAt;
@property (nonatomic, strong) NSTimer *elapsedTimer;
@property (nonatomic, strong) NSTextField *timeLabel;
@property (nonatomic, strong) NSTextField *textLabel;
@property (nonatomic, strong) NSTextField *badgeLabel;
@property (nonatomic, strong) CAGradientLayer *bodyGradient;
@property (nonatomic, strong) CAShapeLayer *bodyBorder;
@property (nonatomic, strong) CAShapeLayer *buttonDisc;
@property (nonatomic, strong) CAShapeLayer *buttonGlyph;
@property (nonatomic, strong) CAShapeLayer *knobDisc;
@property (nonatomic, strong) CAShapeLayer *knobIndicator;
@property (nonatomic, strong) NSMutableArray<CALayer *> *waveBars;
@property (nonatomic, strong) NSMutableArray<CALayer *> *levelDots;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *history;
@property (nonatomic, assign) CGFloat smoothedLevel;
- (void)applyVisualState:(SPRecorderVisualState)state;
- (void)updateAudioLevel:(CGFloat)level;
- (void)updateTranscript:(NSString *)text;
- (void)showBadge:(NSString *)text;
@end

@implementation SPRecorderBarView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = NSColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.15;
    self.layer.shadowRadius = 7.0;
    self.layer.shadowOffset = CGSizeMake(0.0, -1.5);

    _bodyGradient = [CAGradientLayer layer];
    // Subtle warm aluminium instead of a high-contrast "hardware slab".
    _bodyGradient.colors = @[
        (__bridge id)[NSColor colorWithWhite:0.945 alpha:1.0].CGColor,
        (__bridge id)[NSColor colorWithWhite:0.885 alpha:1.0].CGColor,
        (__bridge id)[NSColor colorWithWhite:0.925 alpha:1.0].CGColor,
    ];
    _bodyGradient.locations = @[@0.0, @0.54, @1.0];
    _bodyGradient.startPoint = CGPointMake(0.0, 0.0);
    _bodyGradient.endPoint = CGPointMake(1.0, 1.0);
    _bodyGradient.masksToBounds = YES;
    [self.layer addSublayer:_bodyGradient];

    _bodyBorder = [CAShapeLayer layer];
    _bodyBorder.fillColor = NSColor.clearColor.CGColor;
    _bodyBorder.strokeColor = [NSColor colorWithWhite:0.10 alpha:0.16].CGColor;
    _bodyBorder.lineWidth = 0.75;
    [self.layer addSublayer:_bodyBorder];

    _buttonDisc = [CAShapeLayer layer];
    _buttonDisc.fillColor = [NSColor colorWithWhite:0.075 alpha:0.98].CGColor;
    _buttonDisc.strokeColor = [NSColor colorWithWhite:0.0 alpha:0.30].CGColor;
    _buttonDisc.lineWidth = 0.75;
    [self.layer addSublayer:_buttonDisc];

    _buttonGlyph = [CAShapeLayer layer];
    _buttonGlyph.lineCap = kCALineCapRound;
    _buttonGlyph.lineJoin = kCALineJoinRound;
    _buttonGlyph.lineWidth = 2.2;
    [self.layer addSublayer:_buttonGlyph];

    _knobDisc = [CAShapeLayer layer];
    _knobDisc.fillColor = [NSColor colorWithWhite:0.82 alpha:1.0].CGColor;
    _knobDisc.strokeColor = [NSColor colorWithWhite:0.18 alpha:0.72].CGColor;
    _knobDisc.lineWidth = 0.8;
    [self.layer addSublayer:_knobDisc];

    _knobIndicator = [CAShapeLayer layer];
    _knobIndicator.fillColor = [NSColor colorWithWhite:0.14 alpha:0.95].CGColor;
    [self.layer addSublayer:_knobIndicator];

    _timeLabel = [NSTextField labelWithString:@"0:00"];
    _timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightMedium];
    _timeLabel.textColor = [NSColor colorWithWhite:0.10 alpha:0.94];
    _timeLabel.alignment = NSTextAlignmentLeft;
    _timeLabel.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_timeLabel];

    _textLabel = [NSTextField labelWithString:@""];
    _textLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    _textLabel.textColor = [NSColor colorWithWhite:0.08 alpha:0.94];
    _textLabel.alignment = NSTextAlignmentCenter;
    _textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _textLabel.maximumNumberOfLines = 1;
    [self addSubview:_textLabel];

    _badgeLabel = [NSTextField labelWithString:@""];
    _badgeLabel.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    _badgeLabel.textColor = [NSColor colorWithWhite:0.22 alpha:0.72];
    _badgeLabel.alignment = NSTextAlignmentRight;
    _badgeLabel.hidden = YES;
    [self addSubview:_badgeLabel];

    _waveBars = [NSMutableArray arrayWithCapacity:kWaveBarCount];
    _history = [NSMutableArray arrayWithCapacity:kWaveBarCount];
    for (NSInteger i = 0; i < kWaveBarCount; i++) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = [NSColor colorWithWhite:0.11 alpha:0.82].CGColor;
        bar.cornerRadius = 1.0;
        [self.layer addSublayer:bar];
        [_waveBars addObject:bar];
        [_history addObject:@0.08];
    }

    // Tiny meter LEDs: just enough to keep a hint of instrument character.
    _levelDots = [NSMutableArray arrayWithCapacity:3];
    for (NSInteger i = 0; i < 3; i++) {
        CALayer *dot = [CALayer layer];
        dot.cornerRadius = 1.5;
        dot.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.34 blue:0.08 alpha:1.0].CGColor;
        dot.opacity = 0.18;
        [self.layer addSublayer:dot];
        [_levelDots addObject:dot];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioLevelNotification:)
                                                 name:SPAudioLevelDidUpdateNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.elapsedTimer invalidate];
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];

    NSRect b = self.bounds;
    CGFloat width = NSWidth(b);
    CGFloat height = NSHeight(b);
    CGFloat cy = NSMidY(b);
    CGFloat radius = floor(height / 2.0);

    // The body occupies the full view. No inset = no black rectangular gutter.
    self.bodyGradient.frame = NSRectToCGRect(b);
    self.bodyGradient.cornerRadius = radius;
    self.bodyGradient.masksToBounds = YES;

    self.bodyBorder.frame = CGRectInset(NSRectToCGRect(b), 0.5, 0.5);
    SPSetRoundedPath(self.bodyBorder, MAX(0.0, radius - 0.5));

    CGPathRef shadowPath = CGPathCreateWithRoundedRect(NSRectToCGRect(b), radius, radius, NULL);
    self.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);

    CGFloat controlSize = self.visualState == SPRecorderVisualStateListening ? 30.0 : 32.0;
    CGFloat controlInset = 8.0;
    CGFloat leftX = controlInset;
    CGFloat rightX = width - controlInset - controlSize;

    self.buttonDisc.frame = CGRectMake(leftX, cy - controlSize / 2.0, controlSize, controlSize);
    SPSetEllipsePath(self.buttonDisc);

    CGFloat knobSize = self.visualState == SPRecorderVisualStateListening ? 27.0 : 28.0;
    CGFloat knobX = rightX + (controlSize - knobSize) / 2.0;
    self.knobDisc.frame = CGRectMake(knobX, cy - knobSize / 2.0, knobSize, knobSize);
    SPSetEllipsePath(self.knobDisc);

    self.knobIndicator.frame = CGRectMake(knobX + knobSize / 2.0 - 1.35,
                                          cy - knobSize / 2.0 + 4.2,
                                          2.7, 2.7);
    SPSetEllipsePath(self.knobIndicator);

    // Left cluster stays compact and fixed, so text has a stable central stage.
    CGFloat timeX = leftX + controlSize + 10.0;
    self.timeLabel.frame = NSMakeRect(timeX, floor(cy - 9.0), 52.0, 18.0);

    self.badgeLabel.frame = NSMakeRect(width - 112.0, floor(cy - 8.0), 66.0, 16.0);

    // Listening: a short live waveform, not a decorative full-width graph.
    CGFloat waveStartX = timeX + 65.0;
    CGFloat gap = 3.2;
    CGFloat barWidth = 2.2;
    for (NSInteger i = 0; i < self.waveBars.count; i++) {
        CGFloat level = self.history[i].doubleValue;
        CGFloat barH = 4.0 + level * 14.0;
        self.waveBars[i].frame = CGRectMake(waveStartX + i * (barWidth + gap),
                                            cy - barH / 2.0,
                                            barWidth,
                                            barH);
    }

    // Transcribing / Complete: one centered line in the quiet middle zone.
    CGFloat textLeft = timeX + 61.0;
    CGFloat textRight = rightX - 12.0;
    self.textLabel.frame = NSMakeRect(textLeft,
                                      floor(cy - 9.5),
                                      MAX(0.0, textRight - textLeft),
                                      19.0);

    // LEDs live in the tiny edge gutter, never pushing the knob off symmetry.
    CGFloat ledX = width - 4.5;
    for (NSInteger i = 0; i < self.levelDots.count; i++) {
        self.levelDots[i].frame = CGRectMake(ledX,
                                             cy - 8.0 + i * 6.2,
                                             3.0, 3.0);
    }

    [self updateButtonGlyph];
}

- (void)updateButtonGlyph {
    CGFloat cy = NSMidY(self.bounds);
    CGFloat controlSize = self.visualState == SPRecorderVisualStateListening ? 30.0 : 32.0;
    CGFloat cx = 8.0 + controlSize / 2.0;

    CGMutablePathRef path = CGPathCreateMutable();
    self.buttonGlyph.frame = self.bounds;

    if (self.visualState == SPRecorderVisualStateListening) {
        self.buttonGlyph.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.34 blue:0.08 alpha:1.0].CGColor;
        self.buttonGlyph.strokeColor = NSColor.clearColor.CGColor;
        CGPathAddRoundedRect(path, NULL, CGRectMake(cx - 4.6, cy - 4.6, 9.2, 9.2), 2.2, 2.2);
    } else if (self.visualState == SPRecorderVisualStateTranscribing) {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.94 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 3.4, cy - 5.5);
        CGPathAddLineToPoint(path, NULL, cx - 3.4, cy + 5.5);
        CGPathMoveToPoint(path, NULL, cx + 3.4, cy - 5.5);
        CGPathAddLineToPoint(path, NULL, cx + 3.4, cy + 5.5);
    } else if (self.visualState == SPRecorderVisualStateComplete) {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.96 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 6.5, cy + 0.2);
        CGPathAddLineToPoint(path, NULL, cx - 1.4, cy + 5.2);
        CGPathAddLineToPoint(path, NULL, cx + 7.0, cy - 5.7);
    } else {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.96 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 5.0, cy - 5.0);
        CGPathAddLineToPoint(path, NULL, cx + 5.0, cy + 5.0);
        CGPathMoveToPoint(path, NULL, cx + 5.0, cy - 5.0);
        CGPathAddLineToPoint(path, NULL, cx - 5.0, cy + 5.0);
    }

    self.buttonGlyph.path = path;
    CGPathRelease(path);
}

- (void)audioLevelNotification:(NSNotification *)note {
    NSNumber *value = note.userInfo[SPAudioLevelValueKey];
    if (value) [self updateAudioLevel:value.doubleValue];
}

- (void)applyVisualState:(SPRecorderVisualState)state {
    _visualState = state;

    BOOL listening = state == SPRecorderVisualStateListening;
    BOOL error = state == SPRecorderVisualStateError;

    if (listening) {
        if (!self.recordingStartedAt) self.recordingStartedAt = [NSDate date];
        [self startElapsedTimerIfNeeded];
    } else {
        [self stopElapsedTimer];
    }

    self.timeLabel.hidden = error;
    self.textLabel.hidden = listening;
    self.badgeLabel.hidden = YES;
    self.badgeLabel.stringValue = @"";

    for (CALayer *bar in self.waveBars) bar.hidden = !listening;
    for (CALayer *dot in self.levelDots) {
        dot.hidden = !listening;
        if (!listening) dot.opacity = 0.18;
    }

    if (error && self.textLabel.stringValue.length == 0) {
        self.textLabel.stringValue = @"语音识别失败";
    }

    [self setNeedsLayout:YES];
}

- (void)startElapsedTimerIfNeeded {
    if (self.elapsedTimer) return;
    __weak typeof(self) weakSelf = self;
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                       repeats:YES
                                                         block:^(__unused NSTimer *timer) {
        [weakSelf refreshElapsed];
    }];
    [self refreshElapsed];
}

- (void)stopElapsedTimer {
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
}

- (void)refreshElapsed {
    if (!self.recordingStartedAt) return;
    NSInteger total = MAX(0, (NSInteger)(-[self.recordingStartedAt timeIntervalSinceNow]));
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%ld:%02ld",
                                  (long)(total / 60),
                                  (long)(total % 60)];
}

- (void)updateTranscript:(NSString *)text {
    _transcript = [text copy] ?: @"";
    self.textLabel.stringValue = _transcript;
}

- (void)showBadge:(NSString *)text {
    if (text.length == 0) return;
    self.badgeLabel.stringValue = text;
    self.badgeLabel.hidden = NO;
}

- (void)updateAudioLevel:(CGFloat)level {
    if (self.visualState != SPRecorderVisualStateListening) return;

    CGFloat clamped = MIN(1.0, MAX(0.0, level));
    self.smoothedLevel = self.smoothedLevel * 0.58 + clamped * 0.42;
    [self.history removeObjectAtIndex:0];
    [self.history addObject:@(self.smoothedLevel)];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.07];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    [self setNeedsLayout:YES];

    for (NSInteger i = 0; i < self.levelDots.count; i++) {
        CGFloat threshold = 0.28 + (CGFloat)i * 0.22;
        self.levelDots[i].opacity = self.smoothedLevel >= threshold ? 0.95 : 0.18;
    }
    [CATransaction commit];
}

@end

@implementation SPOverlayPanel (SPRecorderSkin)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSArray<NSString *> *> *pairs = @[
            @[@"updateState:", @"sp_recorder_updateState:"],
            @[@"updateInterimText:", @"sp_recorder_updateInterimText:"],
            @[@"updateDisplayText:", @"sp_recorder_updateDisplayText:"],
            @[@"showResultBadge:", @"sp_recorder_showResultBadge:"],
            @[@"lingerAndDismiss", @"sp_recorder_lingerAndDismiss"],
            @[@"lingerAndDismissWithDuration:", @"sp_recorder_lingerAndDismissWithDuration:"],
            @[@"dismissToIdle", @"sp_recorder_dismissToIdle"],
        ];

        for (NSArray<NSString *> *pair in pairs) {
            Method original = class_getInstanceMethod(self, NSSelectorFromString(pair[0]));
            Method replacement = class_getInstanceMethod(self, NSSelectorFromString(pair[1]));
            if (original && replacement) {
                method_exchangeImplementations(original, replacement);
            }
        }
    });
}

- (NSPanel *)sp_recorder_panel {
    id value = nil;
    @try {
        value = [self valueForKey:@"panel"];
    } @catch (__unused NSException *exception) {
    }
    return [value isKindOfClass:NSPanel.class] ? value : nil;
}

- (SPRecorderBarView *)sp_recorder_view {
    SPRecorderBarView *view = objc_getAssociatedObject(self, kRecorderViewKey);
    if (view) return view;

    NSPanel *panel = [self sp_recorder_panel];
    if (!panel) return nil;

    // The old overlay hosts an NSVisualEffectView. Keeping it as the content
    // view leaves a rectangular material layer behind the new capsule. Replace
    // that host completely with a transparent root so only our rounded layer is
    // rendered. This is the fix for the visible rectangular frame.
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0,
                                                            NSWidth(panel.contentView.bounds),
                                                            NSHeight(panel.contentView.bounds))];
    root.wantsLayer = YES;
    root.layer.backgroundColor = NSColor.clearColor.CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    panel.backgroundColor = NSColor.clearColor;
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.contentView = root;

    view = [[SPRecorderBarView alloc] initWithFrame:root.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:view];

    objc_setAssociatedObject(self,
                             kRecorderViewKey,
                             view,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

- (void)sp_recorder_placeWidth:(CGFloat)width
                        height:(CGFloat)height
                      animated:(BOOL)animated {
    NSPanel *panel = [self sp_recorder_panel];
    SPRecorderBarView *view = [self sp_recorder_view];
    NSScreen *screen = NSScreen.mainScreen ?: panel.screen;
    if (!panel || !view || !screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect target = NSMakeRect(NSMidX(visible) - width / 2.0,
                               NSMinY(visible) + kBottomMargin,
                               width,
                               height);

    if (animated && panel.isVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.14;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [[panel animator] setFrame:target display:YES];
        }];
    } else {
        [panel setFrame:target display:YES];
    }
}

- (void)sp_recorder_showPanel {
    NSPanel *panel = [self sp_recorder_panel];
    if (!panel) return;

    BOOL wasVisible = panel.isVisible && panel.alphaValue > 0.01;
    [panel orderFrontRegardless];
    if (!wasVisible) panel.alphaValue = 0.0;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = wasVisible ? 0.07 : 0.12;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        panel.animator.alphaValue = 1.0;
    }];
}

- (void)sp_recorder_hidePanel {
    NSPanel *panel = [self sp_recorder_panel];
    if (!panel || !panel.isVisible) return;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.13;
        panel.animator.alphaValue = 0.0;
    } completionHandler:^{
        [panel orderOut:nil];
    }];
}

- (void)sp_recorder_updateState:(NSString *)state {
    SPRecorderBarView *view = [self sp_recorder_view];
    if (!view) {
        [self sp_recorder_updateState:state];
        return;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(sp_recorder_performDismiss)
                                               object:nil];

    if ([state hasPrefix:@"recording"]) {
        if (!view.elapsedTimer) {
            view.recordingStartedAt = [NSDate date];
            [view updateTranscript:@""];
        }
        [view applyVisualState:SPRecorderVisualStateListening];
        [self sp_recorder_placeWidth:kListeningWidth
                              height:kListeningHeight
                            animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state hasPrefix:@"connecting_asr"] ||
               [state hasPrefix:@"finalizing_asr"] ||
               [state isEqualToString:@"correcting"]) {
        [view applyVisualState:SPRecorderVisualStateTranscribing];
        [self sp_recorder_placeWidth:kExpandedWidth
                              height:kExpandedHeight
                            animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state hasPrefix:@"preparing_paste"] ||
               [state isEqualToString:@"pasting"]) {
        [view applyVisualState:SPRecorderVisualStateComplete];
        [self sp_recorder_placeWidth:kExpandedWidth
                              height:kExpandedHeight
                            animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state isEqualToString:@"error"] ||
               [state isEqualToString:@"failed"]) {
        [view applyVisualState:SPRecorderVisualStateError];
        [self sp_recorder_placeWidth:kExpandedWidth
                              height:kExpandedHeight
                            animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state isEqualToString:@"idle"] ||
               [state isEqualToString:@"completed"] ||
               [state isEqualToString:@"cancelled"]) {
        [self sp_recorder_hidePanel];
    }
}

- (void)sp_recorder_updateInterimText:(NSString *)text {
    [[self sp_recorder_view] updateTranscript:text];
}

- (void)sp_recorder_updateDisplayText:(NSString *)text {
    [[self sp_recorder_view] updateTranscript:text];
}

- (void)sp_recorder_showResultBadge:(NSString *)badgeText {
    [[self sp_recorder_view] showBadge:badgeText];
}

- (void)sp_recorder_lingerAndDismiss {
    [self sp_recorder_lingerAndDismissWithDuration:0.78];
}

- (void)sp_recorder_lingerAndDismissWithDuration:(NSTimeInterval)duration {
    NSTimeInterval resolved = duration > 0 ? duration : 0.78;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(sp_recorder_performDismiss)
                                               object:nil];
    [self performSelector:@selector(sp_recorder_performDismiss)
               withObject:nil
               afterDelay:resolved];
}

- (void)sp_recorder_performDismiss {
    [self sp_recorder_hidePanel];
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(overlayPanelDidDismiss:)]) {
        [delegate overlayPanelDidDismiss:self];
    }
}

- (void)sp_recorder_dismissToIdle {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(sp_recorder_performDismiss)
                                               object:nil];
    [self sp_recorder_performDismiss];
}

@end

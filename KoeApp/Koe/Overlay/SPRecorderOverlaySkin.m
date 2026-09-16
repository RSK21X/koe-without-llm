#import "SPOverlayPanel.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

extern NSString * const SPAudioLevelDidUpdateNotification;
extern NSString * const SPAudioLevelValueKey;

typedef NS_ENUM(NSInteger, SPRecorderVisualState) {
    SPRecorderVisualStateListening,
    SPRecorderVisualStateTranscribing,
    SPRecorderVisualStateComplete,
    SPRecorderVisualStateError,
};

static const CGFloat kListeningWidth = 460.0;
static const CGFloat kExpandedWidth = 560.0;
static const CGFloat kBarHeight = 68.0;
static const CGFloat kBottomMargin = 18.0;
static const NSInteger kWaveBarCount = 14;
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
    self.layer.masksToBounds = NO;

    _bodyGradient = [CAGradientLayer layer];
    _bodyGradient.colors = @[
        (__bridge id)[NSColor colorWithWhite:0.91 alpha:1.0].CGColor,
        (__bridge id)[NSColor colorWithWhite:0.77 alpha:1.0].CGColor,
        (__bridge id)[NSColor colorWithWhite:0.88 alpha:1.0].CGColor,
    ];
    _bodyGradient.locations = @[@0.0, @0.52, @1.0];
    _bodyGradient.startPoint = CGPointMake(0.0, 0.0);
    _bodyGradient.endPoint = CGPointMake(1.0, 1.0);
    _bodyGradient.cornerRadius = 20.0;
    _bodyGradient.shadowColor = NSColor.blackColor.CGColor;
    _bodyGradient.shadowOpacity = 0.22;
    _bodyGradient.shadowRadius = 10.0;
    _bodyGradient.shadowOffset = CGSizeMake(0.0, -3.0);
    [self.layer addSublayer:_bodyGradient];

    _bodyBorder = [CAShapeLayer layer];
    _bodyBorder.fillColor = NSColor.clearColor.CGColor;
    _bodyBorder.strokeColor = [NSColor colorWithWhite:0.34 alpha:0.70].CGColor;
    _bodyBorder.lineWidth = 1.0;
    [self.layer addSublayer:_bodyBorder];

    _buttonDisc = [CAShapeLayer layer];
    _buttonDisc.fillColor = [NSColor colorWithWhite:0.075 alpha:1.0].CGColor;
    _buttonDisc.strokeColor = [NSColor colorWithWhite:0.0 alpha:0.75].CGColor;
    _buttonDisc.lineWidth = 1.0;
    _buttonDisc.shadowColor = NSColor.blackColor.CGColor;
    _buttonDisc.shadowOpacity = 0.24;
    _buttonDisc.shadowRadius = 3.0;
    _buttonDisc.shadowOffset = CGSizeMake(0, -1);
    [self.layer addSublayer:_buttonDisc];

    _buttonGlyph = [CAShapeLayer layer];
    _buttonGlyph.lineCap = kCALineCapRound;
    _buttonGlyph.lineJoin = kCALineJoinRound;
    _buttonGlyph.lineWidth = 3.0;
    [self.layer addSublayer:_buttonGlyph];

    _knobDisc = [CAShapeLayer layer];
    _knobDisc.fillColor = [NSColor colorWithWhite:0.70 alpha:1.0].CGColor;
    _knobDisc.strokeColor = [NSColor colorWithWhite:0.18 alpha:0.9].CGColor;
    _knobDisc.lineWidth = 1.2;
    _knobDisc.shadowColor = NSColor.blackColor.CGColor;
    _knobDisc.shadowOpacity = 0.20;
    _knobDisc.shadowRadius = 3.0;
    _knobDisc.shadowOffset = CGSizeMake(0, -1);
    [self.layer addSublayer:_knobDisc];

    _knobIndicator = [CAShapeLayer layer];
    _knobIndicator.fillColor = [NSColor colorWithWhite:0.12 alpha:1.0].CGColor;
    [self.layer addSublayer:_knobIndicator];

    _timeLabel = [NSTextField labelWithString:@"0:00"];
    _timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightMedium];
    _timeLabel.textColor = [NSColor colorWithWhite:0.10 alpha:1.0];
    [self addSubview:_timeLabel];

    _textLabel = [NSTextField wrappingLabelWithString:@""];
    _textLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _textLabel.textColor = [NSColor colorWithWhite:0.10 alpha:0.96];
    _textLabel.maximumNumberOfLines = 2;
    _textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_textLabel];

    _badgeLabel = [NSTextField labelWithString:@""];
    _badgeLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    _badgeLabel.textColor = [NSColor colorWithWhite:0.20 alpha:0.9];
    _badgeLabel.hidden = YES;
    [self addSubview:_badgeLabel];

    _waveBars = [NSMutableArray arrayWithCapacity:kWaveBarCount];
    _history = [NSMutableArray arrayWithCapacity:kWaveBarCount];
    for (NSInteger i = 0; i < kWaveBarCount; i++) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = [NSColor colorWithWhite:0.13 alpha:0.88].CGColor;
        bar.cornerRadius = 1.5;
        [self.layer addSublayer:bar];
        [_waveBars addObject:bar];
        [_history addObject:@0.08];
    }

    _levelDots = [NSMutableArray arrayWithCapacity:6];
    for (NSInteger i = 0; i < 6; i++) {
        CALayer *dot = [CALayer layer];
        dot.cornerRadius = 2.5;
        dot.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.31 blue:0.08 alpha:1.0].CGColor;
        dot.opacity = 0.18;
        [self.layer addSublayer:dot];
        [_levelDots addObject:dot];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioLevelNotification:)
                                                 name:SPAudioLevelDidUpdateNotification
                                               object:nil];
    [self applyVisualState:SPRecorderVisualStateListening];
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
    CGFloat cy = NSMidY(b);

    CGRect bodyRect = CGRectInset(NSRectToCGRect(b), 6.0, 7.0);
    self.bodyGradient.frame = bodyRect;
    self.bodyBorder.frame = bodyRect;
    SPSetRoundedPath(self.bodyBorder, 20.0);

    CGFloat buttonSize = 46.0;
    self.buttonDisc.frame = CGRectMake(18.0, cy - buttonSize / 2.0, buttonSize, buttonSize);
    SPSetEllipsePath(self.buttonDisc);

    CGFloat knobSize = 45.0;
    CGFloat knobX = NSWidth(b) - 73.0;
    self.knobDisc.frame = CGRectMake(knobX, cy - knobSize / 2.0, knobSize, knobSize);
    SPSetEllipsePath(self.knobDisc);
    self.knobIndicator.frame = CGRectMake(knobX + knobSize / 2.0 - 2.0,
                                          cy - knobSize / 2.0 + 7.0, 4.0, 4.0);
    SPSetEllipsePath(self.knobIndicator);

    self.timeLabel.frame = NSMakeRect(82.0, 16.0, 66.0, 22.0);
    self.badgeLabel.frame = NSMakeRect(82.0, 41.0, 90.0, 16.0);

    CGFloat waveStartX = 151.0;
    CGFloat gap = 4.0;
    CGFloat barWidth = 3.0;
    for (NSInteger i = 0; i < self.waveBars.count; i++) {
        CGFloat level = self.history[i].doubleValue;
        CGFloat h = 5.0 + level * 24.0;
        self.waveBars[i].frame = CGRectMake(waveStartX + i * (barWidth + gap),
                                            cy - h / 2.0, barWidth, h);
    }

    CGFloat textX = 151.0;
    self.textLabel.frame = NSMakeRect(textX, 36.0, MAX(0.0, knobX - 20.0 - textX), 29.0);

    CGFloat dotX = NSWidth(b) - 17.0;
    for (NSInteger i = 0; i < self.levelDots.count; i++) {
        self.levelDots[i].frame = CGRectMake(dotX, 18.0 + i * 7.0, 5.0, 5.0);
    }

    [self updateButtonGlyph];
}

- (void)updateButtonGlyph {
    CGFloat cy = NSMidY(self.bounds);
    CGFloat cx = 41.0;
    CGMutablePathRef path = CGPathCreateMutable();
    self.buttonGlyph.frame = self.bounds;

    if (self.visualState == SPRecorderVisualStateListening) {
        self.buttonGlyph.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.31 blue:0.08 alpha:1.0].CGColor;
        self.buttonGlyph.strokeColor = NSColor.clearColor.CGColor;
        CGPathAddRoundedRect(path, NULL, CGRectMake(cx - 6.5, cy - 6.5, 13.0, 13.0), 3.0, 3.0);
    } else if (self.visualState == SPRecorderVisualStateTranscribing) {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.92 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 4.0, cy - 7.0);
        CGPathAddLineToPoint(path, NULL, cx - 4.0, cy + 7.0);
        CGPathMoveToPoint(path, NULL, cx + 4.0, cy - 7.0);
        CGPathAddLineToPoint(path, NULL, cx + 4.0, cy + 7.0);
    } else if (self.visualState == SPRecorderVisualStateComplete) {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.94 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 9.0, cy);
        CGPathAddLineToPoint(path, NULL, cx - 2.0, cy + 7.0);
        CGPathAddLineToPoint(path, NULL, cx + 10.0, cy - 8.0);
    } else {
        self.buttonGlyph.fillColor = NSColor.clearColor.CGColor;
        self.buttonGlyph.strokeColor = [NSColor colorWithWhite:0.94 alpha:1.0].CGColor;
        CGPathMoveToPoint(path, NULL, cx - 7.0, cy - 7.0);
        CGPathAddLineToPoint(path, NULL, cx + 7.0, cy + 7.0);
        CGPathMoveToPoint(path, NULL, cx + 7.0, cy - 7.0);
        CGPathAddLineToPoint(path, NULL, cx - 7.0, cy + 7.0);
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
    self.badgeLabel.hidden = YES;
    self.badgeLabel.stringValue = @"";

    BOOL listening = state == SPRecorderVisualStateListening;
    BOOL complete = state == SPRecorderVisualStateComplete;
    BOOL error = state == SPRecorderVisualStateError;

    if (listening) {
        if (!self.recordingStartedAt) self.recordingStartedAt = [NSDate date];
        [self startElapsedTimerIfNeeded];
    } else {
        [self stopElapsedTimer];
    }

    self.textLabel.hidden = listening;
    self.timeLabel.hidden = error;
    for (CALayer *bar in self.waveBars) bar.hidden = complete || error;
    if (complete || error) {
        for (CALayer *dot in self.levelDots) dot.opacity = 0.18;
    }
    if (error && self.textLabel.stringValue.length == 0) self.textLabel.stringValue = @"语音识别失败";
    [self setNeedsLayout:YES];
}

- (void)startElapsedTimerIfNeeded {
    if (self.elapsedTimer) return;
    __weak typeof(self) weakSelf = self;
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
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
                                  (long)(total / 60), (long)(total % 60)];
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
    self.smoothedLevel = self.smoothedLevel * 0.55 + clamped * 0.45;
    [self.history removeObjectAtIndex:0];
    [self.history addObject:@(self.smoothedLevel)];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.075];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    [self setNeedsLayout:YES];
    for (NSInteger i = 0; i < self.levelDots.count; i++) {
        CGFloat threshold = (CGFloat)(i + 1) / (CGFloat)(self.levelDots.count + 1);
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
            if (original && replacement) method_exchangeImplementations(original, replacement);
        }
    });
}

- (NSPanel *)sp_recorder_panel {
    id value = nil;
    @try { value = [self valueForKey:@"panel"]; } @catch (__unused NSException *exception) {}
    return [value isKindOfClass:NSPanel.class] ? value : nil;
}

- (SPRecorderBarView *)sp_recorder_view {
    SPRecorderBarView *view = objc_getAssociatedObject(self, kRecorderViewKey);
    if (view) return view;

    NSPanel *panel = [self sp_recorder_panel];
    NSView *host = panel.contentView;
    if (!host) return nil;

    if ([host isKindOfClass:NSVisualEffectView.class]) {
        NSVisualEffectView *effect = (NSVisualEffectView *)host;
        effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        effect.state = NSVisualEffectStateInactive;
    }

    for (NSView *subview in host.subviews) subview.hidden = YES;
    view = [[SPRecorderBarView alloc] initWithFrame:host.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [host addSubview:view positioned:NSWindowAbove relativeTo:nil];
    objc_setAssociatedObject(self, kRecorderViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

- (void)sp_recorder_placeWidth:(CGFloat)width animated:(BOOL)animated {
    NSPanel *panel = [self sp_recorder_panel];
    SPRecorderBarView *view = [self sp_recorder_view];
    NSScreen *screen = NSScreen.mainScreen ?: panel.screen;
    if (!panel || !view || !screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect target = NSMakeRect(NSMidX(visible) - width / 2.0,
                               NSMinY(visible) + kBottomMargin,
                               width, kBarHeight);
    view.frame = NSMakeRect(0, 0, width, kBarHeight);

    if (animated && panel.isVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.16;
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
        context.duration = wasVisible ? 0.08 : 0.14;
        panel.animator.alphaValue = 1.0;
    }];
}

- (void)sp_recorder_hidePanel {
    NSPanel *panel = [self sp_recorder_panel];
    if (!panel || !panel.isVisible) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
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

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sp_recorder_performDismiss) object:nil];

    if ([state hasPrefix:@"recording"]) {
        view.recordingStartedAt = [NSDate date];
        [view applyVisualState:SPRecorderVisualStateListening];
        [self sp_recorder_placeWidth:kListeningWidth animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state hasPrefix:@"connecting_asr"] || [state hasPrefix:@"finalizing_asr"] || [state isEqualToString:@"correcting"]) {
        [view applyVisualState:SPRecorderVisualStateTranscribing];
        [self sp_recorder_placeWidth:kExpandedWidth animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        [view applyVisualState:SPRecorderVisualStateComplete];
        [self sp_recorder_placeWidth:kExpandedWidth animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        [view applyVisualState:SPRecorderVisualStateError];
        [self sp_recorder_placeWidth:kExpandedWidth animated:YES];
        [self sp_recorder_showPanel];
    } else if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"] || [state isEqualToString:@"cancelled"]) {
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
    [self sp_recorder_lingerAndDismissWithDuration:0.85];
}

- (void)sp_recorder_lingerAndDismissWithDuration:(NSTimeInterval)duration {
    NSTimeInterval resolved = duration > 0 ? duration : 0.85;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sp_recorder_performDismiss) object:nil];
    [self performSelector:@selector(sp_recorder_performDismiss) withObject:nil afterDelay:resolved];
}

- (void)sp_recorder_performDismiss {
    [self sp_recorder_hidePanel];
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(overlayPanelDidDismiss:)]) {
        [delegate overlayPanelDidDismiss:self];
    }
}

- (void)sp_recorder_dismissToIdle {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sp_recorder_performDismiss) object:nil];
    [self sp_recorder_performDismiss];
}

@end

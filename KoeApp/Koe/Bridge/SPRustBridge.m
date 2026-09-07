#import "SPRustBridge.h"
#import <AppKit/AppKit.h>
#import "koe_core.h"

// ─── Static delegate reference for C callbacks ─────────────────────

static __weak id<SPRustBridgeDelegate> _bridgeDelegate = nil;

/// Monotonic token that tracks the current session.
/// Callbacks carrying a stale token are discarded on the main thread.
static uint64_t _currentSessionToken = 0;

static void bridge_on_session_ready(uint64_t token) {
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidBecomeReady];
        });
    }
}

static void bridge_on_session_error(uint64_t token, const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"unknown error";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidEncounterError:msg];
        });
    }
}

static void bridge_on_session_warning(uint64_t token, const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"unknown warning";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveWarning:msg];
        });
    }
}

static void bridge_on_final_text_ready(uint64_t token, const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveFinalText:txt];
        });
    }
}

static void bridge_on_log_event(int level, const char *message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"";
    NSString *levelStr;
    switch (level) {
        case 0: levelStr = @"ERROR"; break;
        case 1: levelStr = @"WARN"; break;
        case 2: levelStr = @"INFO"; break;
        default: levelStr = @"DEBUG"; break;
    }
    NSLog(@"[Koe/Rust][%@] %@", levelStr, msg);
}

static void bridge_on_state_changed(uint64_t token, const char *state) {
    NSString *stateStr = state ? [NSString stringWithUTF8String:state] : @"unknown";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidChangeState:stateStr];
        });
    }
}

static void bridge_on_interim_text(uint64_t token, const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveInterimText:txt];
        });
    }
}

static void bridge_on_asr_final_text(uint64_t token, const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveAsrFinalText:txt];
        });
    }
}

static void bridge_on_session_result_meta(uint64_t token, const char *asrText,
                                          const char *asrProvider, bool llmApplied) {
    NSString *asr = asrText ? [NSString stringWithUTF8String:asrText] : @"";
    NSString *provider = asrProvider ? [NSString stringWithUTF8String:asrProvider] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveSessionMetaWithAsrText:asr
                                                        provider:provider
                                                      llmApplied:llmApplied ? YES : NO];
        });
    }
}

static void bridge_on_rewrite_text_ready(uint64_t token, const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveRewriteText:txt];
        });
    }
}

// ─── Download callback context ─────────────────────────────────────

@interface _KoeDownloadContext : NSObject
@property (copy) void (^progressBlock)(NSUInteger, NSUInteger, uint64_t, uint64_t, NSString *);
@property (copy) void (^completionBlock)(BOOL, NSString *);
@end
@implementation _KoeDownloadContext
@end

// ─── SPRustBridge Implementation ────────────────────────────────────

@interface SPRustBridge ()
@property (nonatomic, weak) id<SPRustBridgeDelegate> delegate;
@end

@implementation SPRustBridge

- (uint64_t)currentSessionToken {
    return _currentSessionToken;
}

- (instancetype)initWithDelegate:(id<SPRustBridgeDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _bridgeDelegate = delegate;
    }
    return self;
}

- (void)initializeCore {
    // Register callbacks
    struct SPCallbacks callbacks = {
        .on_session_ready = bridge_on_session_ready,
        .on_session_error = bridge_on_session_error,
        .on_session_warning = bridge_on_session_warning,
        .on_final_text_ready = bridge_on_final_text_ready,
        .on_log_event = bridge_on_log_event,
        .on_state_changed = bridge_on_state_changed,
        .on_interim_text = bridge_on_interim_text,
        .on_asr_final_text = bridge_on_asr_final_text,
        .on_rewrite_text_ready = bridge_on_rewrite_text_ready,
        .on_session_result_meta = bridge_on_session_result_meta,
    };
    sp_core_register_callbacks(callbacks);

    // Initialize core (config path unused in Phase 1)
    int32_t result = sp_core_create(NULL);
    if (result != 0) {
        NSLog(@"[Koe] sp_core_create failed: %d", result);
    }
}

- (void)destroyCore {
    sp_core_destroy();
}

- (BOOL)beginSessionWithMode:(SPSessionModeObjC)mode {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    const char *bundleId = frontApp.bundleIdentifier.UTF8String;
    pid_t pid = frontApp.processIdentifier;

    _currentSessionToken++;

    struct SPSessionContext context = {
        .mode = (enum SPSessionMode)mode,
        .frontmost_bundle_id = bundleId,
        .frontmost_pid = (int)pid,
        .session_token = _currentSessionToken,
    };

    int32_t result = sp_core_session_begin(context);
    if (result != 0) {
        NSLog(@"[Koe] sp_core_session_begin failed: %d", result);
        return NO;
    }
    return YES;
}

- (void)pushAudioFrame:(const void *)buffer length:(uint32_t)length timestamp:(uint64_t)timestamp {
    sp_core_push_audio((const uint8_t *)buffer, length, timestamp);
}

- (void)endSession {
    sp_core_session_end();
}

- (void)cancelSession {
    sp_core_session_cancel();
}

- (BOOL)acceptAsrResult {
    return sp_core_accept_asr_result() == 0;
}

- (void)reloadConfig {
    sp_core_reload_config();
}

// ─── Model Management ──────────────────────────────────────────────

- (NSArray<NSString *> *)supportedLocalProviders {
    // Local ASR models are intentionally removed from this build.
    return @[];
}

- (NSArray<NSString *> *)supportedLlmProviders {
    // LLM correction is intentionally removed from this build.
    return @[];
}

- (NSDictionary *)llmRemoteModelsForProfile:(NSDictionary *)profile {
    (void)profile;
    return @{
        @"success": @NO,
        @"models": @[],
        @"message": @"本版本不包含 LLM",
    };
}

- (NSArray<NSDictionary *> *)scanModels {
    // Local ASR models are intentionally removed from this build.
    return @[];
}

- (NSInteger)modelStatus:(NSString *)modelPath mode:(SPModelVerifyMode)mode {
    (void)modelPath;
    (void)mode;
    return 0;
}

static void download_progress_cb(void *ctx, uint32_t file_index, uint32_t file_count,
                                  uint64_t downloaded, uint64_t total, const char *filename) {
    _KoeDownloadContext *dctx = (__bridge _KoeDownloadContext *)ctx;
    void (^block)(NSUInteger, NSUInteger, uint64_t, uint64_t, NSString *) = dctx.progressBlock;
    if (!block) return;
    NSString *name = filename ? [NSString stringWithUTF8String:filename] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        block(file_index, file_count, downloaded, total, name);
    });
}

static void download_status_cb(void *ctx, int32_t status, const char *message) {
    // status 0 = started — download still in progress
    if (status == 0) return;

    // Cleanup must happen on main queue (FIFO with progress dispatches)
    // to avoid racing with in-flight progress callbacks.
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"";
    BOOL success = (status == 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        _KoeDownloadContext *dctx = (__bridge_transfer _KoeDownloadContext *)ctx;
        void (^completionBlock)(BOOL, NSString *) = dctx.completionBlock;
        dctx.progressBlock = nil;
        dctx.completionBlock = nil;
        if (completionBlock) completionBlock(success, msg);
    });
}

- (void)downloadModel:(NSString *)modelPath
             progress:(void (^)(NSUInteger, NSUInteger, uint64_t, uint64_t, NSString *))progressBlock
           completion:(void (^)(BOOL, NSString *))completionBlock {
    (void)modelPath;
    (void)progressBlock;
    if (completionBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(NO, @"本版本不包含本地模型");
        });
    }
}

- (void)cancelDownload:(NSString *)modelPath {
    (void)modelPath;
}

- (NSInteger)removeModelFiles:(NSString *)modelPath {
    (void)modelPath;
    return 0;
}

// ─── Rewrite / Prompt Templates ───────────────────────────────────

- (NSArray<NSDictionary *> *)promptTemplates {
    return @[];
}

- (BOOL)setPromptTemplates:(NSArray<NSDictionary *> *)templates {
    (void)templates;
    return NO;
}

- (BOOL)rewriteWithTemplateIndex:(NSInteger)index asrText:(NSString *)text {
    (void)index;
    (void)text;
    return NO;
}

@end

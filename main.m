/*
 * sysaudio — 录下 Mac 正在播放的声音（系统音频内录）
 *
 * 原理：使用 ScreenCaptureKit 的音频流捕获系统输出，不需要 BlackHole 等虚拟声卡，
 *       也不会录入麦克风或本程序自己的声音。
 * 输出：标准 16-bit PCM WAV；可选调用 ffmpeg 转成 m4a / mp3。
 *
 * 编译：见同目录 build.sh
 */

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>
#import <signal.h>
#import <unistd.h>

static volatile sig_atomic_t gStop = 0;
static void handleSignal(int sig) { (void)sig; gStop = 1; }

static void Print(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Print(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", msg.UTF8String);
    fflush(stdout);
}

static void Warn(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Warn(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "%s\n", msg.UTF8String);
}

#pragma mark - WAV 写入器

typedef struct __attribute__((packed)) {
    char     riff[4];
    uint32_t riffSize;
    char     wave[4];
    char     fmt[4];
    uint32_t fmtSize;
    uint16_t audioFormat;      // 1 = PCM
    uint16_t channels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char     data[4];
    uint32_t dataSize;
} WavHeader;

static inline int16_t FloatToS16(float v) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
}

@interface WavWriter : NSObject {
    FILE *_file;
    NSString *_path;
    double _sampleRate;
    UInt32 _channels;
    int16_t *_scratch;
    size_t _scratchFrames;
    int16_t *_zeros;
    size_t _zeroFrames;
    _Atomic uint64_t _dataBytes;
    BOOL _havePTS;
    double _lastPTS;
    double _lastDuration;
    BOOL _warnedFormat;
}
- (BOOL)openPath:(NSString *)path sampleRate:(double)rate error:(NSError **)error;
- (void)writeSampleBuffer:(CMSampleBufferRef)sample;
- (uint64_t)dataBytes;
- (void)close;
@end

@implementation WavWriter

- (BOOL)openPath:(NSString *)path sampleRate:(double)rate error:(NSError **)error {
    _sampleRate = rate;
    _channels = 2;
    _path = path;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    _file = fopen(path.fileSystemRepresentation, "wb");
    if (!_file) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                           userInfo:@{NSLocalizedDescriptionKey: @"无法创建输出文件"}];
        return NO;
    }
    WavHeader h;
    memset(&h, 0, sizeof(h));
    memcpy(h.riff, "RIFF", 4); memcpy(h.wave, "WAVE", 4);
    memcpy(h.fmt, "fmt ", 4);  memcpy(h.data, "data", 4);
    h.fmtSize = 16; h.audioFormat = 1; h.channels = (uint16_t)_channels;
    h.sampleRate = (uint32_t)rate; h.bitsPerSample = 16;
    h.blockAlign = (uint16_t)(_channels * 2);
    h.byteRate = (uint32_t)(rate * _channels * 2);
    fwrite(&h, sizeof(h), 1, _file);
    atomic_store(&_dataBytes, 0);
    return YES;
}

- (void)ensureScratch:(UInt32)frames {
    if (frames <= _scratchFrames) return;
    _scratch = realloc(_scratch, (size_t)frames * _channels * sizeof(int16_t));
    _scratchFrames = frames;
}

- (void)writeZeroFrames:(UInt32)frames {
    if (!_file || frames == 0) return;
    // 单个音频包最多补 5 秒静音，避免时间戳异常导致文件暴涨
    if (frames > (UInt32)(_sampleRate * 5)) frames = (UInt32)(_sampleRate * 5);
    if (frames > _zeroFrames) {
        _zeros = realloc(_zeros, (size_t)frames * _channels * sizeof(int16_t));
        if (_zeros) memset(_zeros, 0, (size_t)frames * _channels * sizeof(int16_t));
        _zeroFrames = frames;
    }
    if (!_zeros) return;
    fwrite(_zeros, (size_t)_channels * sizeof(int16_t), frames, _file);
    atomic_fetch_add(&_dataBytes, (uint64_t)frames * _channels * sizeof(int16_t));
}

- (void)writeSampleBuffer:(CMSampleBufferRef)sample {
    if (!_file || gStop) return;

    CMTime ptsTime = CMSampleBufferGetPresentationTimeStamp(sample);
    double pts = CMTimeGetSeconds(ptsTime);
    UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sample);
    if (frames == 0) return;
    double duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample));
    if (!(duration > 0)) duration = (double)frames / _sampleRate;

    // 无声音播放时系统不会推送音频包，用时间戳补齐静音，保持时间轴连续
    if (_havePTS && CMTIME_IS_NUMERIC(ptsTime)) {
        double gap = pts - (_lastPTS + _lastDuration);
        if (gap > 0.002) [self writeZeroFrames:(UInt32)(gap * _sampleRate)];
    }
    if (CMTIME_IS_NUMERIC(ptsTime)) {
        _havePTS = YES;
        _lastPTS = pts;
        _lastDuration = duration;
    }

    CMAudioFormatDescriptionRef fmtDesc =
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sample);
    const AudioStreamBasicDescription *asbd =
        fmtDesc ? CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) : NULL;
    BOOL isFloat32 = asbd && asbd->mBitsPerChannel == 32 &&
                     (asbd->mFormatFlags & kAudioFormatFlagIsFloat);
    BOOL nonInterleaved = asbd && (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);

    size_t listSize = 0;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, &listSize, NULL, 0, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, NULL);
    if (st != noErr || listSize == 0) return;

    AudioBufferList *abl = (AudioBufferList *)calloc(1, listSize);
    CMBlockBufferRef blockBuffer = NULL;
    st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, &listSize, abl, listSize, kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
    if (st != noErr || !abl->mBuffers[0].mData) {
        free(abl);
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    [self ensureScratch:frames];
    UInt32 buffers = MIN((UInt32)abl->mNumberBuffers, _channels);

    if (isFloat32 && nonInterleaved) {
        const float *left = (const float *)abl->mBuffers[0].mData;
        const float *right = buffers > 1 ? (const float *)abl->mBuffers[1].mData : left;
        for (UInt32 i = 0; i < frames; i++) {
            _scratch[2 * i]     = FloatToS16(left[i]);
            _scratch[2 * i + 1] = FloatToS16(right[i]);
        }
    } else if (isFloat32) {
        const float *pcm = (const float *)abl->mBuffers[0].mData;
        for (UInt32 i = 0; i < frames; i++) {
            float l = pcm[2 * i];
            float r = buffers > 1 ? pcm[2 * i + 1] : l;
            _scratch[2 * i]     = FloatToS16(l);
            _scratch[2 * i + 1] = FloatToS16(r);
        }
    } else if (asbd && asbd->mBitsPerChannel == 16) {
        if (nonInterleaved) {
            const int16_t *left = (const int16_t *)abl->mBuffers[0].mData;
            const int16_t *right = buffers > 1 ? (const int16_t *)abl->mBuffers[1].mData : left;
            for (UInt32 i = 0; i < frames; i++) {
                _scratch[2 * i]     = left[i];
                _scratch[2 * i + 1] = right[i];
            }
        } else {
            memcpy(_scratch, abl->mBuffers[0].mData,
                   MIN((size_t)frames * _channels * sizeof(int16_t),
                       abl->mBuffers[0].mDataByteSize));
        }
    } else {
        if (!_warnedFormat) {
            Warn(@"⚠️ 遇到未预期的音频格式（bits=%u flags=%u），已按静音处理该包",
                 asbd ? (unsigned)asbd->mBitsPerChannel : 0,
                 asbd ? (unsigned)asbd->mFormatFlags : 0);
            _warnedFormat = YES;
        }
        memset(_scratch, 0, (size_t)frames * _channels * sizeof(int16_t));
    }

    fwrite(_scratch, (size_t)_channels * sizeof(int16_t), frames, _file);
    atomic_fetch_add(&_dataBytes, (uint64_t)frames * _channels * sizeof(int16_t));

    free(abl);
    if (blockBuffer) CFRelease(blockBuffer);
}

- (uint64_t)dataBytes { return atomic_load(&_dataBytes); }

- (void)close {
    if (!_file) return;
    uint64_t data = atomic_load(&_dataBytes);
    uint32_t riffSize = (uint32_t)(sizeof(WavHeader) - 8 + data);
    uint32_t dataSize = (uint32_t)data;
    fseek(_file, 4, SEEK_SET);   fwrite(&riffSize, sizeof(riffSize), 1, _file);
    fseek(_file, 40, SEEK_SET);  fwrite(&dataSize, sizeof(dataSize), 1, _file);
    fclose(_file);
    _file = NULL;
    free(_scratch); _scratch = NULL; _scratchFrames = 0;
    free(_zeros);   _zeros = NULL;   _zeroFrames = 0;
}

@end

#pragma mark - 流回调

@interface Receiver : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, strong) WavWriter *writer;
@end

@implementation Receiver
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeAudio && !gStop) {
        [self.writer writeSampleBuffer:sampleBuffer];
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) Warn(@"⚠️ 音频流中断：%@", error.localizedDescription);
}
@end

#pragma mark - 工具函数

static void PrintHelp(void) {
    Print(@"\n"
          "sysaudio — 录下 Mac 正在播放的声音（系统音频内录）\n"
          "\n"
          "用法：\n"
          "  sysaudio [record] [选项]\n"
          "  sysaudio --check              检查权限与运行环境\n"
          "  sysaudio --list-apps          列出当前可捕获的应用\n"
          "  sysaudio --request-permission 触发系统授权弹窗\n"
          "  sysaudio --help               显示本帮助\n"
          "\n"
          "选项：\n"
          "  -o, --out <路径>     输出文件，默认 ~/Desktop/系统录音_<时间>.wav\n"
          "  -t, --seconds <秒>   录制时长，0 表示按 Ctrl+C 停止（默认 0）\n"
          "  -f, --format <格式>  wav | m4a | mp3（默认 wav，后两者需 ffmpeg）\n"
          "      --keep-wav       转码后保留中间 wav 文件\n"
          "\n"
          "示例：\n"
          "  sysaudio                                    # 一直录，Ctrl+C 结束\n"
          "  sysaudio -t 60 -o ~/Desktop/视频原声.wav    # 录 60 秒\n"
          "  sysaudio -t 30 -f mp3 -o ~/Desktop/原声.mp3 # 直接存成 mp3\n"
          "\n"
          "说明：\n"
          "  · 首次使用需在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」\n"
          "    为终端（或 SysAudioCapture.app）打开权限，授权后重新运行本程序。\n"
          "  · 录制的是系统输出的全部声音，不录入麦克风；播放前请先关闭其他声源。\n"
          "  · 没有声音在播放时，程序会自动补静音，时间轴与真实时间保持一致。\n"
          "");
}

static NSString *FindFFmpeg(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *candidates = [NSMutableArray arrayWithArray:
        @[@"/opt/homebrew/bin/ffmpeg", @"/usr/local/bin/ffmpeg", @"/usr/bin/ffmpeg"]];
    NSString *envPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *dir in [envPath componentsSeparatedByString:@":"]) {
        [candidates addObject:[dir stringByAppendingPathComponent:@"ffmpeg"]];
    }
    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

static SCShareableContent *FetchShareableContent(void) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block SCShareableContent *result = nil;
    [SCShareableContent getShareableContentWithCompletionHandler:
        ^(SCShareableContent *content, NSError *error) {
            if (error) Warn(@"⚠️ 无法获取可捕获内容：%@", error.localizedDescription);
            result = content;
            dispatch_semaphore_signal(sema);
        }];
    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        Warn(@"⚠️ 获取屏幕内容超时，通常是权限未授予。");
        return nil;
    }
    return result;
}

static BOOL EnsurePermission(BOOL interactive) {
    if (CGPreflightScreenCaptureAccess()) return YES;
    Warn(@"\n⚠️ 还缺少「屏幕与系统音频录制」权限。\n"
         "   请打开 系统设置 → 隐私与安全性 → 屏幕与系统音频录制，\n"
         "   为「终端 / iTerm / SysAudioCapture.app」（以你实际启动的程序为准）打开开关，\n"
         "   然后重新运行本命令。授权后可能需要重启终端。\n");
    if (interactive) {
        CGRequestScreenCaptureAccess();
        system("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' >/dev/null 2>&1");
    }
    return NO;
}

static int RunCheck(void) {
    Print(@"系统版本：%@", NSProcessInfo.processInfo.operatingSystemVersionString);
    BOOL granted = CGPreflightScreenCaptureAccess();
    Print(@"屏幕与系统音频录制权限：%@", granted ? @"✅ 已授予" : @"❌ 未授予");
    if (granted) {
        SCShareableContent *content = FetchShareableContent();
        Print(@"可捕获显示器数量：%lu", (unsigned long)content.displays.count);
        Print(@"可捕获应用数量：%lu", (unsigned long)content.applications.count);
    }
    NSString *ffmpeg = FindFFmpeg();
    Print(@"ffmpeg：%@", ffmpeg ?: @"未找到（只能用 wav 输出）");
    Print(@"结论：%@", granted ? @"可以开始录制：sysaudio -t 10 -o ~/Desktop/test.wav"
                               : @"请先授权：sysaudio --request-permission");
    return granted ? 0 : 1;
}

static int ListApps(void) {
    if (!EnsurePermission(NO)) return 1;
    SCShareableContent *content = FetchShareableContent();
    if (!content) return 1;
    Print(@"当前可捕获的应用（名称 / Bundle ID / PID）：");
    for (SCRunningApplication *app in content.applications) {
        Print(@"  %-28@ %-45@ %d", app.applicationName ?: @"?",
              app.bundleIdentifier ?: @"?", app.processID);
    }
    return 0;
}

static BOOL Convert(NSString *ffmpeg, NSString *src, NSString *dst, NSString *format) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:
        @[@"-nostdin", @"-y", @"-loglevel", @"error", @"-i", src]];
    if ([format isEqualToString:@"m4a"]) {
        [args addObjectsFromArray:@[@"-c:a", @"aac", @"-b:a", @"192k"]];
    } else {
        [args addObjectsFromArray:@[@"-c:a", @"libmp3lame", @"-q:a", @"2"]];
    }
    [args addObject:dst];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = ffmpeg;
    task.arguments = args;
    // 不要让 ffmpeg 继承终端的 stdin / 管道，否则可能一直等输入
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) { (void)t; dispatch_semaphore_signal(done); };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        Warn(@"⚠️ 转码启动失败：%@", error.localizedDescription);
        return NO;
    }
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
        [task terminate];
        Warn(@"⚠️ 转码超时，已终止。保留原始 WAV：%@", src);
        return NO;
    }
    if (task.terminationStatus != 0) {
        Warn(@"⚠️ 转码失败（ffmpeg 退出码 %d），保留原始 WAV：%@",
             task.terminationStatus, src);
        return NO;
    }
    return YES;
}

static NSString *DefaultOutputPath(NSString *format) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    NSString *desktop = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:desktop]) desktop = NSHomeDirectory();
    return [desktop stringByAppendingPathComponent:
            [NSString stringWithFormat:@"系统录音_%@.%@", stamp, format]];
}

#pragma mark - 录制主流程

static int RunRecord(NSString *outPath, NSString *format, double seconds, BOOL keepWav) {
    if (!EnsurePermission(YES)) return 1;

    if (![format isEqualToString:@"wav"] && ![format isEqualToString:@"m4a"] &&
        ![format isEqualToString:@"mp3"]) {
        Warn(@"⚠️ 不支持的格式：%@（可用 wav / m4a / mp3）", format);
        return 2;
    }
    NSString *ffmpeg = nil;
    if (![format isEqualToString:@"wav"]) {
        ffmpeg = FindFFmpeg();
        if (!ffmpeg) {
            Warn(@"⚠️ 未找到 ffmpeg，无法输出 %@；已改用 wav。", format);
            format = @"wav";
        }
    }
    if (!outPath) outPath = DefaultOutputPath(format);
    outPath = outPath.stringByExpandingTildeInPath;
    if (outPath.pathExtension.length == 0) {
        outPath = [outPath stringByAppendingPathExtension:format];
    } else if (![outPath.pathExtension.lowercaseString isEqualToString:format]) {
        // -f mp3 -o xxx.wav 这类组合会让中间 WAV 与最终文件同名，统一纠正扩展名
        NSString *corrected = [[outPath stringByDeletingPathExtension]
                                  stringByAppendingPathExtension:format];
        Warn(@"⚠️ 输出扩展名与格式不符，已改为：%@", corrected);
        outPath = corrected;
    }

    SCShareableContent *content = FetchShareableContent();
    if (!content || content.displays.count == 0) {
        Warn(@"⚠️ 没有可用的显示器内容，无法建立音频捕获流。");
        return 1;
    }

    SCContentFilter *filter = [[SCContentFilter alloc]
        initWithDisplay:content.displays.firstObject excludingWindows:@[]];

    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.capturesAudio = YES;
    cfg.excludesCurrentProcessAudio = YES;
    cfg.sampleRate = 48000;
    cfg.channelCount = 2;
    cfg.width = 2;
    cfg.height = 2;
    cfg.minimumFrameInterval = CMTimeMake(1, 1);
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    cfg.showsCursor = NO;

    BOOL needsTranscode = ![format isEqualToString:@"wav"];
    NSString *wavPath = needsTranscode
        ? [[outPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"wav"]
        : outPath;
    if (needsTranscode && [wavPath isEqualToString:outPath]) {
        wavPath = [outPath stringByAppendingString:@".tmp.wav"];
    }

    WavWriter *writer = [[WavWriter alloc] init];
    NSError *error = nil;
    if (![writer openPath:wavPath sampleRate:(double)cfg.sampleRate error:&error]) {
        Warn(@"⚠️ 无法创建文件 %@：%@", wavPath, error.localizedDescription);
        return 1;
    }

    Receiver *receiver = [[Receiver alloc] init];
    receiver.writer = writer;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:receiver];
    dispatch_queue_t audioQueue = dispatch_queue_create("com.workbuddy.sysaudio.audio",
                                                        DISPATCH_QUEUE_SERIAL);
    NSError *addError = nil;
    if (![stream addStreamOutput:receiver type:SCStreamOutputTypeAudio
             sampleHandlerQueue:audioQueue error:&addError]) {
        Warn(@"⚠️ 无法添加音频输出：%@", addError.localizedDescription);
        [writer close];
        return 1;
    }

    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    [stream startCaptureWithCompletionHandler:^(NSError *e) {
        startError = e;
        dispatch_semaphore_signal(started);
    }];
    if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        Warn(@"⚠️ 启动捕获超时，请检查权限。");
        [writer close];
        return 1;
    }
    if (startError) {
        Warn(@"⚠️ 启动捕获失败：%@", startError.localizedDescription);
        [writer close];
        return 1;
    }

    Print(@"● 开始录制系统声音 → %@", outPath);
    Print(@"  按 Ctrl+C 结束%@", seconds > 0
          ? [NSString stringWithFormat:@"（或 %.0f 秒后自动停止）", seconds] : @"");

    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);
    NSDate *begin = [NSDate date];
    NSTimeInterval elapsed = 0;
    while (!gStop) {
        elapsed = -begin.timeIntervalSinceNow;
        if (seconds > 0 && elapsed >= seconds) { gStop = 1; break; }
        int mins = (int)elapsed / 60, secs = (int)elapsed % 60;
        printf("\r  已录制 %02d:%02d  |  %6.1f MB   ", mins, secs,
               (double)[writer dataBytes] / 1024.0 / 1024.0);
        fflush(stdout);
        usleep(250000);
    }
    printf("\n");

    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *e) {
        if (e) Warn(@"⚠️ 停止捕获时出错：%@", e.localizedDescription);
        dispatch_semaphore_signal(stopped);
    }];
    dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [writer close];

    uint64_t bytes = [writer dataBytes];
    if (bytes == 0) {
        Warn(@"⚠️ 没有捕获到任何音频。请确认：1) 录制期间确实有声音在播放；2) 权限已授予。");
        [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];
        return 1;
    }

    NSString *finalPath = outPath;
    if (needsTranscode) {
        Print(@"  正在转换为 %@ …", format.uppercaseString);
        if (!Convert(ffmpeg, wavPath, outPath, format)) {
            Warn(@"⚠️ 转码失败，保留原始 WAV：%@", wavPath);
            finalPath = wavPath;
        } else if (!keepWav) {
            [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];
        }
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalPath
                                                                           error:nil];
    double fileMB = attrs ? [attrs[NSFileSize] doubleValue] / 1024.0 / 1024.0 : 0;
    double durationSec = (double)bytes / (48000.0 * 2 * 2);
    Print(@"✅ 已保存：%@", finalPath);
    Print(@"   时长 %02d:%02d ｜ 大小 %.2f MB ｜ %@", (int)durationSec / 60,
          (int)durationSec % 60, fileMB,
          [finalPath.pathExtension.lowercaseString isEqualToString:@"wav"]
              ? @"WAV 48kHz / 立体声 / 16-bit" : format.uppercaseString);
    return 0;
}

#pragma mark - 入口

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *command = @"record";
        NSString *outPath = nil;
        NSString *format = @"wav";
        double seconds = 0;
        BOOL keepWav = NO;
        BOOL check = NO, listApps = NO, requestPermission = NO, help = NO;
        BOOL formatSpecified = NO;

        NSInteger i = 1;
        if (argc > 1 && strncmp(argv[1], "-", 1) != 0) {
            NSString *first = [NSString stringWithUTF8String:argv[1]];
            NSArray *known = @[@"record", @"check", @"list-apps", @"request-permission", @"help"];
            if ([known containsObject:first]) { command = first; i = 2; }
        }

        for (; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) help = YES;
            else if ([arg isEqualToString:@"--check"]) check = YES;
            else if ([arg isEqualToString:@"--list-apps"]) listApps = YES;
            else if ([arg isEqualToString:@"--request-permission"]) requestPermission = YES;
            else if ([arg isEqualToString:@"--keep-wav"]) keepWav = YES;
            else if ([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--out"]) {
                if (++i >= argc) { Warn(@"⚠️ %@ 缺少参数", arg); return 2; }
                outPath = [NSString stringWithUTF8String:argv[i]];
            }
            else if ([arg isEqualToString:@"-t"] || [arg isEqualToString:@"--seconds"]) {
                if (++i >= argc) { Warn(@"⚠️ %@ 缺少参数", arg); return 2; }
                seconds = atof(argv[i]);
                if (seconds < 0) seconds = 0;
            }
            else if ([arg isEqualToString:@"-f"] || [arg isEqualToString:@"--format"]) {
                if (++i >= argc) { Warn(@"⚠️ %@ 缺少参数", arg); return 2; }
                format = [[NSString stringWithUTF8String:argv[i]] lowercaseString];
                formatSpecified = YES;
            }
            else { Warn(@"⚠️ 未知参数：%@", arg); PrintHelp(); return 2; }
        }

        // 未显式指定 -f 时，按输出文件扩展名推断格式（-o 原声.mp3 等价于 -f mp3）
        if (!formatSpecified && outPath.pathExtension.length > 0) {
            NSString *ext = outPath.pathExtension.lowercaseString;
            if ([@[@"wav", @"m4a", @"mp3"] containsObject:ext]) format = ext;
        }

        if (help || [command isEqualToString:@"help"]) { PrintHelp(); return 0; }
        if (check || [command isEqualToString:@"check"]) return RunCheck();
        if (listApps || [command isEqualToString:@"list-apps"]) return ListApps();
        if (requestPermission || [command isEqualToString:@"request-permission"]) {
            if (CGPreflightScreenCaptureAccess()) {
                Print(@"✅ 已具备「屏幕与系统音频录制」权限，无需额外授权。");
                return 0;
            }
            CGRequestScreenCaptureAccess();
            system("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' >/dev/null 2>&1");
            Print(@"已打开系统设置，请为启动本程序的「终端」或「SysAudioCapture.app」打开开关，然后重新运行命令。");
            return 0;
        }
        return RunRecord(outPath, format, seconds, keepWav);
    }
}

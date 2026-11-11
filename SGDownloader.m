#import "SGDownloader.h"

@interface SGDownloader ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^updateBlock)(NSDictionary *);
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSString *outPath;
@property (nonatomic, assign) NSUInteger segments;
@property (nonatomic, assign) long long bytes;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) NSInteger limitMinutes;
@property (nonatomic, strong) NSString *referer;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *seen;
@end

@implementation SGDownloader

+ (instancetype)shared {
    static SGDownloader *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SGDownloader new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.xiaofeifei.safarigrab.dl", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        cfg.timeoutIntervalForResource = 45;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        cfg.HTTPMaximumConnectionsPerHost = 2;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _seen = [NSMutableSet set];
    }
    return self;
}

- (void)emit:(NSDictionary *)st {
    if (self.updateBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.updateBlock(st); });
    }
}

- (void)startWithPlaylist:(NSString *)url limit:(NSInteger)minutes referer:(NSString *)referer
                   update:(void (^)(NSDictionary *))update {
    if (self.running) [self stop];

    self.running = YES;
    self.updateBlock = update;
    self.limitMinutes = minutes;
    self.referer = referer ?: @"";
    self.segments = 0;
    self.bytes = 0;
    self.duration = 0;
    [self.seen removeAllObjects];

    NSString *dir = @"/var/mobile/Documents/SafariGrab";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd_HHmmss";
    self.outPath = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"live_%@.ts", [f stringFromDate:[NSDate date]]]];
    [[NSFileManager defaultManager] createFileAtPath:self.outPath contents:nil attributes:nil];
    self.handle = [NSFileHandle fileHandleForWritingAtPath:self.outPath];

    [self emit:@{@"state": @"running", @"text": @"正在拉取播放列表…"}];

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{ [weakSelf loopWithURL:[NSURL URLWithString:url] finalURL:nil]; });
}

- (void)stop {
    self.running = NO;
    @try { [self.handle closeFile]; } @catch (__unused NSException *e) {}
    self.handle = nil;
    [self emit:@{@"state": @"done", @"text": @"已停止",
                 @"file": self.outPath ?: @"",
                 @"segments": @(self.segments),
                 @"bytes": @(self.bytes),
                 @"duration": @(self.duration)}];
}

- (NSData *)get:(NSString *)u code:(NSInteger *)code finalURL:(NSURL **)finalURL {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    if (self.referer.length) [req setValue:self.referer forHTTPHeaderField:@"Referer"];

    __block NSData *result = nil;
    __block NSURL *furl = nil;
    __block NSInteger cd = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [self.session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            cd = [(NSHTTPURLResponse *)resp statusCode];
            furl = resp.URL;
            result = data;
            dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    if (code) *code = cd;
    if (finalURL) *finalURL = furl;
    return result;
}

- (void)loopWithURL:(NSURL *)indexURL finalURL:(NSURL *)knownFinal {
    NSURL *current = indexURL;
    double limitSec = self.limitMinutes > 0 ? self.limitMinutes * 60.0 : 0;
    NSInteger lastSeq = -1;
    NSInteger fail = 0;

    while (self.running) {
        if (limitSec > 0 && self.duration >= limitSec) break;

        NSURL *finalURL = nil;
        NSInteger code = -1;
        NSData *d = [self get:current.absoluteString code:&code finalURL:&finalURL];
        if (!d) {
            fail++;
            [self emit:@{@"state": @"running",
                         @"text": [NSString stringWithFormat:@"拉取失败(HTTP %ld)，重试 %ld", (long)code, (long)fail]}];
            if (fail > 30) {
                [self emit:@{@"state": @"failed", @"text": @"连续失败，链接可能已过期"}];
                self.running = NO;
                break;
            }
            [NSThread sleepForTimeInterval:2.0];
            continue;
        }
        fail = 0;

        // ⚠ 相对切片必须以重定向后的最终 URL 为基准
        NSURL *base = finalURL ?: current;
        NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!text) { [NSThread sleepForTimeInterval:1.0]; continue; }

        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        NSInteger mediaSeq = 0;
        double target = 4;
        BOOL ended = NO, encrypted = NO;
        NSMutableArray<NSDictionary *> *segs = [NSMutableArray array];
        double pendingDur = 0;

        for (NSString *raw in lines) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!line.length) continue;

            if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
                mediaSeq = [[line substringFromIndex:22] integerValue];
            } else if ([line hasPrefix:@"#EXT-X-TARGETDURATION:"]) {
                target = [[line substringFromIndex:22] doubleValue];
            } else if ([line hasPrefix:@"#EXT-X-KEY:"] && ![line containsString:@"METHOD=NONE"]) {
                encrypted = YES;
            } else if ([line hasPrefix:@"#EXTINF:"]) {
                NSString *v = [line substringFromIndex:8];
                pendingDur = [[[v componentsSeparatedByString:@","] firstObject] doubleValue];
            } else if ([line hasPrefix:@"#EXT-X-ENDLIST"]) {
                ended = YES;
            } else if (![line hasPrefix:@"#"]) {
                NSURL *u = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
                if (u) [segs addObject:@{@"url": u.absoluteString, @"dur": @(pendingDur)}];
                pendingDur = 0;
            }
        }

        if (encrypted) {
            [self emit:@{@"state": @"failed", @"text": @"该流带 AES-128 加密，暂不支持"}];
            self.running = NO;
            break;
        }
        if (!segs.count) { [NSThread sleepForTimeInterval:1.0]; continue; }

        for (NSUInteger i = 0; i < segs.count && self.running; i++) {
            if (limitSec > 0 && self.duration >= limitSec) break;
            NSInteger seq = mediaSeq + (NSInteger)i;
            if (seq <= lastSeq) continue;
            if ([self.seen containsObject:@(seq)]) continue;

            NSData *sd = [self get:segs[i][@"url"] code:NULL finalURL:NULL];
            if (!sd.length) {
                [self emit:@{@"state": @"running", @"text": [NSString stringWithFormat:@"切片 %ld 失败，重试", (long)seq]}];
                break;
            }
            @try { [self.handle writeData:sd]; } @catch (__unused NSException *e) {}

            self.bytes += sd.length;
            self.segments++;
            self.duration += [segs[i][@"dur"] doubleValue];
            lastSeq = seq;
            [self.seen addObject:@(seq)];

            [self emit:@{@"state": @"running",
                         @"text": [NSString stringWithFormat:@"录制中 %02d:%02d:%02d",
                                   (int)(self.duration/3600), (int)((long)self.duration%3600/60), (int)((long)self.duration%60)],
                         @"seconds": @(self.duration),
                         @"bytes": @(self.bytes),
                         @"segments": @(self.segments)}];
        }

        if (ended) break;
        [NSThread sleepForTimeInterval:MAX(1.0, MIN(3.0, target / 2))];
    }

    [self stop];
}

@end

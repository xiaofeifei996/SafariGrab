#import <Foundation/Foundation.h>

@interface SGDownloader : NSObject

+ (instancetype)shared;

/// 开始录制。完整回调用 NSString 形式的 JSON 状态。
- (void)startWithPlaylist:(NSString *)url
                   limit:(NSInteger)minutes
                referer:(NSString *)referer
                 update:(void (^)(NSDictionary *state))update;

- (void)stop;

@property (nonatomic, readonly) BOOL running;

@end

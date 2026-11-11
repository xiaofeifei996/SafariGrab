#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "SGDownloader.h"

// ===================== 注入到页面的 JS =====================

static NSString *const kSGScript = @R"JS(
(function () {
  if (window.__sgInstalled) return;
  window.__sgInstalled = true;

  var btn = null, panel = null, timer = null, currentURL = null;

  function findStreams() {
    var out = [];
    function add(u) { if (u && u.indexOf('.m3u8') > 0 && out.indexOf(u) < 0) out.push(u); }

    // 1) 已播放的 video / audio
    document.querySelectorAll('video,audio').forEach(function (v) {
      add(v.src); add(v.currentSrc);
    });

    // 2) 关键：页面实际发出的网络请求（hls.js 等都是 XHR 拉的 m3u8）
    try {
      performance.getEntriesByType('resource').forEach(function (e) { add(e.name); });
    } catch (e) {}

    // 3) iframe 的 url= 参数
    document.querySelectorAll('iframe').forEach(function (f) {
      var m = (f.src || '').match(/[?&]url=([^&]+)/);
      if (m) { try { add(decodeURIComponent(m[1])); } catch (e) {} }
    });

    // 4) 页面 HTML 里的明文地址
    try {
      var re = /https?:\/\/[^\s"'<>\\]+\.m3u8[^\s"'<>\\]*/g;
      var m2 = (document.documentElement.innerHTML || '').match(re) || [];
      m2.forEach(add);
    } catch (e) {}

    return out;
  }

  function post(obj) {
    try { window.webkit.messageHandlers.safarigrab.postMessage(obj); } catch (e) {}
  }

  function buildUI() {
    btn = document.createElement('div');
    btn.textContent = '录制';
    btn.style.cssText = [
      'position:fixed', 'right:14px', 'bottom:110px', 'z-index:2147483647',
      'width:52px', 'height:52px', 'border-radius:26px',
      'background:rgba(0,122,255,.92)', 'color:#fff',
      'font:600 14px -apple-system', 'display:flex',
      'align-items:center', 'justify-content:center',
      'box-shadow:0 4px 14px rgba(0,0,0,.35)',
      '-webkit-user-select:none', 'user-select:none'
    ].join(';');

    btn.addEventListener('click', function () {
      if (panel) { panel.remove(); panel = null; return; }
      var list = findStreams();
      if (!list.length) {
        showTip('本页没找到 m3u8 流。\n可以先点播放，再试一次。');
        return;
      }
      currentURL = list[0];
      openPanel(list);
    });

    document.documentElement.appendChild(btn);
  }

  function showTip(t) {
    var d = document.createElement('div');
    d.textContent = t;
    d.style.cssText = 'position:fixed;left:50%;top:40%;transform:translate(-50%,-50%);z-index:2147483647;' +
      'background:rgba(0,0,0,.85);color:#fff;padding:14px 18px;border-radius:12px;' +
      'font:14px/1.5 -apple-system;white-space:pre-line;max-width:80vw;text-align:center';
    document.documentElement.appendChild(d);
    setTimeout(function () { d.remove(); }, 2200);
  }

  function openPanel(list) {
    panel = document.createElement('div');
    var host = '';
    try { host = location.host; } catch (e) {}
    panel.style.cssText = 'position:fixed;right:12px;bottom:172px;z-index:2147483647;' +
      'width:260px;background:rgba(28,28,30,.97);border-radius:14px;padding:14px;' +
      'color:#fff;font:13px/1.45 -apple-system;box-shadow:0 8px 28px rgba(0,0,0,.5)';

    var h = document.createElement('div');
    h.textContent = '找到 ' + list.length + ' 个流';
    h.style.cssText = 'font-weight:600;margin-bottom:8px';

    var u = document.createElement('div');
    u.textContent = list[0].replace(/^https?:\/\//, '').slice(0, 46) + '…';
    u.style.cssText = 'color:#8e8e93;font-size:11px;margin-bottom:10px;word-break:break-all';

    var b1 = document.createElement('button');
    b1.textContent = '开始录制';
    b1.style.cssText = 'width:100%;padding:9px;border:0;border-radius:9px;background:#0a84ff;' +
      'color:#fff;font:600 14px -apple-system;margin-bottom:6px';
    b1.onclick = function () {
      post({ cmd: 'start', url: list[0], referer: location.href, limit: 0 });
      b1.textContent = '录制中…';
      b1.style.background = '#48484a';
      b1.disabled = true;
    };

    var b2 = document.createElement('button');
    b2.textContent = '停止';
    b2.style.cssText = 'width:100%;padding:9px;border:0;border-radius:9px;background:#3a3a3c;' +
      'color:#ff453a;font:600 14px -apple-system';
    b2.onclick = function () { post({ cmd: 'stop' }); };

    panel.appendChild(h); panel.appendChild(u); panel.appendChild(b1); panel.appendChild(b2);
    document.documentElement.appendChild(panel);
  }

  // 原生回传状态
  window.__sgStatus = function (text, done) {
    if (btn) btn.textContent = done ? '完成' : '录…';
    if (panel && !done) {
      var s = panel.querySelector('.sg-status');
      if (!s) {
        s = document.createElement('div');
        s.className = 'sg-status';
        s.style.cssText = 'color:#30d158;font-size:11px;margin-top:8px;word-break:break-all';
        panel.appendChild(s);
      }
      s.textContent = text;
    }
  };

  function boot() { buildUI(); }
  if (document.documentElement) boot();
  else document.addEventListener('DOMContentLoaded', boot);
})();
)JS";

// ===================== 原生桥 =====================

@interface SGBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@end

@implementation SGBridge

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = body[@"cmd"];

    WKWebView *wv = self.webView;

    if ([cmd isEqualToString:@"start"]) {
        NSString *url = body[@"url"];
        NSString *referer = body[@"referer"];
        NSInteger limit = [body[@"limit"] integerValue];
        if (!url.length) return;

        [[SGDownloader shared] startWithPlaylist:url limit:limit referer:referer update:^(NSDictionary *st) {
            NSString *text = st[@"text"] ?: @"";
            BOOL done = [st[@"state"] isEqualToString:@"done"] || [st[@"state"] isEqualToString:@"failed"];
            NSString *js = [NSString stringWithFormat:@"window.__sgStatus && window.__sgStatus(%@, %@);",
                            [self jsString:text], done ? @"true" : @"false"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [wv evaluateJavaScript:js completionHandler:nil];
            });

        }];
    } else if ([cmd isEqualToString:@"stop"]) {
        [[SGDownloader shared] stop];
    }
}

- (NSString *)jsString:(NSString *)s {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    // ["xxx"] → "xxx"
    if (json.length >= 2) return [json substringWithRange:NSMakeRange(1, json.length - 2)];
    return @"\"\"";
}

@end

// ===================== Hook =====================

static NSMutableDictionary<NSString *, SGBridge *> *gBridges;
static char kBridgeKey;

static void SGInstall(WKWebView *wv, WKWebViewConfiguration *configuration) {
    if (!wv || !configuration) return;
    WKUserContentController *ucc = configuration.userContentController;
    if (!ucc) {
        ucc = [WKUserContentController new];
        configuration.userContentController = ucc;
    }

    NSString *key = [NSString stringWithFormat:@"%p", ucc];
    if (gBridges[key]) return;

    SGBridge *bridge = [SGBridge new];
    bridge.webView = wv;
    [ucc addScriptMessageHandler:bridge name:@"safarigrab"];

    WKUserScript *us = [[WKUserScript alloc] initWithSource:kSGScript
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                           forMainFrameOnly:NO];
    [ucc addUserScript:us];

    gBridges[key] = bridge;
    objc_setAssociatedObject(wv, &kBridgeKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebView *wv = %orig;
    SGInstall(wv, configuration);
    return wv;
}

%end

%ctor {
    gBridges = [NSMutableDictionary dictionary];
}

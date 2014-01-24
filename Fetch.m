// Fast asynchronous even-driven CoreNetwork based HTTP fetch framework
// http://github.com/nanoant/Fetch.framework
//
// Copyright (c) 2010-2012 Adam Strzelecki
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "Fetch.h"

@interface Fetch ()

@property(strong) NSInputStream *stream;
@property(assign) BOOL gotHeaders;

@end

@implementation Fetch

@synthesize data;
@synthesize delegate;
@synthesize tag;
@synthesize retry;
@synthesize stream;
@synthesize gotHeaders;
@synthesize error;
@synthesize URL;

void FetchReadCallBack(CFReadStreamRef stream, CFStreamEventType eventType,
                       void *clientCallBackInfo);
void *CFClientRetain(void *object);
void CFClientRelease(void *object);
CFStringRef CFClientDescribeCopy(void *object);

static NSUInteger streamCount = 0;
NSInputStream *persistentStream = NULL;

+ (void)cleanupPersistentConnections
{
  [persistentStream close];
  persistentStream = NULL;
}

+ (Fetch *)fetchURL:(NSURL *)url
           delegate:(id<FetchDelegate>)delegate
                tag:(NSInteger)tag
              retry:(BOOL)retry
            cookies:(NSArray *)cookies
               hash:(NSString *)hash;
{
  return [[Fetch alloc] initWithURL:url
                           delegate:delegate
                                tag:tag
                              retry:retry
                            cookies:cookies
                               hash:hash
                               post:nil];
}

+ (Fetch *)postURL:(NSURL *)url
              data:(NSDictionary *)post
          delegate:(id<FetchDelegate>)delegate
               tag:(NSInteger)tag
             retry:(BOOL)retry
           cookies:(NSArray *)cookies
              hash:(NSString *)hash;
{
  return [[Fetch alloc] initWithURL:url
                           delegate:delegate
                                tag:tag
                              retry:retry
                            cookies:cookies
                               hash:hash
                               post:post];
}

- (id)initWithURL:(NSURL *)url
         delegate:(id<FetchDelegate>)aDelegate
              tag:(NSInteger)aTag
            retry:(BOOL)aRetry
          cookies:(NSArray *)cookies
             hash:(NSString *)hash
             post:(NSDictionary *)post
{
  // Copy properties
  delegate = aDelegate;
  tag = aTag;
  retry = aRetry;

  CFHTTPMessageRef request = CFHTTPMessageCreateRequest(
      kCFAllocatorDefault, post ? CFSTR("POST") : CFSTR("GET"),
      (__bridge CFURLRef)url, kCFHTTPVersion1_1);
  if (request) {
    if (post) {
      NSMutableArray *postElements =
          [NSMutableArray arrayWithCapacity:post.count];
      for (NSString *key in post) {
        [postElements
            addObject:[NSString
                          stringWithFormat:
                              @"%@=%@", key,
                              [[post objectForKey:key]
                                  stringByAddingPercentEscapesUsingEncoding:
                                      NSUTF8StringEncoding]]];
      }
      NSString *postString = [postElements componentsJoinedByString:@"&"];
      NSData *postData = [postString dataUsingEncoding:NSUTF8StringEncoding
                                  allowLossyConversion:YES];
      CFHTTPMessageSetHeaderFieldValue(
          request, CFSTR("Content-Type"),
          CFSTR("application/x-www-form-urlencoded"));
      CFHTTPMessageSetHeaderFieldValue(
          request, CFSTR("Content-Length"), (__bridge CFStringRef)
          [ NSString stringWithFormat : @"%zu", (size_t)[postData length] ]);
      CFHTTPMessageSetBody(request, (__bridge CFDataRef)postData);
    }
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Keep-Alive"), CFSTR("30"));
    // Prepare HTTP fields with cookie and hash
    if (cookies != nil) {
      NSDictionary *cookieFields =
          [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
      for (NSString *name in cookieFields.allKeys) {
        NSString *value = [cookieFields objectForKey:name];
        CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)name,
                                         (__bridge CFStringRef)value);
      }
    }
    if (hash != nil) {
      CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Referer"),
                                       (__bridge CFStringRef)hash);
    }

    stream =
        (__bridge_transfer NSInputStream *)CFReadStreamCreateForHTTPRequest(
            kCFAllocatorDefault, request);

    if (stream != NULL) {
      CFStreamClientContext context = { 0, (__bridge void *)self,
                                        CFClientRetain, CFClientRelease,
                                        CFClientDescribeCopy };
      CFReadStreamSetClient((CFReadStreamRef)stream,
                            kCFStreamEventHasBytesAvailable |
                                kCFStreamEventErrorOccurred |
                                kCFStreamEventEndEncountered,
                            FetchReadCallBack, &context);
      [stream scheduleInRunLoop:[NSRunLoop mainRunLoop]
                        forMode:NSRunLoopCommonModes];

      // In meantime our persistent stream may be closed, check that.
      // If we won't do it, our new stream will raise an error on startup
      // FIXME: This is a bug in CFNetwork!
      if (persistentStream != NULL) {
        switch (persistentStream.streamStatus) {
        case NSStreamStatusNotOpen:
        case NSStreamStatusClosed:
        case NSStreamStatusError:
          [persistentStream close];
          persistentStream = NULL;
          break;
        default:
          break;
        }
      }

      [stream setProperty:@YES
                   forKey:(id)kCFStreamPropertyHTTPAttemptPersistentConnection];
      [stream open];

      if (persistentStream != NULL) {
        [persistentStream close];
        persistentStream = NULL;
      }

      ++streamCount;
    } else {
      [delegate fetchDidFail:self];
    }
    CFRelease(request);
  } else {
    [delegate fetchDidFail:self];
  }

  return self;
}

- (void)cancel
{
  [stream close];
  // this will release the fetch object
  CFReadStreamSetClient((CFReadStreamRef)stream, kCFStreamEventNone, NULL,
                        NULL);
}

- (NSURL *)URL
{
  return (NSURL *)[stream propertyForKey:(id)kCFStreamPropertyHTTPFinalURL];
}

- (NSError *)error
{
  return stream.streamError;
}

- (void)detach
{
  if (streamCount > 1) {
    [stream close];
  } else {
    persistentStream = stream;
  }

  // this will release the fetch object
  CFReadStreamSetClient((CFReadStreamRef)stream, kCFStreamEventNone, NULL,
                        NULL);
}

- (void)dealloc
{
  --streamCount;
}

#pragma mark -
#pragma mark CFNetwork management

void *CFClientRetain(void *object)
{
  return (void *)CFBridgingRetain((__bridge id)object);
}

void CFClientRelease(void *object)
{
  CFBridgingRelease((__bridge CFTypeRef)(__bridge id)object);
}

CFStringRef CFClientDescribeCopy(void *object)
{
  return (CFStringRef)CFBridgingRetain([(__bridge id)object description]);
}

void FetchReadCallBack(CFReadStreamRef stream, CFStreamEventType eventType,
                       void *clientCallBackInfo)
{
  Fetch *fetch = (__bridge Fetch *)clientCallBackInfo;
  if (!fetch || fetch->stream != (__bridge NSInputStream *)stream) return;
  if (!fetch.gotHeaders) {
    fetch.gotHeaders = YES;
    CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(
        stream, kCFStreamPropertyHTTPResponseHeader);
    if (response == NULL) {
      [fetch.delegate fetchDidFail:fetch];
      [fetch cancel];
      return;
    }
    CFStringRef contentLengthString =
        CFHTTPMessageCopyHeaderFieldValue(response, CFSTR("Content-Length"));
    NSInteger contentLength = NSURLResponseUnknownLength;
    if (contentLengthString != NULL) {
      contentLength = CFStringGetIntValue(contentLengthString);
      CFRelease(contentLengthString);
    }
    NSInteger statusCode = CFHTTPMessageGetResponseStatusCode(response);
    CFRelease(response);
    [fetch.delegate fetch:fetch
        didReceiveStatusCode:statusCode
               contentLength:contentLength];
  }
  switch (eventType) {
  case kCFStreamEventHasBytesAvailable:
    if (fetch.data != nil) {
      UInt8 buf[2048];
      CFIndex bytesRead = CFReadStreamRead(stream, buf, sizeof(buf));
      // Returning -1 means an error
      if (bytesRead == -1) {
        [fetch.delegate fetchDidFail:fetch];
        [fetch cancel];
      } else if (bytesRead > 0) {
        [fetch.data appendBytes:buf length:bytesRead];
      }
    }
    break;
  case kCFStreamEventErrorOccurred:
    [fetch.delegate fetchDidFail:fetch];
    [fetch cancel];
    break;
  case kCFStreamEventEndEncountered:
    [fetch.delegate fetchDidFinish:fetch];
    [fetch detach];
    break;
  default:
    break;
  }
}

@end

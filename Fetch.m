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

@property(assign) CFReadStreamRef stream;
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

static int streamCount = 0;
CFReadStreamRef persistentStream = NULL;

// Define DLog in your pch header in order to get debugging info
#ifndef DLog
#define DLog(fmt, ...)
#endif

+ (void)cleanupPersistentConnections
{
  if (persistentStream != NULL) {
    DLog(@"%p fetch *cleanup [%ld]", persistentStream,
         CFGetRetainCount(persistentStream));
    CFReadStreamClose(persistentStream);
    CFRelease(persistentStream);
    persistentStream = NULL;
  }
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

- (id)initWithURL:(NSURL *)_url
         delegate:(id<FetchDelegate>)_delegate
              tag:(NSInteger)_tag
            retry:(BOOL)_retry
          cookies:(NSArray *)cookies
             hash:(NSString *)hash
             post:(NSDictionary *)post
{
  // Copy properties
  self.delegate = _delegate;
  tag = _tag;
  retry = _retry;

  CFHTTPMessageRef request = CFHTTPMessageCreateRequest(
      kCFAllocatorDefault, post ? CFSTR("POST") : CFSTR("GET"),
      (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
  if (request != NULL) {
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

    stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request);

    if (stream != NULL) {
      CFStreamClientContext context = { 0, (__bridge void *)self,
                                        CFClientRetain, CFClientRelease,
                                        CFClientDescribeCopy };
      CFReadStreamSetClient(stream, kCFStreamEventHasBytesAvailable |
                                        kCFStreamEventErrorOccurred |
                                        kCFStreamEventEndEncountered,
                            FetchReadCallBack, &context);
      CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                      kCFRunLoopCommonModes);

      // In meantime our persistent stream may be closed, check that.
      // If we won't do it, our new stream will raise an error on startup
      // FIXME: This is a bug in CFNetwork!
      if (persistentStream != NULL) {
        CFStreamStatus status = CFReadStreamGetStatus(persistentStream);
        if (status == kCFStreamStatusNotOpen ||
            status == kCFStreamStatusClosed || status == kCFStreamStatusError) {
          DLog(@"%p fetch:%ld *alerady closed [%ld]", persistentStream,
               (long)tag, CFGetRetainCount(persistentStream));
          CFReadStreamClose(persistentStream);
          CFRelease(persistentStream);
          persistentStream = NULL;
        }
      }

      CFReadStreamSetProperty(stream,
                              kCFStreamPropertyHTTPAttemptPersistentConnection,
                              kCFBooleanTrue);
      CFReadStreamOpen(stream);
      DLog(@"%p fetch:%ld -init [%ld] %@", stream, (long)tag,
           CFGetRetainCount(stream), _url);

      if (persistentStream != NULL) {
        DLog(@"%p fetch:%ld *close [%ld]", persistentStream, (long)tag,
             CFGetRetainCount(persistentStream));
        CFReadStreamClose(persistentStream);
        CFRelease(persistentStream);
        persistentStream = NULL;
      }

      streamCount++;
    } else {
      DLog(@"fetch:%ld CFReadStreamCreateForHTTPRequest failed!", (long)tag);
      [delegate fetchDidFail:self];
    }
  } else {
    DLog(@"fetch:%ld CFHTTPMessageCreateRequest failed!", (long)tag);
    [delegate fetchDidFail:self];
  }
  CFRelease(request);

  return self;
}

- (void)cancel
{
  DLog(@"%p fetch:%ld -cancel [%ld]", stream, (long)tag,
       CFGetRetainCount(stream));
  CFReadStreamClose(stream);
  // This will release the fetch object
  CFReadStreamSetClient(stream, kCFStreamEventNone, NULL, NULL);
}

- (NSURL *)URL
{
  return (NSURL *)CFBridgingRelease(
      CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPFinalURL));
}

- (NSError *)error
{
  return (NSError *)CFBridgingRelease(CFReadStreamCopyError(stream));
}

- (void)detach
{
  DLog(@"%p fetch:%ld -detach [%ld]", stream, (long)tag,
       CFGetRetainCount(stream));
  if (streamCount > 1) {
    DLog(@"%p fetch:%ld *release [%ld]", stream, (long)tag,
         CFGetRetainCount(stream));
    CFReadStreamClose(stream);
  } else {
    DLog(@"%p fetch:%ld *retain [%ld]", stream, (long)tag,
         CFGetRetainCount(stream));
    persistentStream = stream;
    CFRetain(persistentStream);
  }

  // This will release the fetch object
  CFReadStreamSetClient(stream, kCFStreamEventNone, NULL, NULL);
}

+ (void)releaseStream:(id)streamObject
{
  CFRelease((CFReadStreamRef)streamObject);
}

- (void)dealloc
{
  DLog(@"%p fetch:%ld -dealloc [%ld]", stream, (long)tag,
       CFGetRetainCount(stream));

  // FIXME: This fixes case where retain count for stream is 1 and after
  // returning
  // from this function CFNetwork routines crashes, because stream context is
  // freed.
  // CFRelease(stream);
  [Fetch performSelector:@selector(releaseStream:)
              withObject:(__bridge id)stream
              afterDelay:10];

  streamCount--;
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
  if (!fetch || fetch->stream != stream) return;
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
        [(NSMutableData *)fetch.data appendBytes:buf length:bytesRead];
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

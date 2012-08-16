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

#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>

@class Fetch;

@protocol FetchDelegate

- (void)fetchDidFail:(Fetch *)fetch;
- (void)fetchDidFinish:(Fetch *)fetch;
- (void)fetch:(Fetch *)fetch didReceiveStatusCode:(NSInteger)statusCode contentLength:(NSInteger)contentLength;

@end

@interface Fetch : NSObject {
	NSMutableData *data;
	NSInteger tag;
	BOOL retry;
	id<FetchDelegate> delegate;
	CFReadStreamRef stream;
	BOOL gotHeaders;
}

@property (nonatomic, retain) id<FetchDelegate> delegate;
@property (nonatomic, retain) NSMutableData *data;
@property (assign) NSInteger tag;
@property (assign) BOOL retry;
@property (assign) CFReadStreamRef stream;
@property (assign) BOOL gotHeaders;
@property (readonly) NSError *error;
@property (readonly) NSURL *URL;

- (id)initWithURL:(NSURL *)url
		 delegate:(id<FetchDelegate>)_delegate
			  tag:(NSInteger)_tag
			retry:(BOOL)_retry
		  cookies:(NSArray *)cookies
			 hash:(NSString *)hash
			 post:(NSDictionary *)post;
+ (Fetch *)fetchURL:(NSURL *)url
		   delegate:(id<FetchDelegate>)delegate
				tag:(NSInteger)tag
			  retry:(BOOL)retry
			cookies:(NSArray *)cookies
			   hash:(NSString *)hash;
+ (Fetch *)postURL:(NSURL *)url
			  data:(NSDictionary *)post
		  delegate:(id<FetchDelegate>)delegate
			   tag:(NSInteger)tag
			 retry:(BOOL)retry
		   cookies:(NSArray *)cookies
			  hash:(NSString *)hash;
- (void)cancel;
+ (void)cleanupPersistentConnections;

@end

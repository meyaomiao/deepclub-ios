/*
 * Test-only event synthesis API usage adapted from WebDriverAgent.
 * Copyright (c) 2015-present, Facebook, Inc. All rights reserved.
 * BSD License — For WebDriverAgent software.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. Neither the name Facebook nor the names of its contributors may be used to
 *    endorse or promote products derived from this software without specific
 *    prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#import "P4RedactedInput.h"
#import <TargetConditionals.h>
#import <XCTest/XCTest.h>

// Selector signatures follow Appium WebDriverAgent's publicly available
// XCUIElement+FBTyping / FBXCTestDaemonsProxy sources. No binary inspection.
// https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Categories/XCUIElement%2BFBTyping.m
@interface NSObject (P4EventSignatures)
- (instancetype)initWithName:(NSString *)name;
- (instancetype)initForTextInput;
- (void)typeText:(NSString *)text atOffset:(double)offset typingSpeed:(NSUInteger)speed shouldRedact:(BOOL)redact;
- (void)addPointerEventPath:(id)path;
- (id)eventSynthesizer;
- (void)synthesizeEvent:(id)record completion:(void (^)(BOOL, NSError *))completion;
@end

BOOL P4TypeRedactedText(NSString *value) {
#if DEBUG && TARGET_OS_SIMULATOR
    Class recordType = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathType = NSClassFromString(@"XCPointerEventPath");
    if (!recordType || !pathType || ![XCUIDevice.sharedDevice respondsToSelector:@selector(eventSynthesizer)]) return NO;
    id record = [[recordType alloc] initWithName:@"P4 redacted input"];
    id path = [[pathType alloc] initForTextInput];
    if (![path respondsToSelector:@selector(typeText:atOffset:typingSpeed:shouldRedact:)]) return NO;
    [path typeText:value atOffset:0.0 typingSpeed:60 shouldRedact:YES];
    [record addPointerEventPath:path];
    __block BOOL complete = NO;
    __block BOOL success = NO;
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:^(BOOL result, NSError *error) {
        success = result && error == nil;
        complete = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!complete && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return complete && success;
#else
    return NO;
#endif
}

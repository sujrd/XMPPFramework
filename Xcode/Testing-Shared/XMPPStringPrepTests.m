//
//  XMPPStringPrepTests.m
//  XMPPFrameworkTests
//
//  Created by Hanny Prastya Hariyadi on 2026/10/31.
//

#import <XCTest/XCTest.h>
@import XMPPFramework;

/**
 * Expected values are what libidn 1.35 returned, except where a test says otherwise.
**/
@interface XMPPStringPrepTests : XCTestCase

@end

@implementation XMPPStringPrepTests

- (void)assertPrepOf:(NSString *)input node:(NSString *)node domain:(NSString *)domain resource:(NSString *)resource password:(NSString *)password {
    XCTAssertEqualObjects([XMPPStringPrep prepNode:input], node, @"nodeprep of %@", input);
    XCTAssertEqualObjects([XMPPStringPrep prepDomain:input], domain, @"nameprep of %@", input);
    XCTAssertEqualObjects([XMPPStringPrep prepResource:input], resource, @"resourceprep of %@", input);
    XCTAssertEqualObjects([XMPPStringPrep prepPassword:input], password, @"SASLprep of %@", input);
}

- (void)assertPrepOf:(NSString *)input all:(NSString *)output {
    [self assertPrepOf:input node:output domain:output resource:output password:output];
}

- (NSString *)string:(NSString *)unit repeated:(NSUInteger)count {
    return [@"" stringByPaddingToLength:unit.length * count withString:unit startingAtIndex:0];
}

- (void)testASCII {
    [self assertPrepOf:@"romeo" all:@"romeo"];
    [self assertPrepOf:@"Example.COM" node:@"example.com" domain:@"example.com" resource:@"Example.COM" password:@"Example.COM"];
    [self assertPrepOf:@"" all:@""];
}

- (void)testNodeDelimiters {
    for (NSString *delimiter in @[@"\"", @"&", @"'", @"/", @":", @"<", @">", @"@"]) {
        NSString *input = [NSString stringWithFormat:@"a%@b", delimiter];
        [self assertPrepOf:input node:nil domain:input resource:input password:input];
    }
    [self assertPrepOf:@"℀" node:nil domain:@"a/c" resource:@"a/c" password:@"a/c"];
}

- (void)testSpaces {
    [self assertPrepOf:@"a b" node:nil domain:@"a b" resource:@"a b" password:@"a b"];
    [self assertPrepOf:@"a b" node:nil domain:@"a b" resource:@"a b" password:@"a b"];
    [self assertPrepOf:@"a　b" node:nil domain:@"a b" resource:@"a b" password:@"a b"];
    [self assertPrepOf:@"a​b" node:@"ab" domain:@"ab" resource:@"ab" password:@"a b"];
}

- (void)testControlCharacters {
    [self assertPrepOf:@"a\x07" @"b" node:nil domain:@"a\x07" @"b" resource:nil password:nil];
    [self assertPrepOf:@"a\x7F" @"b" node:nil domain:@"a\x7F" @"b" resource:nil password:nil];
    [self assertPrepOf:[NSString stringWithFormat:@"a%Cb", (unichar)0x85] all:nil];
}

- (void)testMappedToNothing {
    for (NSString *input in @[@"a­b", @"a﻿b", @"a᠋b"]) {
        [self assertPrepOf:input all:@"ab"];
    }
}

- (void)testCaseFolding {
    [self assertPrepOf:@"ß" node:@"ss" domain:@"ss" resource:@"ß" password:@"ß"];
    [self assertPrepOf:@"ΣΑΣ" node:@"σασ" domain:@"σασ" resource:@"ΣΑΣ" password:@"ΣΑΣ"];
    [self assertPrepOf:@"İ" node:@"i̇" domain:@"i̇" resource:@"İ" password:@"İ"];
}

- (void)testCompatibilityCharacters {
    [self assertPrepOf:@"ﬁ" all:@"fi"];
    [self assertPrepOf:@"Ｊｏｈｎ" node:@"john" domain:@"john" resource:@"John" password:@"John"];
    [self assertPrepOf:@"Ⅸ" node:@"ix" domain:@"ix" resource:@"IX" password:@"IX"];
    [self assertPrepOf:@"㎒" node:@"mhz" domain:@"mhz" resource:@"MHz" password:@"MHz"];
    [self assertPrepOf:@"½" all:@"1⁄2"];
}

- (void)testComposition {
    [self assertPrepOf:@"é" all:@"é"];
    [self assertPrepOf:@"ệ" all:@"ệ"];
    [self assertPrepOf:@"ୌ" all:@"ୌ"];
    [self assertPrepOf:@"ㄱㅏ" all:@"가"];
    [self assertPrepOf:@"각" all:@"각"];
    [self assertPrepOf:@"ཱི" all:@"ཱི"];
    [self assertPrepOf:@"ཱྀ" all:@"ཱྀ"];
    [self assertPrepOf:@"陋" all:@"陋"];
}

- (void)testBidi {
    [self assertPrepOf:@"שלום" all:@"שלום"];
    [self assertPrepOf:@"العربية" all:@"العربية"];
    [self assertPrepOf:@"ש1ש" all:@"ש1ש"];
    for (NSString *input in @[@"שa", @"1ש", @"ש1"]) {
        [self assertPrepOf:input all:nil];
    }
}

- (void)testProhibitedCharacters {
    for (NSString *input in @[@"a", @"a￿", @"a\U0010FFFF", @"a⿰", @"a‎", @"a‮", @"a\U000E0001", @"a�"]) {
        [self assertPrepOf:input all:nil];
    }
    // NFKC replaces the prohibited U+0340 before the check.
    [self assertPrepOf:@"à" all:@"à"];
}

- (void)testUnassignedInUnicode32 {
    [self assertPrepOf:@"ȡ" all:@"ȡ"];
    [self assertPrepOf:@"ẞ" all:@"ẞ"];
    [self assertPrepOf:@"\U0001F100" all:@"\U0001F100"];
    [self assertPrepOf:@"\U0001F600" all:@"\U0001F600"];
}

- (void)testUnicode32Decompositions {
    [self assertPrepOf:@"\U0002F868" all:@"\U0002136A"];
    [self assertPrepOf:@"\U0002F874" all:@"弳"];
}

- (void)testNoCompositionAcrossCombiningMark {
    // libidn returned U+0B4C U+0B3C, from before Unicode Corrigendum #5.
    [self assertPrepOf:@"େ଼ୗ" all:@"େ଼ୗ"];
}

- (void)testLengthLimit {
    [self assertPrepOf:[self string:@"a" repeated:1023] all:[self string:@"a" repeated:1023]];
    [self assertPrepOf:[self string:@"あ" repeated:341] all:[self string:@"あ" repeated:341]];
    // libidn's wrapper read past its buffer for these.
    [self assertPrepOf:[self string:@"a" repeated:1024] all:nil];
    [self assertPrepOf:[self string:@"あ" repeated:342] all:nil];

    NSString *phrase = @"صلى الله عليه وسلم";
    NSString *expanded = [self string:phrase repeated:31];
    [self assertPrepOf:[self string:@"ﷺ" repeated:31] node:nil domain:expanded resource:expanded password:expanded];
    [self assertPrepOf:[self string:@"ﷺ" repeated:32] all:nil];
}

- (void)testNULAndLoneSurrogates {
    // libidn's wrapper cut the string short at U+0000 and crashed on lone surrogates.
    unichar nul[] = {'a', 0, 'b'};
    unichar highSurrogate[] = {'a', 0xD800, 'b'};
    unichar lowSurrogate[] = {0xDC00, 'a'};
    [self assertPrepOf:[NSString stringWithCharacters:nul length:3] all:nil];
    [self assertPrepOf:[NSString stringWithCharacters:highSurrogate length:3] all:nil];
    [self assertPrepOf:[NSString stringWithCharacters:lowSurrogate length:2] all:nil];
}

@end

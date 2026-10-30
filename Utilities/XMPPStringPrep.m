#import "XMPPStringPrep.h"
#import "XMPPStringPrepTables.h"

/**
 * Stringprep (RFC 3454) with the profiles XMPP needs. It behaves like libidn with flags 0,
 * which XMPPFramework used before: it normalizes with NFKC, checks the bidi rules
 * and allows code points that are unassigned in Unicode 3.2.
**/

typedef struct {
    BOOL mapsNonASCIISpaceToSpace;
    BOOL foldsCase;
    BOOL prohibitsASCIISpace;
    BOOL prohibitsASCIIControl;
    BOOL prohibitsNodeDelimiters;
} XMPPStringPrepProfile;

// Nodeprep, RFC 3920 appendix A
static const XMPPStringPrepProfile XMPPStringPrepNodeprep = {
    .foldsCase = YES,
    .prohibitsASCIISpace = YES,
    .prohibitsASCIIControl = YES,
    .prohibitsNodeDelimiters = YES,
};

// Nameprep, RFC 3491
static const XMPPStringPrepProfile XMPPStringPrepNameprep = {
    .foldsCase = YES,
};

// Resourceprep, RFC 3920 appendix B
static const XMPPStringPrepProfile XMPPStringPrepResourceprep = {
    .prohibitsASCIIControl = YES,
};

// SASLprep, RFC 4013
static const XMPPStringPrepProfile XMPPStringPrepSASLprep = {
    .mapsNonASCIISpaceToSpace = YES,
    .prohibitsASCIIControl = YES,
};

// Each part of a JID is at most 1023 bytes in UTF-8, both before and after the prep.
static const NSUInteger XMPPStringPrepMaxLength = 1023;

#define XMPPStringPrepContains(table, codePoint) \
    XMPPStringPrepRangesContain(table, sizeof(table) / sizeof(table[0]), codePoint)

static BOOL XMPPStringPrepRangesContain(const XMPPStringPrepRange *ranges, size_t count, uint32_t codePoint)
{
    size_t low = 0;
    size_t high = count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (codePoint < ranges[middle].first) {
            high = middle;
        } else if (codePoint > ranges[middle].last) {
            low = middle + 1;
        } else {
            return YES;
        }
    }
    return NO;
}

static const XMPPStringPrepMapping *XMPPStringPrepCaseFolding(uint32_t codePoint)
{
    size_t low = 0;
    size_t high = sizeof(XMPPStringPrepTableB2) / sizeof(XMPPStringPrepTableB2[0]);
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (codePoint < XMPPStringPrepTableB2[middle].codePoint) {
            high = middle;
        } else if (codePoint > XMPPStringPrepTableB2[middle].codePoint) {
            low = middle + 1;
        } else {
            return &XMPPStringPrepTableB2[middle];
        }
    }
    return NULL;
}

static void XMPPStringPrepAppend(NSMutableData *codePoints, uint32_t codePoint)
{
    [codePoints appendBytes:&codePoint length:sizeof(codePoint)];
}

/**
 * Returns nil for lone surrogates, and for U+0000, where the libidn wrapper cut the string short.
**/
static NSMutableData *XMPPStringPrepCodePoints(NSString *string)
{
    CFStringRef cfString = (__bridge CFStringRef)string;
    CFIndex length = CFStringGetLength(cfString);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(cfString, &buffer, CFRangeMake(0, length));

    NSMutableData *codePoints = [NSMutableData dataWithCapacity:(NSUInteger)length * sizeof(uint32_t)];
    for (CFIndex i = 0; i < length; i++) {
        UniChar unit = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        uint32_t codePoint = unit;
        if (CFStringIsSurrogateHighCharacter(unit) && i + 1 < length) {
            UniChar low = CFStringGetCharacterFromInlineBuffer(&buffer, i + 1);
            if (CFStringIsSurrogateLowCharacter(low)) {
                codePoint = CFStringGetLongCharacterForSurrogatePair(unit, low);
                i++;
            }
        }
        if (codePoint == 0 || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
            return nil;
        }
        XMPPStringPrepAppend(codePoints, codePoint);
    }
    return codePoints;
}

static NSString *XMPPStringPrepString(const uint32_t *codePoints, NSUInteger count)
{
    NSMutableData *units = [NSMutableData dataWithCapacity:count * sizeof(UniChar)];
    for (NSUInteger i = 0; i < count; i++) {
        UniChar surrogates[2];
        BOOL isPair = CFStringGetSurrogatePairForLongCharacter(codePoints[i], surrogates);
        [units appendBytes:surrogates length:(isPair ? 2 : 1) * sizeof(UniChar)];
    }
    return [[NSString alloc] initWithCharacters:units.bytes length:units.length / sizeof(UniChar)];
}

static NSUInteger XMPPStringPrepUTF8Length(NSData *codePoints)
{
    const uint32_t *values = codePoints.bytes;
    NSUInteger length = 0;
    for (NSUInteger i = 0; i < codePoints.length / sizeof(uint32_t); i++) {
        length += values[i] < 0x80 ? 1 : values[i] < 0x800 ? 2 : values[i] < 0x10000 ? 3 : 4;
    }
    return length;
}

static NSData *XMPPStringPrepMap(NSData *input, const XMPPStringPrepProfile *profile)
{
    const uint32_t *values = input.bytes;
    NSMutableData *output = [NSMutableData dataWithCapacity:input.length];
    for (NSUInteger i = 0; i < input.length / sizeof(uint32_t); i++) {
        const XMPPStringPrepMapping *folding = NULL;
        if (profile->mapsNonASCIISpaceToSpace && XMPPStringPrepContains(XMPPStringPrepTableC12, values[i])) {
            XMPPStringPrepAppend(output, ' ');
        } else if (XMPPStringPrepContains(XMPPStringPrepTableB1, values[i])) {
            continue;
        } else if (profile->foldsCase && (folding = XMPPStringPrepCaseFolding(values[i]))) {
            [output appendBytes:folding->mapping length:folding->length * sizeof(uint32_t)];
        } else {
            XMPPStringPrepAppend(output, values[i]);
        }
    }
    return output;
}

/**
 * Unicode 4.0 corrected the decompositions of these CJK compatibility ideographs (Corrigendum #4).
 * Stringprep keeps the ones from Unicode 3.2.
**/
static uint32_t XMPPStringPrepUnicode32Decomposition(uint32_t codePoint)
{
    switch (codePoint) {
        case 0x2F868: return 0x2136A;
        case 0x2F874: return 0x5F33;
        case 0x2F91F: return 0x43AB;
        case 0x2F95F: return 0x7AAE;
        case 0x2F9BF: return 0x4D57;
        default: return codePoint;
    }
}

/**
 * NFKC through ICU's transform. NSString's precomposedStringWithCompatibilityMapping doesn't reorder
 * or compose what it decomposes, such as Hangul compatibility jamo and some Tibetan vowel signs.
 *
 * Stringprep normalizes with Unicode 3.2. ICU uses a later version, which also decomposes
 * and reorders characters added since, so code points unassigned in 3.2 stay out of it.
 * ICU also applies Unicode Corrigendum #5, so unlike libidn it doesn't compose two characters
 * across a combining mark between them, such as U+0B47 U+0B3C U+0B57.
**/
static NSData *XMPPStringPrepNormalize(NSData *input)
{
    const uint32_t *values = input.bytes;
    NSUInteger count = input.length / sizeof(uint32_t);
    BOOL isASCII = YES;
    for (NSUInteger i = 0; i < count && isASCII; i++) {
        isASCII = values[i] < 0x80;
    }
    if (isASCII) {
        return input;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:input.length];
    NSMutableData *run = [NSMutableData dataWithCapacity:input.length];
    for (NSUInteger i = 0; i <= count; i++) {
        if (i < count && !XMPPStringPrepContains(XMPPStringPrepTableA1, values[i])) {
            XMPPStringPrepAppend(run, XMPPStringPrepUnicode32Decomposition(values[i]));
            continue;
        }
        if (run.length > 0) {
            NSMutableString *normalized = [XMPPStringPrepString(run.bytes, run.length / sizeof(uint32_t)) mutableCopy];
            if (!CFStringTransform((__bridge CFMutableStringRef)normalized, NULL, CFSTR("Any-NFKC"), false)) {
                return nil;
            }
            NSData *normalizedCodePoints = XMPPStringPrepCodePoints(normalized);
            if (!normalizedCodePoints) {
                return nil;
            }
            [output appendData:normalizedCodePoints];
            run.length = 0;
        }
        if (i < count) {
            XMPPStringPrepAppend(output, values[i]);
        }
    }
    return output;
}

static BOOL XMPPStringPrepIsProhibited(uint32_t codePoint, const XMPPStringPrepProfile *profile)
{
    if (profile->prohibitsASCIISpace && XMPPStringPrepContains(XMPPStringPrepTableC11, codePoint)) {
        return YES;
    }
    if (profile->prohibitsASCIIControl && XMPPStringPrepContains(XMPPStringPrepTableC21, codePoint)) {
        return YES;
    }
    if (profile->prohibitsNodeDelimiters) {
        switch (codePoint) {
            case '"': case '&': case '\'': case '/': case ':': case '<': case '>': case '@':
                return YES;
        }
    }
    return XMPPStringPrepContains(XMPPStringPrepTableC12, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC22, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC3, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC4, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC5, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC6, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC7, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC8, codePoint)
        || XMPPStringPrepContains(XMPPStringPrepTableC9, codePoint);
}

/**
 * RFC 3454 section 6: a string with right-to-left characters has no left-to-right ones,
 * and starts and ends with a right-to-left character.
**/
static BOOL XMPPStringPrepSatisfiesBidi(NSData *codePoints)
{
    const uint32_t *values = codePoints.bytes;
    NSUInteger count = codePoints.length / sizeof(uint32_t);
    BOOL containsRandAL = NO;
    BOOL containsL = NO;
    for (NSUInteger i = 0; i < count; i++) {
        containsRandAL = containsRandAL || XMPPStringPrepContains(XMPPStringPrepTableD1, values[i]);
        containsL = containsL || XMPPStringPrepContains(XMPPStringPrepTableD2, values[i]);
    }
    if (!containsRandAL) {
        return YES;
    }
    return !containsL
        && XMPPStringPrepContains(XMPPStringPrepTableD1, values[0])
        && XMPPStringPrepContains(XMPPStringPrepTableD1, values[count - 1]);
}

static NSString *XMPPStringPrepPrepare(NSString *string, const XMPPStringPrepProfile *profile)
{
    // Each UTF-16 code unit takes at least one byte in UTF-8.
    if (string.length > XMPPStringPrepMaxLength) {
        return nil;
    }
    NSData *input = XMPPStringPrepCodePoints(string);
    if (!input || XMPPStringPrepUTF8Length(input) > XMPPStringPrepMaxLength) {
        return nil;
    }

    NSData *output = XMPPStringPrepNormalize(XMPPStringPrepMap(input, profile));
    if (!output || XMPPStringPrepUTF8Length(output) > XMPPStringPrepMaxLength) {
        return nil;
    }
    const uint32_t *values = output.bytes;
    NSUInteger count = output.length / sizeof(uint32_t);
    for (NSUInteger i = 0; i < count; i++) {
        if (XMPPStringPrepIsProhibited(values[i], profile)) {
            return nil;
        }
    }
    if (!XMPPStringPrepSatisfiesBidi(output)) {
        return nil;
    }
    return XMPPStringPrepString(values, count);
}


@implementation XMPPStringPrep

+ (NSString *)prepNode:(NSString *)node
{
    if (!node) { return nil; }
    return XMPPStringPrepPrepare(node, &XMPPStringPrepNodeprep);
}

+ (NSString *)prepDomain:(NSString *)domain
{
    if (!domain) { return nil; }
    return XMPPStringPrepPrepare(domain, &XMPPStringPrepNameprep);
}

+ (NSString *)prepResource:(NSString *)resource
{
    if (!resource) { return nil; }
    return XMPPStringPrepPrepare(resource, &XMPPStringPrepResourceprep);
}

+ (NSString *)prepPassword:(NSString *)password
{
    if (!password) { return nil; }
    return XMPPStringPrepPrepare(password, &XMPPStringPrepSASLprep);
}

@end

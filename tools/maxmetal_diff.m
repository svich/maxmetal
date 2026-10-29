// Differential check of the maxmetal translation against the Ryujinx path's: for each variant both MSL functions run on the
// GPU with the same inputs, bound by their reflections as the renderer binds them (same kind and NVN slot, same data),
// and their outputs are compared: a fragment shader's colour / depth outputs over a 32x32 target with smoothly varying
// inputs, a vertex shader's position and varyings for 64 vertices, every stage's stores to storage buffers.
// Inputs are random (seeded by variant): constant buffers floats in [0, 1), textures [0, 1), vertex attributes the
// Ryujinx path types as integers small integers. Reported per variant: exact, close (float within 1e-4 relative),
// different, capped (a side hit the test-only loop cap: with_loop_cap), or skipped (what the harness does not bind).
// MAXMETAL_DIFF_COMPILE_ONLY=1: compile both sides (loop cap injected) and run nothing.
// Usage: maxmetal-diff [--time N] <ryujinx dir> <maxmetal dir> <variant>...   (variant: the name before _b.metal)
// --time N: also draw / dispatch each function N times and report the GPU time of both (ms).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <unistd.h>

#define SBUF_BYTES (1u << 20)   // storage slots: 1 MiB (indices the inputs make stay inside)
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static int g_time;
static const char *g_variant;   // the variant being compared (wait_cb's line)

// A shader can run on the GPU without end and without a hang error coming back (a cs on 2026-10-28: waitUntilCompleted
// blocked 15 min). Each run gets GPU_TIMEOUT seconds (default 20), then its timeout is the variant's line and the process
// exits (3), so a batch driver can go on with the rest. who: "ryujinx" (a skip), "maxmetal" (a fail) or "setup".
static void wait_cb(id<MTLCommandBuffer> cb, const char *who) {
    static double limit;
    if (!limit) limit = getenv("GPU_TIMEOUT") ? atof(getenv("GPU_TIMEOUT")) : 20;
    for (double t = 0; cb.status < MTLCommandBufferStatusCompleted; t += 0.001) {
        if (t > limit) {
            printf("%s %s %s run: gpu timeout (%.0f s)\n", strcmp(who, "maxmetal") ? "skip" : "fail", g_variant, who, limit);
            fflush(stdout); _exit(3);
        }
        usleep(1000);
    }
}

// ---- deterministic random
static uint64_t g_rng;
static uint32_t rnd(void) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return (uint32_t)(g_rng >> 16); }
static float rndf(void) { return (rnd() & 0xFFFFFF) / 16777216.0f; }
static void seed(const char *s) { g_rng = 1469598103934665603ull; for (; *s; s++) g_rng = (g_rng ^ (uint8_t)*s) * 1099511628211ull; if (!g_rng) g_rng = 1; }

typedef struct { NSString *msl; NSDictionary *refl; id<MTLFunction> fn; NSString *err; const char *who; } Side;

// ---- test-only loop cap. Random inputs can make a shader loop without end (loop counts and list walks read from the
// data): the GPU runs until the watchdog resets it, a reset every app sees (screen glitches, a lost external display,
// on 2026-10-29 a frozen Mac). Each loop of main0 breaks once main0's loops have run MAXMETAL_DIFF_LOOP_CAP iterations in all
// (default 4096) and sets a flag the run reads back: a variant that hits it on either side is "capped", its comparison
// says nothing about the translation.
#define CAP_INDEX 15     // the flag's buffer index in every stage (vertex attributes from 16, the vertex dump at 29)
static int g_capped;     // the sides that hit it: 1 Ryujinx, 2 maxmetal
static int g_capsites;   // loops the last with_loop_cap capped

static size_t skip_ws(const char *s, size_t i, size_t n) { while (i < n && isspace((unsigned char)s[i])) i++; return i; }
static size_t match_close(const char *s, size_t i, size_t n, char open, char close) {  // s[i] == open: its close, or n
    int depth = 0;
    for (; i < n; i++) {
        if (s[i] == '/' && i + 1 < n && s[i + 1] == '/') { while (i < n && s[i] != '\n') i++; continue; }
        if (s[i] == open) depth++;
        else if (s[i] == close && --depth == 0) return i;
    }
    return n;
}

static NSString *with_loop_cap(NSString *src) {
    const char *s = src.UTF8String, *m = strstr(s, " main0(");
    size_t n = strlen(s);
    g_capsites = 0;
    if (!m) return src;
    size_t args = (size_t)(m - s) + 7, pclose = match_close(s, args - 1, n, '(', ')'), body = skip_ws(s, pclose + 1, n);
    if (body >= n || s[body] != '{') return src;
    size_t end = match_close(s, body, n, '{', '}');
    static unsigned cap;
    if (!cap) cap = getenv("MAXMETAL_DIFF_LOOP_CAP") ? (unsigned)atoi(getenv("MAXMETAL_DIFF_LOOP_CAP")) : 4096;
    NSString *brk = [NSString stringWithFormat:@" if (++maxmetal_cap > %uu) { atomic_store_explicit(maxmetal_capped, 1u, memory_order_relaxed); break; }", cap];
    NSMutableString *o = [NSMutableString string];
    __block size_t from = 0;
    void (^to)(size_t) = ^(size_t k) { [o appendString:[[NSString alloc] initWithBytes:s + from length:k - from encoding:NSUTF8StringEncoding]]; from = k; };
    to(args);
    [o appendFormat:@"device atomic_uint *maxmetal_capped [[buffer(%d)]]%s", CAP_INDEX, s[skip_ws(s, args, n)] == ')' ? "" : ", "];
    to(body + 1);
    [o appendString:@" uint maxmetal_cap = 0u;"];
    for (size_t i = body + 1; i < end; i++) {
        if (s[i] == '/' && s[i + 1] == '/') { while (i < end && s[i] != '\n') i++; continue; }
        if (isalnum((unsigned char)s[i - 1]) || s[i - 1] == '_' || s[i - 1] == '.') continue;
        size_t open;
        if (!strncmp(s + i, "for", 3) || !strncmp(s + i, "while", 5)) {   // for (...) { / while (...) {, not a do-while's tail
            size_t k = skip_ws(s, i + (s[i] == 'f' ? 3 : 5), end);
            if (k >= end || s[k] != '(') continue;
            open = skip_ws(s, match_close(s, k, end, '(', ')') + 1, end);
        } else if (!strncmp(s + i, "do", 2)) {   // do { ... } while (c); but do { ... } while (false) (a block)
            open = skip_ws(s, i + 2, end);
            if (open >= end || s[open] != '{') continue;
            size_t w = skip_ws(s, match_close(s, open, end, '{', '}') + 1, end);
            if (!strncmp(s + w, "while (false)", 13)) continue;
        } else continue;
        if (open >= end || s[open] != '{') continue;
        to(open + 1);
        [o appendString:brk];
        g_capsites++;
        i = open;
    }
    to(n);
    return o;
}

static id<MTLBuffer> cap_buffer(void) {
    id<MTLBuffer> b = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    memset(b.contents, 0, 4);
    return b;
}
static void cap_check(const Side *sd, id<MTLBuffer> b) { if (*(const uint32_t *)b.contents) g_capped |= strcmp(sd->who, "maxmetal") ? 1 : 2; }

static id<MTLFunction> compile(NSString *src, NSString **err) {
    src = with_loop_cap(src);
    MTLCompileOptions *o = [MTLCompileOptions new];
    // as the renderer compiles them
    if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeSafe;
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        o.fastMathEnabled = NO;
#pragma clang diagnostic pop
    }
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e];
    if (!lib) { *err = e.localizedDescription; return nil; }
    return [lib newFunctionWithName:@"main0"];
}

// ---- inputs, keyed by binding kind and slot so both sides get the same objects / contents
static NSMutableDictionary *g_res;       // key -> id (read-only resources shared by both sides)
static NSMutableDictionary *g_init;      // key -> NSData (initial contents of writable buffers: each side gets a copy)
static NSString *g_stage;

static id<MTLBuffer> buf_with(NSData *d) { return [dev newBufferWithBytes:d.bytes length:d.length options:MTLResourceStorageModeShared]; }

static NSData *random_floats(size_t bytes) {
    NSMutableData *d = [NSMutableData dataWithLength:bytes];
    float *f = d.mutableBytes;
    for (size_t i = 0; i < bytes / 4; i++) f[i] = rndf();
    return d;
}

static NSData *driver_bank(int bank) {
    NSMutableData *d = [NSMutableData dataWithLength:65536];
    uint8_t *p = d.mutableBytes;
    if (bank == 0) {
        int base = [g_stage isEqual:@"vs"] ? 0x110 : [g_stage isEqual:@"ps"] ? 0x510 : 0x310;
        for (int k = 0; k < 16; k++) {   // storage slot k at a made-up address, 64 KiB
            uint64_t a = 0x1000000000ull + (uint64_t)k * 0x1000000; uint32_t n = SBUF_BYTES;
            memcpy(p + base + 16 * k, &a, 8); memcpy(p + base + 16 * k + 8, &n, 4);
        }
        if ([g_stage isEqual:@"cs"]) {
            uint32_t grid[3] = {2, 1, 1}; memcpy(p + 0x200, grid, 12);
            for (int k = 0; k < 16; k++) { uint64_t a = 0x2000000000ull + (uint64_t)k * 0x100000; uint32_t n = 65536; memcpy(p + 0x210 + 16 * k, &a, 8); memcpy(p + 0x210 + 16 * k + 8, &n, 4); }
        } else if ([g_stage isEqual:@"vs"]) {
            float ps = 2047.9375f; memcpy(p + 0x610, &ps, 4);
        }
    }
    return d;
}

static id<MTLTexture> make_texture(NSString *type) {
    BOOL depth = [type hasPrefix:@"depth"];
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.pixelFormat = depth ? MTLPixelFormatDepth32Float : MTLPixelFormatRGBA16Float;
    td.width = td.height = 16; td.depth = 1; td.arrayLength = 1;
    if ([type hasPrefix:@"texture1d_array"]) { td.textureType = MTLTextureType1DArray; td.height = 1; td.arrayLength = 4; }
    else if ([type hasPrefix:@"texture1d"]) { td.textureType = MTLTextureType1D; td.height = 1; }
    else if ([type containsString:@"2d_array"]) { td.textureType = MTLTextureType2DArray; td.arrayLength = 4; }
    else if ([type containsString:@"cube_array"]) { td.textureType = MTLTextureTypeCubeArray; td.arrayLength = 2; }
    else if ([type containsString:@"cube"]) td.textureType = MTLTextureTypeCube;
    else if ([type hasPrefix:@"texture3d"]) { td.textureType = MTLTextureType3D; td.depth = 8; td.width = td.height = 8; }
    else if ([type hasPrefix:@"texture2d"] || [type hasPrefix:@"depth2d"]) td.textureType = MTLTextureType2D;
    else return nil;
    if ([type containsString:@"<uint"] || [type containsString:@"<int"]) return nil;
    td.mipmapLevelCount = depth || td.textureType == MTLTextureType1D || td.textureType == MTLTextureType1DArray ? 1 : (td.textureType == MTLTextureType3D ? 4 : 5);
    // MAXMETAL_DIFF_ONE_LEVEL=1: one level, the LOD no matter (implicit-LOD samples in divergent control flow have undefined
    // derivatives: either side's pixels in a quad whose lanes diverge may pick another level)
    if (getenv("MAXMETAL_DIFF_ONE_LEVEL")) td.mipmapLevelCount = 1;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    // contents through a blit (depth textures are private on the Mac)
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    NSUInteger slices = td.arrayLength * (td.textureType == MTLTextureTypeCube || td.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    for (NSUInteger lv = 0; lv < td.mipmapLevelCount; lv++) {
        NSUInteger w = MAX(td.width >> lv, 1u), h = MAX(td.height >> lv, 1u), dz = MAX(td.depth >> lv, 1u);
        NSUInteger bpp = depth ? 4 : 8, row = w * bpp, img = row * h;
        NSMutableData *d = [NSMutableData dataWithLength:img * dz];
        if (depth) { float *f = d.mutableBytes; for (NSUInteger i = 0; i < w * h * dz; i++) f[i] = rndf(); }
        else { __fp16 *f = d.mutableBytes; for (NSUInteger i = 0; i < w * h * dz * 4; i++) f[i] = (__fp16)rndf(); }
        id<MTLBuffer> src = buf_with(d);
        for (NSUInteger sl = 0; sl < slices; sl++)
            [bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:img sourceSize:MTLSizeMake(w, h, dz)
                     toTexture:t destinationSlice:sl destinationLevel:lv destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    [bl endEncoding]; [cb commit]; wait_cb(cb, "setup");
    return t;
}

// An image (kind img): IMG_W x IMG_H 2D in the format its view names (the msl name's last part, as Ryujinx's "_r32ui"; none:
// unknown, RGBA32Float), shared storage so its contents can be set and read back; init: its contents (made when nil)
#define IMG_W 1024
#define IMG_H 64
static MTLPixelFormat image_format(NSString *fmt, NSUInteger *bpp) {
    NSDictionary *f = @{@"r8ui": @[@(MTLPixelFormatR8Uint), @1], @"r8i": @[@(MTLPixelFormatR8Sint), @1], @"r16ui": @[@(MTLPixelFormatR16Uint), @2],
                        @"r16i": @[@(MTLPixelFormatR16Sint), @2], @"r32ui": @[@(MTLPixelFormatR32Uint), @4], @"rg32ui": @[@(MTLPixelFormatRG32Uint), @8],
                        @"rgba32ui": @[@(MTLPixelFormatRGBA32Uint), @16], @"": @[@(MTLPixelFormatRGBA32Float), @16]};
    NSArray *e = f[fmt];
    if (!e) return MTLPixelFormatInvalid;
    *bpp = [e[1] unsignedIntegerValue];
    return (MTLPixelFormat)[e[0] unsignedIntegerValue];
}
static id<MTLTexture> make_image(NSString *fmt, NSData *init) {
    NSUInteger bpp; MTLPixelFormat pf = image_format(fmt, &bpp);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:IMG_W height:IMG_H mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, IMG_W, IMG_H) mipmapLevel:0 withBytes:init.bytes bytesPerRow:IMG_W * bpp];
    return t;
}
static NSData *image_bytes(id<MTLTexture> t, NSString *fmt) {
    NSUInteger bpp; image_format(fmt, &bpp);
    NSMutableData *d = [NSMutableData dataWithLength:IMG_W * IMG_H * bpp];
    [t getBytes:d.mutableBytes bytesPerRow:IMG_W * bpp fromRegion:MTLRegionMake2D(0, 0, IMG_W, IMG_H) mipmapLevel:0];
    return d;
}

static id<MTLSamplerState> make_sampler(BOOL compare) {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterLinear;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeRepeat;
    if (compare) sd.compareFunction = MTLCompareFunctionLessEqual;
    sd.supportArgumentBuffers = YES;
    return [dev newSamplerStateWithDescriptor:sd];
}

static NSData *hex_data(NSString *h) {
    NSMutableData *d = [NSMutableData dataWithLength:65536];
    uint8_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i + 1 < h.length && i / 2 < 65536; i += 2) p[i / 2] = (uint8_t)strtoul([[h substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16);
    return d;
}

// The argument buffer of one side. writable: key -> the side's own copy of each written buffer. nil + why when a
// binding is not supported here.
static id<MTLBuffer> encode_args(Side *s, NSMutableDictionary *writable, NSMutableArray *use, NSString **why) {
    if (![s->refl[@"bindings"] count]) return [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];   // (no argument buffer)
    id<MTLArgumentEncoder> enc = [s->fn newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ab = [dev newBufferWithLength:MAX(enc.encodedLength, 16u) options:MTLResourceStorageModeShared];
    [enc setArgumentBuffer:ab offset:0];
    NSSet *cmp = [NSSet setWithArray:s->refl[@"compare_slots"] ?: @[]];
    for (NSDictionary *b in s->refl[@"bindings"]) {
        NSString *kind = b[@"kind"]; NSUInteger aid = [b[@"arg_id"] unsignedIntegerValue];
        id reg = b[@"reg"] ?: b[@"bank"] ?: @0;
        NSString *key = [NSString stringWithFormat:@"%@:%@", kind, reg];
        if ([kind isEqual:@"cbuf"] || [kind isEqual:@"c1"] || [kind isEqual:@"drvcb"] || [kind isEqual:@"support"] || [kind isEqual:@"ubo_ptr"]) {
            id<MTLBuffer> bf = g_res[key];
            if (!bf) {
                NSData *d;
                if ([kind isEqual:@"c1"]) d = hex_data(s->refl[@"c1"] ?: @"");
                else if ([kind isEqual:@"drvcb"]) d = driver_bank([reg intValue]);
                else if ([kind isEqual:@"support"]) { NSMutableData *m = [NSMutableData dataWithLength:65536]; float one = 1; for (int i = 0; i < 73; i++) memcpy((uint8_t *)m.mutableBytes + 192 + 16 * i, &one, 4); d = m; }
                else d = random_floats(65536);
                g_res[key] = bf = buf_with(d);
            }
            [enc setBuffer:bf offset:0 atIndex:aid]; [use addObject:bf];
        } else if ([kind isEqual:@"sbuf"] || [kind isEqual:@"sbuf_ubo"]) {
            // sbuf_ubo: the buffer whose address the shader reads from uniform block reg at off (both sides subtract
            // that address again: any value there serves)
            if ([kind isEqual:@"sbuf_ubo"]) key = [NSString stringWithFormat:@"%@:%@", key, b[@"off"]];
            if (!g_init[key]) g_init[key] = random_floats(SBUF_BYTES);
            id<MTLBuffer> bf = writable[key];
            if (!bf) writable[key] = bf = buf_with(g_init[key]);
            [enc setBuffer:bf offset:0 atIndex:aid]; [use addObject:bf];
        } else if ([kind isEqual:@"img"]) {   // each side its own copy (any view may be written), compared after the run
            NSString *fmt = [b[@"msl_name"] componentsSeparatedByString:@"_"].lastObject, *ik = [NSString stringWithFormat:@"img:%@:%@", reg, fmt];
            NSUInteger bpp;
            if (image_format(fmt, &bpp) == MTLPixelFormatInvalid) { *why = [NSString stringWithFormat:@"image format %@", fmt]; return nil; }
            if (!g_init[ik]) {
                NSMutableData *d = [NSMutableData dataWithLength:IMG_W * IMG_H * bpp];
                if ([fmt isEqual:@""]) for (size_t i = 0; i < d.length / 4; i++) ((float *)d.mutableBytes)[i] = rndf();
                else {   // coordinates (x / y halves) other texels' own, shifted by the slot: shaders that scatter by them
                         // write each texel once (no race), counts read from them are large
                    uint32_t *u = d.mutableBytes; NSUInteger per = bpp / 4 ? bpp / 4 : 1; int r = [reg intValue];
                    for (NSUInteger i = 0; i < d.length / 4; i++) { NSUInteger tx = (i / per) % IMG_W, ty = (i / per) / IMG_W;
                        u[i] = (uint32_t)((tx + 7 * r + 1) % IMG_W) | (uint32_t)(((ty + 3 * r) % IMG_H) << 16); }
                }
                g_init[ik] = d;
            }
            id<MTLTexture> t = writable[ik];
            if (!t) writable[ik] = t = make_image(fmt, g_init[ik]);
            [enc setTexture:t atIndex:aid]; [use addObject:t];
        } else if ([kind isEqual:@"tex"]) {
            NSString *tk = [NSString stringWithFormat:@"%@:%@", key, b[@"msl_type"]];
            id<MTLTexture> t = g_res[tk];
            if (!t) { t = make_texture(b[@"msl_type"]); if (!t) { *why = [NSString stringWithFormat:@"texture type %@", b[@"msl_type"]]; return nil; } g_res[tk] = t; }
            [enc setTexture:t atIndex:aid]; [use addObject:t];
        } else if ([kind isEqual:@"samp_tex"] || [kind isEqual:@"samp"]) {
            BOOL c = [cmp containsObject:reg];
            NSString *sk = [NSString stringWithFormat:@"samp:%@:%d", reg, c];
            id<MTLSamplerState> ss = g_res[sk];
            if (!ss) g_res[sk] = ss = make_sampler(c);
            [enc setSamplerState:ss atIndex:aid];
        } else {
            *why = [NSString stringWithFormat:@"binding kind %@", kind];
            return nil;
        }
    }
    [use addObject:ab];
    return ab;
}

// ---- comparison
typedef struct { uint64_t exact, close, diff; double maxrel; NSString *first; } Cmp;
static void cmp_words(Cmp *c, const uint32_t *a, const uint32_t *b, size_t n, BOOL floats, NSString *what) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] == b[i]) { c->exact++; continue; }
        float fa, fb; memcpy(&fa, &a[i], 4); memcpy(&fb, &b[i], 4);
        double rel = fabs((double)fa - fb) / fmax(1.0, fmax(fabs(fa), fabs(fb)));
        if (floats && isfinite(fa) && isfinite(fb) && rel <= 1e-4) { c->close++; c->maxrel = fmax(c->maxrel, rel); continue; }
        if (floats && isnan(fa) && isnan(fb)) { c->close++; continue; }
        c->diff++;
        if (!c->first) c->first = [NSString stringWithFormat:@"%@[%zu]: ryujinx %08x (%g) maxmetal %08x (%g)", what, i, a[i], fa, b[i], fb];
    }
}

// ---- fragment: a full-screen triangle, varyings v_n = a_n + b_n * u + c_n * v
static NSString *g_vs_src;
static id<MTLFunction> grid_vs(void) {
    static id<MTLFunction> f;
    if (f) return f;
    NSMutableString *s = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct VO {\n    float4 pos [[position]];\n"];
    for (int i = 0; i < 32; i++) [s appendFormat:@"    float4 v%d [[user(locn%d)]];\n", i, i];
    [s appendString:@"};\nvertex VO gridvs(uint vid [[vertex_id]], constant float4 *k [[buffer(1)]]) {\n    float2 p = float2((vid << 1) & 2, vid & 2);\n    VO o;\n    o.pos = float4(p * 2.0f - 1.0f, 0.5f, 1.0f);\n"];
    for (int i = 0; i < 32; i++) [s appendFormat:@"    o.v%d = k[%d] + k[%d] * p.x + k[%d] * p.y;\n", i, 3 * i, 3 * i + 1, 3 * i + 2];
    [s appendString:@"    return o;\n}\n"];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:s options:nil error:&e];
    f = [lib newFunctionWithName:@"gridvs"];
    return f;
}

static MTLPixelFormat out_format(NSString *src, int n, BOOL *present) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\b(float|half|uint|int)([234]?)\\s+\\w+\\s*\\[\\[color\\(%d\\)\\]\\]", n] options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:src options:0 range:NSMakeRange(0, src.length)];
    *present = m != nil;
    if (!m) return MTLPixelFormatInvalid;
    NSString *t = [src substringWithRange:[m rangeAtIndex:1]];
    return [t isEqual:@"uint"] ? MTLPixelFormatRGBA32Uint : [t isEqual:@"int"] ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA32Float;
}

static BOOL ident_char(unichar ch) { return ch == '_' || (ch < 128 && isalnum(ch)); }

// Colour output n of main0_out made a `want` vector (uint / int: a render target the Ryujinx path writes as integers),
// so it binds to the same target format. The body keeps computing it in its own type: its out.<member> uses become a
// local, which every return bit-casts into the member.
static NSString *retype_color(NSString *msl, int n, NSString *want) {
    NSRange st = [msl rangeOfString:@"struct main0_out"];
    if (st.location == NSNotFound) return msl;
    NSRange body = [msl rangeOfString:@"};" options:0 range:NSMakeRange(st.location, msl.length - st.location)];
    NSRange attr = [msl rangeOfString:[NSString stringWithFormat:@"[[color(%d)]]", n] options:0
                                range:NSMakeRange(st.location, NSMaxRange(body) - st.location)];
    if (attr.location == NSNotFound) return msl;
    // the member's declaration: "<type> <member> [[color(n)]];"
    NSRange line = [msl lineRangeForRange:attr];
    NSArray *words = [[[msl substringWithRange:NSMakeRange(line.location, attr.location - line.location)]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (words.count != 2) return msl;
    NSString *type = words[0], *member = words[1];
    NSUInteger digit = [type rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location;
    NSString *width = digit == NSNotFound ? @"" : [type substringFromIndex:digit];
    NSString *shadow = [NSString stringWithFormat:@"color%d_value", n];
    NSMutableString *s = [msl mutableCopy];
    NSRange decl = NSMakeRange(line.location, attr.location - line.location);
    NSString *prefix = [s substringWithRange:decl];
    [s replaceCharactersInRange:decl withString:[prefix stringByReplacingCharactersInRange:[prefix rangeOfString:type]
                                                                               withString:[want stringByAppendingString:width]]];
    // out.<member> (not a longer name) -> the local, from the entry point on
    NSRange entry = [s rangeOfString:@" main0("];
    if (entry.location == NSNotFound) return msl;
    NSString *use = [@"out." stringByAppendingString:member];
    for (NSUInteger at = entry.location;;) {
        NSRange r = [s rangeOfString:use options:0 range:NSMakeRange(at, s.length - at)];
        if (r.location == NSNotFound) break;
        BOOL whole = (r.location == 0 || !ident_char([s characterAtIndex:r.location - 1])) &&
                     (NSMaxRange(r) == s.length || !ident_char([s characterAtIndex:NSMaxRange(r)]));
        if (whole) [s replaceCharactersInRange:r withString:shadow];
        at = r.location + (whole ? shadow.length : r.length);
    }
    // the local, declared where the function body starts; each return stores it first
    NSRange open = [s rangeOfString:@"{" options:0 range:NSMakeRange(entry.location, s.length - entry.location)];
    if (open.location == NSNotFound) return msl;
    [s insertString:[NSString stringWithFormat:@"\n    %@ %@ = {};", type, shadow] atIndex:NSMaxRange(open)];
    [s replaceOccurrencesOfString:@"return out;"
                       withString:[NSString stringWithFormat:@"{ out.%@ = as_type<%@%@>(%@); return out; }", member, want, width, shadow]
                          options:0 range:NSMakeRange(entry.location, s.length - entry.location)];
    return s;
}

static double run_time(id<MTLCommandBuffer> cb) { return (cb.GPUEndTime - cb.GPUStartTime) * 1e3; }

static NSString *run_fragment(Side *sd, NSData **out_colors, NSMutableDictionary *writable, double *ms) {
    int W = 32, H = 32;
    NSMutableArray *use = [NSMutableArray array]; NSString *why = nil;
    id<MTLBuffer> ab = encode_args(sd, writable, use, &why);
    if (!ab) return why;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = grid_vs(); pd.fragmentFunction = sd->fn;
    NSMutableArray *targets = [NSMutableArray array];
    for (int n = 0; n < 8; n++) {
        BOOL present; MTLPixelFormat f = out_format(sd->msl, n, &present);
        if (!present) { [targets addObject:[NSNull null]]; continue; }
        pd.colorAttachments[n].pixelFormat = f;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        [targets addObject:[dev newTextureWithDescriptor:td]];
    }
    BOOL depth = [sd->msl containsString:@"[[depth("];
    id<MTLTexture> dt = nil;
    if (depth) {
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        dt = [dev newTextureWithDescriptor:td];
    }
    NSError *e = nil;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) return [NSString stringWithFormat:@"pipeline: %@", e.localizedDescription];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = depth;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    id<MTLBuffer> k = g_res[@"grid"];
    if (!k) { NSMutableData *d = [NSMutableData dataWithLength:96 * 16]; float *f = d.mutableBytes; for (int i = 0; i < 96 * 4; i++) f[i] = rndf() * 2.0f - 0.5f; g_res[@"grid"] = k = buf_with(d); }
    int reps = ms ? g_time : 1;
    id<MTLBuffer> capb = cap_buffer();
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    for (int r = 0; r < reps; r++) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (int n = 0; n < 8; n++) {
            if (targets[n] == [NSNull null]) continue;
            rp.colorAttachments[n].texture = targets[n]; rp.colorAttachments[n].loadAction = MTLLoadActionClear;
            rp.colorAttachments[n].storeAction = MTLStoreActionStore; rp.colorAttachments[n].clearColor = MTLClearColorMake(0, 0, 0, 0);
        }
        if (dt) { rp.depthAttachment.texture = dt; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = 0.25; }
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:ps]; [en setDepthStencilState:ds];
        [en setVertexBuffer:k offset:0 atIndex:1];
        [en setFragmentBuffer:ab offset:0 atIndex:0];
        [en setFragmentBuffer:capb offset:0 atIndex:CAP_INDEX];
        for (id r in use) [en useResource:r usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:MTLRenderStageFragment];
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [en endEncoding];
    }
    NSMutableArray *reads = [NSMutableArray array];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    for (int n = 0; n < 9; n++) {
        id<MTLTexture> t = n < 8 ? (targets[n] == [NSNull null] ? nil : targets[n]) : dt;
        if (!t) { [reads addObject:[NSNull null]]; continue; }
        NSUInteger bpp = n < 8 ? 16 : 4;
        id<MTLBuffer> rb = [dev newBufferWithLength:W * H * bpp options:MTLResourceStorageModeShared];
        [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                   toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * bpp destinationBytesPerImage:W * H * bpp];
        [reads addObject:rb];
    }
    [bl endEncoding];
    [cb commit]; wait_cb(cb, sd->who);
    if (cb.error) return [NSString stringWithFormat:@"gpu: %@", cb.error.localizedDescription];
    if (ms) *ms = run_time(cb) / reps;
    else cap_check(sd, capb);
    NSMutableData *all = [NSMutableData data];
    for (int n = 0; n < 9; n++) {
        uint32_t len = reads[n] == [NSNull null] ? 0 : (uint32_t)[reads[n] length];
        [all appendBytes:&len length:4];
        if (len) [all appendBytes:[reads[n] contents] length:len];
    }
    *out_colors = all;
    return nil;
}

// ---- vertex: the outputs of 64 vertices, stored by an added store before each return
static NSString *with_vertex_dump(NSString *src, NSString **err) {
    NSRegularExpression *st = [NSRegularExpression regularExpressionWithPattern:@"struct main0_out\\s*\\{(.*?)\\};" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *m = [st firstMatchInString:src options:0 range:NSMakeRange(0, src.length)];
    if (!m) { *err = @"no main0_out"; return nil; }
    NSString *body = [src substringWithRange:[m rangeAtIndex:1]];
    NSMutableString *stores = [NSMutableString string];
    NSRegularExpression *fld = [NSRegularExpression regularExpressionWithPattern:@"(\\w+)\\s+(\\w+)\\s*\\[\\[(user\\(locn(\\d+)\\)|position[^\\]]*|point_size)\\]\\]" options:0 error:nil];
    for (NSTextCheckingResult *f in [fld matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
        NSString *type = [body substringWithRange:[f rangeAtIndex:1]], *name = [body substringWithRange:[f rangeAtIndex:2]];
        NSString *attr = [body substringWithRange:[f rangeAtIndex:3]];
        int slot = [attr hasPrefix:@"position"] ? 32 : [attr hasPrefix:@"point_size"] ? 33 : [[body substringWithRange:[f rangeAtIndex:4]] intValue];
        NSString *v = [type isEqual:@"float4"] ? [NSString stringWithFormat:@"out.%@", name] :
                      [type isEqual:@"float"] ? [NSString stringWithFormat:@"float4(out.%@, 0, 0, 0)", name] :
                      [NSString stringWithFormat:@"as_type<float4>(uint4(as_type<uint4>(%@4(out.%@))))", [type substringToIndex:type.length - 1], name];
        if (![type hasSuffix:@"4"] && ![type isEqual:@"float"]) { *err = [NSString stringWithFormat:@"output type %@", type]; return nil; }
        [stores appendFormat:@"maxmetal_dump[maxmetal_vid * 34u + %du] = %@; ", slot, v];
    }
    NSRegularExpression *vid = [NSRegularExpression regularExpressionWithPattern:@"uint\\s+(\\w+)\\s*\\[\\[vertex_id\\]\\]" options:0 error:nil];
    NSTextCheckingResult *vm = [vid firstMatchInString:src options:0 range:NSMakeRange(0, src.length)];
    NSString *vname = vm ? [src substringWithRange:[vm rangeAtIndex:1]] : @"maxmetal_vid";
    if (![src containsString:@"vertex main0_out main0("]) { *err = @"no vertex main0"; return nil; }
    NSRange open = [src rangeOfString:@"vertex main0_out main0("];
    NSString *add = vm ? @"device float4 *maxmetal_dump [[buffer(29)]], " : @"device float4 *maxmetal_dump [[buffer(29)]], uint maxmetal_vid [[vertex_id]], ";
    if ([[src substringFromIndex:NSMaxRange(open)] hasPrefix:@")"]) add = [add substringToIndex:add.length - 2];   // (no parameters)
    src = [src stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(open), 0) withString:add];
    stores = [[stores stringByReplacingOccurrencesOfString:@"maxmetal_vid" withString:vname] mutableCopy];
    return [src stringByReplacingOccurrencesOfString:@"return out;" withString:[NSString stringWithFormat:@"{ %@return out; }", stores]];
}

static NSString *run_vertex(Side *sd, NSData **dump, NSMutableDictionary *writable, NSDictionary *ryu_types, double *ms) {
    NSString *err = nil;
    NSString *src = with_vertex_dump(sd->msl, &err);
    if (!src) return err;
    id<MTLFunction> fn = compile(src, &err);
    if (!fn) return [NSString stringWithFormat:@"dump variant: %@", err];
    Side s2 = *sd; s2.fn = fn;
    NSMutableArray *use = [NSMutableArray array]; NSString *why = nil;
    id<MTLBuffer> ab = encode_args(&s2, writable, use, &why);
    if (!ab) return why;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = fn;
    static id<MTLFunction> nullfs;
    if (!nullfs) nullfs = [[dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 nullfs() { return float4(0); }\n" options:nil error:nil] newFunctionWithName:@"nullfs"];
    pd.fragmentFunction = nullfs;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    int nv = 64;
    for (NSDictionary *vi in sd->refl[@"vertex_inputs"]) {
        int loc = [vi[@"location"] intValue]; NSString *t = vi[@"msl_type"];
        MTLVertexFormat f = [t hasPrefix:@"uint"] ? MTLVertexFormatUInt4 : [t hasPrefix:@"int"] ? MTLVertexFormatInt4 : MTLVertexFormatFloat4;
        if ([t hasSuffix:@"2"]) f = f == MTLVertexFormatUInt4 ? MTLVertexFormatUInt2 : f == MTLVertexFormatInt4 ? MTLVertexFormatInt2 : MTLVertexFormatFloat2;
        else if ([t hasSuffix:@"3"]) f = f == MTLVertexFormatUInt4 ? MTLVertexFormatUInt3 : f == MTLVertexFormatInt4 ? MTLVertexFormatInt3 : MTLVertexFormatFloat3;
        else if (![t hasSuffix:@"4"]) f = f == MTLVertexFormatUInt4 ? MTLVertexFormatUInt : f == MTLVertexFormatInt4 ? MTLVertexFormatInt : MTLVertexFormatFloat;
        vd.attributes[loc].format = f; vd.attributes[loc].offset = 0; vd.attributes[loc].bufferIndex = 16 + loc;
        vd.layouts[16 + loc].stride = 16;
        NSString *key = [NSString stringWithFormat:@"attr:%d", loc];
        if (!g_res[key]) {   // integers where the Ryujinx path types the input as one (indices), floats in [0, 1) else (as texture coordinates, weights)
            NSMutableData *d = [NSMutableData dataWithLength:nv * 16];
            BOOL ints = [ryu_types[@(loc)] hasPrefix:@"uint"] || [ryu_types[@(loc)] hasPrefix:@"int"];
            uint32_t *w = d.mutableBytes;
            for (int i = 0; i < nv * 4; i++) { if (ints) w[i] = rnd() & 15; else { float f = rndf(); memcpy(&w[i], &f, 4); } }
            g_res[key] = buf_with(d);
        }
    }
    pd.vertexDescriptor = vd;
    NSError *e = nil;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) return [NSString stringWithFormat:@"pipeline: %@", e.localizedDescription];
    id<MTLBuffer> db = [dev newBufferWithLength:nv * 34 * 16 options:MTLResourceStorageModeShared];
    memset(db.contents, 0, db.length);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    int reps = ms ? g_time : 1;
    id<MTLBuffer> capb = cap_buffer();
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    for (int r = 0; r < reps; r++) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:ps];
        [en setVertexBuffer:ab offset:0 atIndex:0];
        [en setVertexBuffer:db offset:0 atIndex:29];
        [en setVertexBuffer:capb offset:0 atIndex:CAP_INDEX];
        for (NSDictionary *vi in sd->refl[@"vertex_inputs"]) { int loc = [vi[@"location"] intValue]; [en setVertexBuffer:g_res[[NSString stringWithFormat:@"attr:%d", loc]] offset:0 atIndex:16 + loc]; }
        for (id x in use) [en useResource:x usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:MTLRenderStageVertex];
        [en drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:nv];
        [en endEncoding];
    }
    [cb commit]; wait_cb(cb, sd->who);
    if (cb.error) return [NSString stringWithFormat:@"gpu: %@", cb.error.localizedDescription];
    if (ms) *ms = run_time(cb) / reps;
    else cap_check(sd, capb);
    *dump = [NSData dataWithBytes:db.contents length:db.length];
    return nil;
}

static NSString *run_compute(Side *sd, NSMutableDictionary *writable, double *ms) {
    NSMutableArray *use = [NSMutableArray array]; NSString *why = nil;
    id<MTLBuffer> ab = encode_args(sd, writable, use, &why);
    if (!ab) return why;
    NSError *e = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:sd->fn error:&e];
    if (!ps) return [NSString stringWithFormat:@"pipeline: %@", e.localizedDescription];
    NSArray *tg = sd->refl[@"threadgroup_size"];
    MTLSize local = MTLSizeMake([tg[0] unsignedIntegerValue], [tg[1] unsignedIntegerValue], [tg[2] unsignedIntegerValue]);
    id<MTLBuffer> capb = cap_buffer();
    if (!ms) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
        [en setComputePipelineState:ps];
        [en setBuffer:ab offset:0 atIndex:0];
        [en setBuffer:capb offset:0 atIndex:CAP_INDEX];
        for (id x in use) [en useResource:x usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [en dispatchThreadgroups:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:local];
        [en endEncoding];
        [cb commit]; wait_cb(cb, sd->who);
        if (cb.error) return [NSString stringWithFormat:@"gpu: %@", cb.error.localizedDescription];
        cap_check(sd, capb);
        return nil;
    }
    // Timing: CS_TIME_GROUPS threadgroups (default 128: 2 take a few microseconds, below the noise), each run in its own
    // command buffer from the initial buffer contents (the stores of a run before change what loops see); the median.
    const char *g = getenv("CS_TIME_GROUPS");
    NSUInteger groups = g ? (NSUInteger)atoi(g) : 128;
    double t[256]; int reps = MIN(g_time, 256);
    id<MTLBuffer> c0 = g_res[@"drvcb:0"];  // the grid size the shader reads (driver_bank), for the timed dispatch
    uint32_t grid[3] = {(uint32_t)groups, 1, 1}, grid0[3] = {2, 1, 1};
    if (c0) memcpy((uint8_t *)c0.contents + 0x200, grid, 12);
    // CS_TIME_SCALE: the floats of the storage / uniform buffers times this for the timed runs (counts and loop bounds
    // read from [0, 1) truncate to 0: the shader ends at once)
    const char *sc = getenv("CS_TIME_SCALE");
    float scale = sc ? (float)atof(sc) : 1;
    NSMutableDictionary *init = [NSMutableDictionary dictionary], *saved = [NSMutableDictionary dictionary];
    for (NSString *k in writable) {
        if ([k hasPrefix:@"img:"]) continue;   // (images: as they are)
        NSMutableData *d = [g_init[k] mutableCopy];
        for (size_t i = 0; i < d.length / 4; i++) ((float *)d.mutableBytes)[i] *= scale;
        init[k] = d;
    }
    for (NSString *k in g_res)
        if ([k hasPrefix:@"ubo_ptr:"] || [k hasPrefix:@"cbuf:"]) {
            id<MTLBuffer> b = g_res[k];
            saved[k] = [NSData dataWithBytes:b.contents length:b.length];
            for (size_t i = 0; i < b.length / 4; i++) ((float *)b.contents)[i] *= scale;
        }
    for (int r = 0; r < reps; r++) {
        for (NSString *k in writable) if (init[k]) memcpy([writable[k] contents], [init[k] bytes], [init[k] length]);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
        [en setComputePipelineState:ps];
        [en setBuffer:ab offset:0 atIndex:0];
        [en setBuffer:capb offset:0 atIndex:CAP_INDEX];
        for (id x in use) [en useResource:x usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [en dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:local];
        [en endEncoding];
        [cb commit]; wait_cb(cb, sd->who);
        t[r] = cb.error ? -1 : run_time(cb);
        if (cb.error) break;
    }
    if (c0) memcpy((uint8_t *)c0.contents + 0x200, grid0, 12);
    for (NSString *k in saved) memcpy([g_res[k] contents], [saved[k] bytes], [saved[k] length]);
    for (int r = 0; r < reps; r++) if (t[r] < 0) return @"gpu error while timing";
    for (int i = 1; i < reps; i++) for (int j = i; j > 0 && t[j] < t[j - 1]; j--) { double x = t[j]; t[j] = t[j - 1]; t[j - 1] = x; }
    *ms = reps ? t[reps / 2] : 0;
    return nil;
}

static BOOL load_side(Side *s, NSString *dir, NSString *variant) {
    NSString *base = [dir stringByAppendingPathComponent:[variant stringByAppendingString:@"_b"]];
    s->msl = [NSString stringWithContentsOfFile:[base stringByAppendingString:@".metal"] encoding:NSUTF8StringEncoding error:nil];
    NSData *j = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".json"]];
    s->refl = j ? [NSJSONSerialization JSONObjectWithData:j options:0 error:nil] : nil;
    if (!s->msl || !s->refl) { s->err = @"missing files"; return NO; }
    NSString *err = nil;
    s->fn = compile(s->msl, &err);
    if (!s->fn) { s->err = err; return NO; }
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        int a = 1;
        if (argc > 2 && !strcmp(argv[1], "--time")) { g_time = atoi(argv[2]); a = 3; }
        if (argc - a < 3) { fprintf(stderr, "usage: maxmetal-diff [--time N] <ryujinx dir> <maxmetal dir> <variant>...\n"); return 2; }
        dev = MTLCreateSystemDefaultDevice(); queue = [dev newCommandQueue];
        NSString *ryu = @(argv[a]), *mm = @(argv[a + 1]);
        for (int i = a + 2; i < argc; i++) {
            @autoreleasepool {
                NSString *variant = @(argv[i]);
                Side R = {.who = "ryujinx"}, L = {.who = "maxmetal"};
                g_variant = argv[i];
                g_capped = 0;
                if (!load_side(&R, ryu, variant)) { printf("skip %s ryujinx: %s\n", argv[i], [[R.err stringByReplacingOccurrencesOfString:@"\n" withString:@" "] substringToIndex:MIN(R.err.length, 160u)].UTF8String); continue; }
                int loops_r = g_capsites;
                if (!load_side(&L, mm, variant)) { printf("fail %s maxmetal compile: %s\n", argv[i], [[L.err stringByReplacingOccurrencesOfString:@"\n" withString:@" "] substringToIndex:MIN(L.err.length, 200u)].UTF8String); continue; }
                if (getenv("MAXMETAL_DIFF_COMPILE_ONLY")) {   // (both sides compiled, loop cap and all; nothing runs on the GPU)
                    printf("compiled %s loops_ryujinx=%d loops_maxmetal=%d\n", argv[i], loops_r, g_capsites);
                    fflush(stdout);
                    continue;
                }
                // the stage the program is (the SPH's; a real game's "ps" request can be a vertex program), not the request's label
                NSString *kind = R.refl[@"msl_entry_kind"];
                g_stage = [kind isEqual:@"vertex"] ? @"vs" : [kind isEqual:@"fragment"] ? @"ps" : [kind isEqual:@"kernel"] ? @"cs" : R.refl[@"stage"];
                g_res = [NSMutableDictionary dictionary]; g_init = [NSMutableDictionary dictionary];
                seed(argv[i]);
                NSMutableDictionary *wr = [NSMutableDictionary dictionary], *wl = [NSMutableDictionary dictionary];
                Cmp c = {0};
                NSString *er = nil, *el = nil;
                double tr = 0, tl = 0;
                if ([g_stage isEqual:@"ps"]) {
                    // outputs the Ryujinx path declares as integers: the maxmetal function retyped as the renderer retypes it
                    for (int n = 0; n < 8; n++) {
                        BOOL pr, pl; MTLPixelFormat fr = out_format(R.msl, n, &pr); out_format(L.msl, n, &pl);
                        if (pr && pl && fr != MTLPixelFormatRGBA32Float) {
                            L.msl = retype_color(L.msl, n, fr == MTLPixelFormatRGBA32Uint ? @"uint" : @"int");
                            NSString *e2 = nil; L.fn = compile(L.msl, &e2);
                            if (!L.fn) { el = [NSString stringWithFormat:@"retyped: %@", e2]; break; }
                        }
                    }
                    NSData *cr = nil, *cl = nil;
                    if (!el) er = run_fragment(&R, &cr, wr, NULL);
                    if (!er && !el) el = run_fragment(&L, &cl, wl, NULL);
                    if (!er && !el) {
                        const char *dump = getenv("MAXMETAL_DIFF_DUMP");   // <dir>: both sides' outputs as <variant>.ryu / .maxmetal
                        if (dump) {
                            [cr writeToFile:[NSString stringWithFormat:@"%s/%s.ryu", dump, argv[i]] atomically:NO];
                            [cl writeToFile:[NSString stringWithFormat:@"%s/%s.maxmetal", dump, argv[i]] atomically:NO];
                        }
                        const uint8_t *pr = cr.bytes, *pl = cl.bytes;
                        for (int n = 0; n < 9; n++) {
                            uint32_t lr, ll; memcpy(&lr, pr, 4); memcpy(&ll, pl, 4); pr += 4; pl += 4;
                            if (lr != ll) { c.diff++; c.first = c.first ?: [NSString stringWithFormat:@"output %d present in one only", n]; }
                            else if (lr) {
                                BOOL fl; MTLPixelFormat f = n < 8 ? out_format(R.msl, n, &fl) : MTLPixelFormatRGBA32Float;
                                cmp_words(&c, (const uint32_t *)pr, (const uint32_t *)pl, lr / 4, f == MTLPixelFormatRGBA32Float, n < 8 ? [NSString stringWithFormat:@"color%d", n] : @"depth");
                            }
                            pr += lr; pl += ll;
                        }
                    }
                    if (!er && !el && g_time) { run_fragment(&R, &cr, wr, &tr); run_fragment(&L, &cl, wl, &tl); }
                } else if ([g_stage isEqual:@"vs"]) {
                    NSMutableDictionary *types = [NSMutableDictionary dictionary];
                    for (NSDictionary *vi in R.refl[@"vertex_inputs"]) types[vi[@"location"]] = vi[@"msl_type"];
                    NSData *dr = nil, *dl = nil;
                    er = run_vertex(&R, &dr, wr, types, NULL);
                    if (!er) el = run_vertex(&L, &dl, wl, types, NULL);
                    if (!er && !el) {
                        const char *dump = getenv("MAXMETAL_DIFF_DUMP");   // <dir>: both sides' varyings (64 vertices x 34 x float4)
                        if (dump) {
                            [dr writeToFile:[NSString stringWithFormat:@"%s/%s.ryu", dump, argv[i]] atomically:NO];
                            [dl writeToFile:[NSString stringWithFormat:@"%s/%s.maxmetal", dump, argv[i]] atomically:NO];
                        }
                        // varyings maxmetal writes; the Ryujinx path's (0, 0, 0, 1) for one it does not write is not compared
                        const uint32_t *a2 = dr.bytes, *b2 = dl.bytes;
                        for (int v = 0; v < 64; v++)
                            for (int s = 0; s < 34; s++) {
                                const uint32_t *x = a2 + (v * 34 + s) * 4, *y = b2 + (v * 34 + s) * 4;
                                BOOL zx = !x[0] && !x[1] && !x[2] && !x[3], zy = !y[0] && !y[1] && !y[2] && !y[3];
                                if (zx != zy && s < 32) { c.diff++; c.first = c.first ?: [NSString stringWithFormat:@"varying %d written by one only", s]; continue; }
                                cmp_words(&c, x, y, s == 33 ? 1 : 4, YES, s == 32 ? @"position" : s == 33 ? @"point size" : [NSString stringWithFormat:@"v%d", s]);
                            }
                    }
                    if (!er && !el && g_time) { run_vertex(&R, &dr, wr, types, &tr); run_vertex(&L, &dl, wl, types, &tl); }
                } else {
                    er = run_compute(&R, wr, NULL);
                    if (!er) el = run_compute(&L, wl, NULL);
                }
                // stores to storage buffers (both started from the same contents)
                if (!er && !el)
                    for (NSString *k in wr) {
                        if (!wl[k]) { c.diff++; c.first = c.first ?: [NSString stringWithFormat:@"%@ bound by ryujinx only", k]; continue; }
                        if ([k hasPrefix:@"img:"]) {   // an image: its texels (uint formats bit for bit)
                            NSString *fmt = [k componentsSeparatedByString:@":"].lastObject;
                            NSData *x = image_bytes(wr[k], fmt), *y = image_bytes(wl[k], fmt);
                            cmp_words(&c, x.bytes, y.bytes, x.length / 4, [fmt isEqual:@""], k);
                            continue;
                        }
                        id<MTLBuffer> x = wr[k], y = wl[k];
                        cmp_words(&c, x.contents, y.contents, x.length / 4, YES, k);
                    }
                // (compute: timed after the comparison, the timed runs change the stored contents)
                if (!er && !el && g_time && [g_stage isEqual:@"cs"] && (run_compute(&R, wr, &tr) || run_compute(&L, wl, &tl)))
                    tr = tl = 0;  // (a GPU error: no time)
                if (er || el) {
                    printf(er ? "skip %s ryujinx run: %s\n" : "fail %s maxmetal run: %s\n", argv[i], (er ?: el).UTF8String);
                    // after a GPU error the system ignores this process's later command buffers: exit (3, as wait_cb)
                    if ([er ?: el hasPrefix:@"gpu:"]) { fflush(stdout); _exit(3); }
                    continue;
                }
                // (a side hit the loop cap: its outputs say nothing, unless both still agree)
                const char *verdict = g_capped && (c.diff || c.close) ? "capped" : c.diff ? "diff" : c.close ? "close" : "exact";
                printf("%s %s %s exact=%llu close=%llu diff=%llu maxrel=%.2g", verdict, argv[i], g_stage.UTF8String,
                       (unsigned long long)c.exact, (unsigned long long)c.close, (unsigned long long)c.diff, c.maxrel);
                if (g_time) printf(" ms_ryujinx=%.4f ms_maxmetal=%.4f", tr, tl);
                if (g_capped) printf(" loop_capped=%s", g_capped == 3 ? "both" : g_capped == 1 ? "ryujinx" : "maxmetal");
                if (c.first) printf(" first: %s", c.first.UTF8String);
                printf("\n");
                fflush(stdout);
            }
        }
    }
    return 0;
}

// Translator tests: small hand-assembled Maxwell programs, each translated and compared with its expected output in
// tests/golden (<name>.metal or .glsl, and <name>.json: an NVN translation's reflection). Every output also goes to
// <out dir> for the Metal compile test (tests/metal_compile.cmake).
// MAXMETAL_UPDATE_GOLDEN=1 writes the expected files from this run instead: review their diff before committing it.
// Usage: test_translate <golden dir> <out dir> [test name...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "maxmetal/maxmetal.h"

// ---- a small assembler: the fields the translator reads, the rest zero
enum { P0 = 0, P1 = 1, PT = 7, RZ = 255 };
enum { SR_TID_X = 0x21, SR_CTAID_X = 0x25 };
enum { LT = 1, EQ = 2, LE = 3, GT = 4, NE = 5, GE = 6 };  // FSETP / ISETP comparisons

#define AL ((uint64_t)PT << 16)  // guard: always

static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static uint64_t rr(uint64_t op, int d, int a) { return op | AL | (uint64_t)a << 8 | (uint64_t)d; }
// @Pp / @!Pp in front of w
static uint64_t at(int p, int neg, uint64_t w) { return (w & ~(0xfull << 16)) | (uint64_t)(p | (neg ? 8 : 0)) << 16; }

static uint64_t mov32i(int d, uint32_t v) { return 0x0100000000000000ull | (uint64_t)v << 20 | 0xfull << 12 | AL | d; }
static uint64_t movf(int d, float v) { return mov32i(d, fb(v)); }
static uint64_t fadd(int d, int a, int b) { return rr(0x5c58000000000000ull | (uint64_t)b << 20, d, a); }
static uint64_t fadd32i(int d, int a, float v) { return rr(0x0800000000000000ull | (uint64_t)fb(v) << 20, d, a); }
static uint64_t fmul(int d, int a, int b) { return rr(0x5c68000000000000ull | (uint64_t)b << 20, d, a); }
static uint64_t fmul_c(int d, int a, int bank, uint32_t off) {  // d = a * c[bank][off]
    return rr(0x4c68000000000000ull | (uint64_t)bank << 34 | (uint64_t)(off / 4) << 20, d, a);
}
static uint64_t ffma(int d, int a, int b, int c) { return rr(0x5980000000000000ull | (uint64_t)c << 39 | (uint64_t)b << 20, d, a); }
static uint64_t mufu_rcp(int d, int a) { return rr(0x5080000000000000ull | 4ull << 20, d, a); }
static uint64_t iadd32i(int d, int a, int32_t v) { return rr(0x1c00000000000000ull | (uint64_t)(uint32_t)v << 20, d, a); }
static uint64_t iadd_cc(int d, int a, int b) { return rr(0x5c10000000000000ull | 1ull << 47 | (uint64_t)b << 20, d, a); }
static uint64_t iadd_x(int d, int a, int b) { return rr(0x5c10000000000000ull | 1ull << 43 | (uint64_t)b << 20, d, a); }
static uint64_t shl_i(int d, int a, int n) { return rr(0x3848000000000000ull | (uint64_t)n << 20, d, a); }
// p = a <cmp> imm (float, its top 20 bits) / p = int(a) <cmp> imm, AND PT; the second destination PT
static uint64_t fsetp_i(int p, int cmp, int a, float v) {
    return rr(0x36b0000000000000ull | (uint64_t)cmp << 48 | (uint64_t)PT << 39 | (uint64_t)(fb(v) >> 12 & 0x7ffff) << 20 |
              (uint64_t)(fb(v) >> 31) << 56, (p << 3) | PT, a);
}
static uint64_t isetp_i(int p, int cmp, int a, int32_t v) {
    return rr(0x3660000000000000ull | (uint64_t)cmp << 49 | 1ull << 48 | (uint64_t)PT << 39 | (uint64_t)(v & 0x7ffff) << 20 |
              (uint64_t)(v < 0) << 56, (p << 3) | PT, a);
}
// branch offsets are from the next instruction
static uint64_t bra(int pc, int target) { return 0xe24000000007000full | (uint64_t)((target - pc - 8) & 0xffffff) << 20; }
static uint64_t ssy(int pc, int target) { return 0xe290000000000000ull | (uint64_t)((target - pc - 8) & 0xffffff) << 20; }
static uint64_t sync_(void) { return 0xf0f800000007000full; }
static uint64_t exit_(void) { return 0xe30000000007000full; }
static uint64_t kil(void) { return 0xe33000000007000full; }
static uint64_t ipa(int d, uint32_t addr, int mode, int mul) {  // mode: 0 pass, 1 multiply (by mul)
    return 0xe000000000000000ull | (uint64_t)mode << 54 | (uint64_t)RZ << 39 | (uint64_t)addr << 28 | (uint64_t)mul << 20 | AL |
           (uint64_t)RZ << 8 | d;
}
static uint64_t ald(int d, uint32_t addr, int n) { return rr(0xefd8000000000000ull | (uint64_t)(n - 1) << 47 | (uint64_t)RZ << 39 | (uint64_t)addr << 20, d, RZ); }
static uint64_t ast(int s, uint32_t addr, int n) { return rr(0xeff0000000000000ull | (uint64_t)(n - 1) << 47 | (uint64_t)RZ << 39 | (uint64_t)addr << 20, s, RZ); }
static uint64_t ldc(int d, int bank, uint32_t off, int wide) {  // d (d + 1) = c[bank][off]
    return rr(0xef90000000000000ull | (uint64_t)(wide ? 5 : 4) << 48 | (uint64_t)bank << 36 | (uint64_t)(off & 0xffff) << 20, d, RZ);
}
// TEXS 2D, 32-bit results: rgba into d0, d0 + 1, d1, d1 + 1; coordinates (a, b); NVN texture slot (handle c2[0x20 + 8 * slot])
static uint64_t texs2d(int d0, int d1, int a, int b, int slot) {
    return rr(0xd800000000000000ull | 1ull << 53 | 4ull << 50 | (uint64_t)(0x20 + 8 * slot) / 4 << 36 | (uint64_t)d1 << 28 |
              (uint64_t)b << 20, d0, a);
}
static uint64_t mov_rz(int d) { return rr(0x5c98078000000000ull | (uint64_t)RZ << 20, d, 0); }
static uint64_t i2f_neg(int d, int b) {  // d = float(-int(b))
    return rr(0x5cb8000000000000ull | 1ull << 45 | 1ull << 13 | 2ull << 10 | 2ull << 8 | (uint64_t)b << 20, d, 0);
}
// XMAD reg, reg: d = (a.lo|hi * b.lo|hi) (<< 16: psl) + c (cmode 4: cbcc), mrg: the result's high half b's low half
static uint64_t xmad(int d, int a, int ha, int b, int hb, int c, int psl, int mrg, int cmode) {
    return rr(0x5b00000000000000ull | (uint64_t)b << 20 | (uint64_t)c << 39 | (uint64_t)hb << 35 | (uint64_t)psl << 36 |
              (uint64_t)mrg << 37 | (uint64_t)cmode << 50 | (uint64_t)ha << 53, d, a);
}
static uint64_t s2r(int d, int sr) { return rr(0xf0c8000000000000ull | (uint64_t)sr << 20, d, 0); }
static uint64_t lds(int d, int a, int off) { return rr(0xef48000000000000ull | 4ull << 48 | (uint64_t)(off & 0xffffff) << 20, d, a); }
static uint64_t sts(int s, int a, int off) { return rr(0xef58000000000000ull | 4ull << 48 | (uint64_t)(off & 0xffffff) << 20, s, a); }
static uint64_t bar(void) { return 0xf0a81b8000070000ull; }
static uint64_t ldg(int d, int a, int off) { return rr(0xeed0000000000000ull | 4ull << 48 | 1ull << 45 | (uint64_t)(off & 0xffffff) << 20, d, a); }
static uint64_t stg(int s, int a, int off) { return rr(0xeed8000000000000ull | 4ull << 48 | 1ull << 45 | (uint64_t)(off & 0xffffff) << 20, s, a); }

// A program: instructions with their pc (8 bytes each, a scheduling word before every three), ended by NVN's padding
// (a branch to itself)
typedef struct { uint64_t w[256]; int n; } Prog;
static int pc_of(int i) { return (i / 3 * 4 + i % 3 + 1) * 8; }  // instruction i's pc
static int emit(Prog *p, uint64_t w) { int pc = pc_of(p->n); p->w[p->n++] = w; return pc; }
static int next_pc(const Prog *p) { return pc_of(p->n); }

// The translator's input: the NVN header (0x30 bytes) and the SPH (0x50) before graphics code, nothing before compute
static uint8_t *build(const Prog *p, int stage, uint32_t omap, size_t *size) {
    Prog q = *p;
    while (q.n % 3 != 2) q.w[q.n++] = 0x50b0000000070f00ull;  // NOP
    q.w[q.n] = 0xe2400fffff87000full;                          // the padding: BRA to the scheduling word before it
    q.n++;
    size_t head = stage == STAGE_COMPUTE ? 0 : 0x80, words = (size_t)q.n / 3 * 4 + 4;
    uint8_t *b = calloc(1, head + words * 8 + 64);
    if (head) {
        uint32_t sph0 = (stage == STAGE_FRAGMENT ? 2u : 1u) | 3u << 5 | (stage == STAGE_FRAGMENT ? 5u : 1u) << 10;
        memcpy(b + 0x30, &sph0, 4);
        memcpy(b + 0x30 + 0x48, &omap, 4);
    }
    uint64_t *code = (uint64_t *)(b + head);
    for (int i = 0; i < q.n; i++) {
        if (i % 3 == 0) code[i / 3 * 4] = 0x001f8000fc0007e0ull;  // scheduling word
        code[pc_of(i) / 8] = q.w[i];
    }
    *size = head + words * 8;
    return b;
}

// ---- the programs
enum { PLAIN, NVN, GLSL };
typedef struct {
    const char *name;
    int stage, mode;
    uint32_t omap;            // fragment: render target components written (RT0 rgba: 0xf)
    const char *expect;       // in the output (the program is translated as meant), "" none
    const char *reject;       // not in the output, NULL none
    const char *fail;         // the translation fails with this error
    void (*make)(Prog *);
    uint8_t features;         // ShaderKey.features
} Test;
#define LAS (MAXMETAL_FEAT_RSCALE | MAXMETAL_FEAT_TINT | MAXMETAL_FEAT_LAS)  // Link's Awakening's renderer

// position and one varying from vertex attributes, the position scaled by c[3][0] (user uniform block 0)
static void vs_passthrough(Prog *p) {
    emit(p, ald(0, 0x80, 4));   // r0..r3 = attribute 0
    emit(p, ald(4, 0x90, 4));   // r4..r7 = attribute 1
    for (int i = 0; i < 3; i++) emit(p, fmul_c(i, i, 3, 0));
    emit(p, ast(0, 0x70, 4));   // position
    emit(p, ast(4, 0x80, 4));   // varying 0
    emit(p, exit_());
}

static void ps_color(Prog *p) {
    emit(p, movf(0, 1.0f)); emit(p, movf(1, 0.5f)); emit(p, movf(2, 0.25f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// varying 0 .xy (perspective: times w, then 1 / w) as coordinates into texture slot 0, times varying 0 .z
static void ps_texture(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(5, 0x80, 1, 4));
    emit(p, ipa(6, 0x84, 1, 4));
    emit(p, ipa(7, 0x88, 1, 4));
    emit(p, texs2d(0, 2, 5, 6, 0));
    for (int i = 0; i < 4; i++) emit(p, fmul(i, i, 7));
    emit(p, exit_());
}

// if (v0.x > 0.5) red else blue, joined by SSY / SYNC
static void ps_branch(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(5, 0x80, 1, 4));
    int si = p->n, s = emit(p, 0);  // (SSY and BRA: their targets below)
    emit(p, fsetp_i(P0, GT, 5, 0.5f));
    int bi = p->n, b = emit(p, 0);
    emit(p, movf(0, 0.0f)); emit(p, movf(2, 1.0f));
    emit(p, sync_());
    int els = emit(p, movf(0, 1.0f)); emit(p, movf(2, 0.0f));
    emit(p, sync_());
    int join = emit(p, movf(1, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
    p->w[si] = ssy(s, join);
    p->w[bi] = at(P0, 0, bra(b, els));
}

// if (v0.x > 0.5) green else red, the else path going to the SSY target by BRA, not SYNC: the join is reached with
// the SSY entry popped and with it still on the stack (structured all the same: its edges do not depend on the stack)
static void ps_ssy_unpopped(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(5, 0x80, 1, 4));
    int si = p->n, s = emit(p, 0);
    emit(p, fsetp_i(P0, GT, 5, 0.5f));
    int bi = p->n, b = emit(p, 0);
    emit(p, movf(0, 1.0f)); emit(p, movf(1, 0.0f));
    int ji = p->n, j = emit(p, 0);  // BRA join
    int els = emit(p, movf(0, 0.0f)); emit(p, movf(1, 1.0f));
    emit(p, sync_());
    int join = emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
    p->w[si] = ssy(s, join);
    p->w[bi] = at(P0, 0, bra(b, els));
    p->w[ji] = bra(j, join);
}

// four rounds of r1 += 0.25 (a do-while loop on an integer counter)
static void ps_loop(Prog *p) {
    emit(p, mov32i(0, 0));
    emit(p, movf(1, 0.0f));
    int top = emit(p, fadd32i(1, 1, 0.25f));
    emit(p, iadd32i(0, 0, 1));
    emit(p, isetp_i(P0, LT, 0, 4));
    emit(p, at(P0, 0, bra(next_pc(p), top)));
    emit(p, movf(0, 0.0f)); emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// discard where v0.x < 0, after reading the inputs
static void ps_discard(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(0, 0x80, 1, 4));
    emit(p, fsetp_i(P0, LT, 0, 0.0f));
    emit(p, at(P0, 0, kil()));
    emit(p, movf(1, 0.0f)); emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// discard where v0.x < 0 by a branch around a KIL block (which zeroes 1 / w first), then varying 1 times 1 / w: the
// discarded path does not reach it, so 1 / w is still the one definition there and the multiply folds (Ryujinx's SSA)
static void ps_kil_fold(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(0, 0x80, 1, 4));
    emit(p, fsetp_i(P0, LT, 0, 0.0f));
    int bi = p->n, b = emit(p, 0);
    emit(p, mov_rz(4));
    emit(p, kil());
    int join = emit(p, ipa(0, 0x90, 1, 4));
    emit(p, ipa(1, 0x94, 1, 4));
    emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
    p->w[bi] = at(P0, 1, bra(b, join));
}

// r0 * r1 + r2 as the compiler writes a 32-bit multiply, the MRG part over b's register: one multiply of the values the
// first part read (Ryujinx's XmadOptimizer)
static void ps_xmad_mul(Prog *p) {
    emit(p, mov32i(0, 123456789u)); emit(p, mov32i(1, 987654321u)); emit(p, mov32i(2, 5));
    emit(p, xmad(3, 0, 0, 1, 0, 2, 0, 0, 0));      // t = r0.lo * r1.lo + r2
    emit(p, xmad(1, 0, 0, 1, 1, RZ, 0, 1, 0));     // u = MRG r0.lo * r1.hi (into r1)
    emit(p, xmad(0, 0, 1, 1, 1, 3, 1, 0, 4));      // r0 = PSL.CBCC r0.hi * u.hi + t
    emit(p, movf(1, 0.0f)); emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// SR_THREAD_KILL: whether the invocation is a helper (as on entry), as colour
static void ps_helper(Prog *p) {
    emit(p, s2r(0, 0x13));
    emit(p, movf(1, 0.0f)); emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// -int(0): the negation is the integer's (+0, never -0)
static void ps_i2f_neg(Prog *p) {
    emit(p, mov32i(0, 0));
    emit(p, i2f_neg(0, 0));
    emit(p, movf(1, 0.0f)); emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

// each thread stores its id to shared memory; after the barrier, its neighbour's value + the input word at storage
// slot 0 (c0[0x310]: address, c0[0x318]: size) goes to slot 1 at the thread's index
static void cs_shared_global(Prog *p) {
    emit(p, s2r(0, SR_TID_X));
    emit(p, shl_i(1, 0, 2));
    emit(p, sts(0, 1, 0));
    emit(p, bar());
    emit(p, lds(2, 1, 4));
    emit(p, ldc(4, 0, 0x310, 1));
    emit(p, ldg(3, 4, 0));
    emit(p, fadd(2, 2, 3));
    emit(p, ldc(6, 0, 0x320, 1));
    emit(p, iadd_cc(6, 6, 1));
    emit(p, iadd_x(7, 7, RZ));
    emit(p, stg(2, 6, 0));
    emit(p, exit_());
}

// fragment math: ffma, constant buffer operand
static void ps_ffma(Prog *p) {
    emit(p, ipa(4, 0x7c, 0, RZ));
    emit(p, mufu_rcp(4, 4));
    emit(p, ipa(0, 0x80, 1, 4));
    emit(p, ipa(1, 0x84, 1, 4));
    emit(p, ffma(0, 0, 1, 0));
    emit(p, fmul_c(1, 1, 3, 4));
    emit(p, movf(2, 0.0f)); emit(p, movf(3, 1.0f));
    emit(p, exit_());
}

static void bad_insn(Prog *p) {
    emit(p, 0xfff8000000000000ull);
    emit(p, exit_());
}

static const Test tests[] = {
    {"vs_passthrough", STAGE_VERTEX, NVN, 0, "[[position", NULL, NULL, vs_passthrough, 0},
    {"ps_color", STAGE_FRAGMENT, NVN, 0xf, "[[color(0)]]", NULL, NULL, ps_color, 0},
    {"ps_texture", STAGE_FRAGMENT, NVN, 0xf, ".sample(", NULL, NULL, ps_texture, 0},
    {"ps_branch", STAGE_FRAGMENT, NVN, 0xf, "if (", "switch (pc)", NULL, ps_branch, 0},
    {"ps_loop", STAGE_FRAGMENT, NVN, 0xf, "while (", "switch (pc)", NULL, ps_loop, 0},
    {"ps_ssy_unpopped", STAGE_FRAGMENT, NVN, 0xf, "if (", "switch (pc)", NULL, ps_ssy_unpopped, 0},
    {"ps_discard", STAGE_FRAGMENT, NVN, 0xf, "discard_fragment()", NULL, NULL, ps_discard, 0},
    {"ps_ffma", STAGE_FRAGMENT, NVN, 0xf, "fma(", NULL, NULL, ps_ffma, 0},
    {"ps_kil_fold", STAGE_FRAGMENT, NVN, 0xf, "as_type<uint>(in.v1[0]);", "gl_FragCoord.w * as_type<float>", NULL, ps_kil_fold, 0},
    {"ps_i2f_neg", STAGE_FRAGMENT, NVN, 0xf, "float((-int(r0)))", "(-float(", NULL, ps_i2f_neg, 0},
    {"ps_helper", STAGE_FRAGMENT, NVN, 0xf, "simd_is_helper_thread()", NULL, NULL, ps_helper, 0},
    {"ps_xmad_mul", STAGE_FRAGMENT, NVN, 0xf, "r0 = ((xs0 * xs1) + xs2);", NULL, NULL, ps_xmad_mul, 0},
    {"cs_shared_global", STAGE_COMPUTE, NVN, 0, "MAXMETAL_GAT(ga, s0)", NULL, NULL, cs_shared_global, 0},
    {"ps_texture_plain", STAGE_FRAGMENT, PLAIN, 0xf, ".sample(", "rscale", NULL, ps_texture, 0},
    {"ps_branch_plain", STAGE_FRAGMENT, PLAIN, 0xf, "switch (pc)", "ltint", NULL, ps_branch, 0},
    {"ps_texture_las", STAGE_FRAGMENT, PLAIN, 0xf, "ltint", NULL, NULL, ps_texture, LAS},
    {"vs_passthrough_glsl", STAGE_VERTEX, GLSL, 0, "gl_Position", NULL, NULL, vs_passthrough, 0},
    {"ps_texture_glsl", STAGE_FRAGMENT, GLSL, 0xf, "texture(", "rscale", NULL, ps_texture, 0},
    {"ps_texture_las_glsl", STAGE_FRAGMENT, GLSL, 0xf, "rscale", NULL, NULL, ps_texture, LAS},
    {"bad_insn", STAGE_FRAGMENT, NVN, 0xf, NULL, NULL, "unknown instruction", bad_insn, 0},
};

// ---- the runner
static char *read_text(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = calloc(1, (size_t)n + 1);
    if (fread(s, 1, (size_t)n, f) != (size_t)n) { free(s); s = NULL; }
    fclose(f);
    return s;
}

static int write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    fputs(text, f);
    return fclose(f) == 0;
}

// text against <dir>/<name><ext>: 1 same (or written, with update), 0 not
static int check(const char *dir, const char *name, const char *ext, const char *text, int update) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s%s", dir, name, ext);
    if (update) return write_text(path, text) ? 1 : (printf("  cannot write %s\n", path), 0);
    char *want = read_text(path);
    if (!want) { printf("  no expected output %s (MAXMETAL_UPDATE_GOLDEN=1 writes it)\n", path); return 0; }
    int same = !strcmp(want, text);
    if (!same) {  // the first differing line
        int line = 1;
        const char *a = want, *b = text;
        while (*a && *a == *b) { if (*a == '\n') line++; a++; b++; }
        while (a > want && a[-1] != '\n') { a--; b--; }  // from the line's start
        printf("  %s%s differs from line %d:\n    expected: %.*s\n    got:      %.*s\n", name, ext, line,
               (int)strcspn(a, "\n"), a, (int)strcspn(b, "\n"), b);
    }
    free(want);
    return same;
}

static int run(const Test *t, const char *golden, const char *out, int update) {
    Prog p = {0};
    t->make(&p);
    size_t size;
    uint8_t *blob = build(&p, t->stage, t->omap, &size);
    NvnKey nk;
    memset(&nk, 0, sizeof nk);
    memset(nk.tex_type, -1, sizeof nk.tex_type);
    nk.tex_type[0] = TEXTYPE_2D;
    nk.local[0] = 64; nk.local[1] = 1; nk.local[2] = 1;
    ShaderKey key;
    memset(&key, 0, sizeof key);
    key.glsl = t->mode == GLSL;
    key.features = t->features;
    if (t->mode == NVN) key.nvn = &nk;
    else key.vs_out_mask = 0xffffffffu;  // (NVN: the reflection names the varyings instead)
    ShaderInfo *si = maxwell_translate(blob, size, t->stage, &key);
    free(blob);
    int ok = 1;
    if (t->fail) {
        if (si->msl) { printf("  translated; expected the error \"%s\"\n", t->fail); ok = 0; }
        else if (!strstr(si->error, t->fail)) { printf("  error \"%s\"; expected \"%s\"\n", si->error, t->fail); ok = 0; }
        maxwell_free(si);
        return ok;
    }
    if (!si->msl) { printf("  translation failed: %s\n", si->error); maxwell_free(si); return 0; }
    if (t->expect && !strstr(si->msl, t->expect)) { printf("  no \"%s\" in the output\n", t->expect); ok = 0; }
    if (t->reject && strstr(si->msl, t->reject)) { printf("  \"%s\" in the output\n", t->reject); ok = 0; }
    const char *ext = t->mode == GLSL ? ".glsl" : ".metal";
    ok &= check(golden, t->name, ext, si->msl, update);
    if (si->refl) ok &= check(golden, t->name, ".json", si->refl, update);
    char path[4096];
    snprintf(path, sizeof path, "%s/%s%s", out, t->name, ext);
    if (!write_text(path, si->msl)) { printf("  cannot write %s\n", path); ok = 0; }
    maxwell_free(si);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: test_translate <golden dir> <out dir> [test name...]\n"); return 2; }
    int update = getenv("MAXMETAL_UPDATE_GOLDEN") && atoi(getenv("MAXMETAL_UPDATE_GOLDEN"));
    int failed = 0, ran = 0;
    for (size_t i = 0; i < sizeof tests / sizeof tests[0]; i++) {
        const Test *t = &tests[i];
        int want = argc == 3;
        for (int a = 3; a < argc; a++) want |= !strcmp(argv[a], t->name);
        if (!want) continue;
        ran++;
        printf("%s\n", t->name);
        if (!run(t, argv[1], argv[2], update)) { failed++; printf("FAIL %s\n", t->name); }
    }
    printf("%d of %d passed%s\n", ran - failed, ran, update ? " (expected outputs written)" : "");
    return failed ? 1 : 0;
}

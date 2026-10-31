// maxmetal: the command-line front end of the Maxwell -> MSL translator (libmaxmetal).
//   maxmetal translate [--glsl] [--features N] <vs|ps|cs> <code> [-o <out>]
//                                                              one shader's MSL (GLSL) on stdout or in <out>
//   maxmetal probe [--all] [--features N] <out dir> <vs|ps|cs> <code>...
//                                                              translate many: <out dir>/<name>.metal each,
//                                                              "ok <name> <insts>" or "fail <name> <error>"
//   maxmetal service --out <dir> --chain <name>                the NVN translation service
//   maxmetal request <request.json> --out <dir> --chain <name> one service request, the reply on stdout
// <code>: a shader cache code file - graphics code from the SPH on, compute code after its 0x100-byte header.
// translate / probe use the translator's own binding contract (--features: ShaderKey.features, MAXMETAL_FEAT_* summed);
// service / request the NVN one (ShaderKey.nvn).
//
// The service has the Ryujinx + SPIRV-Cross translation service's protocol and files: one JSON request per line on
// stdin, one reply line {"ok": true} or {"ok": false, "error": "..."} on stdout, and <out>/<variant>_b.metal +
// <variant>_b.json.
// Request: {"variant", "stage": "vs|ps|cs", "code": path, "c1": hex, "tex": {slot: type}, "img": {...}, "attr": {...},
//           "fout": {...}, "local": [x, y, z], "depth_minus_w": bool, "early_fragment_tests": bool,
//           "hw_layer_clamp": bool}
// That service's arguments (maxmetal --service --spirv-cross <path> --out <dir> --chain <name>, or --one <file>) work too:
// a renderer can start maxmetal in its place.
#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "maxmetal/maxmetal.h"

// ---- a small JSON reader: enough for the requests (objects, arrays, strings, numbers, true / false / null)
typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } JType;
typedef struct J {
    JType t;
    double num;
    bool b;
    char *str;             // J_STR
    struct J *items;       // J_ARR / J_OBJ values
    char **keys;           // J_OBJ keys
    int n;
} J;

static const char *jws(const char *p) { while (*p && isspace((unsigned char)*p)) p++; return p; }

static const char *jstr(const char *p, char **out) {  // p at the opening quote
    size_t cap = 16, n = 0;
    char *s = malloc(cap);
    for (p++; *p && *p != '"'; p++) {
        char ch = *p;
        if (ch == '\\') {
            p++;
            switch (*p) {
            case 'n': ch = '\n'; break;
            case 't': ch = '\t'; break;
            case 'r': ch = '\r'; break;
            case 'b': ch = '\b'; break;
            case 'f': ch = '\f'; break;
            case 'u': ch = '?'; p += 4; break;  // (no request carries escaped code points)
            default: ch = *p;
            }
        }
        if (n + 2 > cap) s = realloc(s, cap *= 2);
        s[n++] = ch;
    }
    s[n] = 0;
    *out = s;
    return *p == '"' ? p + 1 : NULL;
}

static const char *jparse(const char *p, J *v) {
    memset(v, 0, sizeof *v);
    p = jws(p);
    if (*p == '{' || *p == '[') {
        bool obj = *p == '{';
        v->t = obj ? J_OBJ : J_ARR;
        int cap = 0;
        p = jws(p + 1);
        if (*p == (obj ? '}' : ']')) return p + 1;
        for (;;) {
            if (v->n == cap) {
                cap = cap ? cap * 2 : 8;
                v->items = realloc(v->items, cap * sizeof *v->items);
                if (obj) v->keys = realloc(v->keys, cap * sizeof *v->keys);
            }
            if (obj) {
                p = jws(p);
                if (*p != '"' || !(p = jstr(p, &v->keys[v->n]))) return NULL;
                p = jws(p);
                if (*p++ != ':') return NULL;
            }
            if (!(p = jparse(p, &v->items[v->n++]))) return NULL;
            p = jws(p);
            if (*p == ',') { p++; continue; }
            if (*p == (obj ? '}' : ']')) return p + 1;
            return NULL;
        }
    }
    if (*p == '"') { v->t = J_STR; return jstr(p, &v->str); }
    if (!strncmp(p, "true", 4)) { v->t = J_BOOL; v->b = true; return p + 4; }
    if (!strncmp(p, "false", 5)) { v->t = J_BOOL; return p + 5; }
    if (!strncmp(p, "null", 4)) return p + 4;
    char *e;
    v->num = strtod(p, &e);
    if (e == p) return NULL;
    v->t = J_NUM;
    return e;
}

static void jfree(J *v) {
    for (int i = 0; i < v->n; i++) { jfree(&v->items[i]); if (v->keys) free(v->keys[i]); }
    free(v->items); free(v->keys); free(v->str);
}

static const J *jget(const J *o, const char *k) {
    if (!o || o->t != J_OBJ) return NULL;
    for (int i = 0; i < o->n; i++) if (!strcmp(o->keys[i], k)) return &o->items[i];
    return NULL;
}
static bool jtruthy(const J *v) {
    return v && ((v->t == J_BOOL && v->b) || (v->t == J_NUM && v->num != 0) || (v->t == J_STR && v->str[0]) ||
                 ((v->t == J_ARR || v->t == J_OBJ) && v->n));
}

// JSON string literal of s (as Python's json.dumps with ensure_ascii; JSON readers take either form)
static void jput_str(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') fprintf(f, "\\%c", ch);
        else if (ch == '\n') fputs("\\n", f);
        else if (ch < 0x20 || ch > 0x7e) fprintf(f, "\\u%04x", ch);
        else fputc(ch, f);
    }
    fputc('"', f);
}

// ---- translation
static const char *g_out, *g_chain;

static int tex_type_of(const char *s, bool *depth) {
    size_t n = strlen(s);
    *depth = n > 6 && !strcmp(s + n - 6, "_depth");
    char b[32];
    snprintf(b, sizeof b, "%.*s", (int)(*depth ? n - 6 : n), s);
    if (!strcmp(b, "1d")) return TEXTYPE_1D;
    if (!strcmp(b, "1darray")) return TEXTYPE_1D_ARRAY;
    if (!strcmp(b, "2darray")) return TEXTYPE_2D_ARRAY;
    if (!strcmp(b, "3d")) return TEXTYPE_3D;
    if (!strcmp(b, "cube")) return TEXTYPE_CUBE;
    if (!strcmp(b, "cubearray")) return TEXTYPE_CUBE_ARRAY;
    if (!strcmp(b, "2d")) return TEXTYPE_2D;
    return -1;  // (buffer / multisample textures: the lookup decides, or the translation fails)
}

static uint8_t *read_all(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = calloc(1, (size_t)n + 0x30 + 64);
    if (fread(b + 0x30, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
    fclose(f);
    *size = (size_t)n + 0x30;
    return b;
}

static bool write_text(const char *dir, const char *name, const char *suffix, const char *text) {
    char path[4096], tmp[4200];
    snprintf(path, sizeof path, "%s/%s%s", dir, name, suffix);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return false;
    fputs(text, f);
    if (fclose(f)) return false;
    return rename(tmp, path) == 0;
}

// Handles one request: 0, or the error text in err.
static int handle(const J *rq, char *err, size_t errlen) {
    const J *jv = jget(rq, "variant"), *js = jget(rq, "stage"), *jc = jget(rq, "code");
    if (!jv || jv->t != J_STR || !js || js->t != J_STR || !jc || jc->t != J_STR) { snprintf(err, errlen, "request without variant / stage / code"); return 1; }
    const char *variant = jv->str, *st = js->str;
    int stage = !strcmp(st, "vs") ? STAGE_VERTEX : !strcmp(st, "ps") ? STAGE_FRAGMENT : !strcmp(st, "cs") ? STAGE_COMPUTE : -1;
    if (stage < 0) { snprintf(err, errlen, "stage %s not supported by the translation chain", st); return 1; }
    const J *local = jget(rq, "local");
    if (stage == STAGE_COMPUTE && !jtruthy(local)) { snprintf(err, errlen, "compute shader without thread group size"); return 1; }
    NvnKey nk;
    memset(&nk, 0, sizeof nk);
    memset(nk.tex_type, -1, sizeof nk.tex_type);
    const J *tex = jget(rq, "tex");
    for (int i = 0; tex && tex->t == J_OBJ && i < tex->n; i++) {
        int slot = atoi(tex->keys[i]);
        const J *v = &tex->items[i];
        const char *ts = v->t == J_STR ? v->str : v->t == J_OBJ && jget(v, "type") && jget(v, "type")->t == J_STR ? jget(v, "type")->str : NULL;
        if (slot < 0 || slot >= 128 || !ts) continue;
        bool depth;
        nk.tex_type[slot] = (int8_t)tex_type_of(ts, &depth);
        nk.tex_depth[slot] = depth;
    }
    nk.early_fragment_tests = jtruthy(jget(rq, "early_fragment_tests"));
    nk.depth_minus_w = jtruthy(jget(rq, "depth_minus_w"));
    nk.hw_layer_clamp = jtruthy(jget(rq, "hw_layer_clamp"));
    for (int i = 0; local && local->t == J_ARR && i < local->n && i < 3; i++) nk.local[i] = (uint32_t)local->items[i].num;
    // c1 (hex): the program's constants, for BRX jump tables
    const J *c1h = jget(rq, "c1");
    uint8_t c1b[0x10000];
    if (c1h && c1h->t == J_STR) {
        size_t n = strlen(c1h->str) / 2;
        for (size_t i = 0; i < n && i < sizeof c1b; i++) {
            unsigned v;
            if (sscanf(c1h->str + 2 * i, "%2x", &v) != 1) { n = i; break; }
            c1b[i] = (uint8_t)v;
        }
        if (n) { nk.c1 = c1b; nk.c1_size = (uint32_t)(n < sizeof c1b ? n : sizeof c1b); }
    }
    size_t size;
    uint8_t *blob = read_all(jc->str, &size);
    if (!blob) { snprintf(err, errlen, "cannot read %s", jc->str); return 1; }
    // The shader cache holds graphics code from the SPH on (the translator wants the 0x30-byte NVN header before it) and
    // compute code with its header: the instructions start at +0x100, the words before them zero.
    const uint8_t *code = blob;
    size_t code_size = size;
    if (stage != STAGE_COMPUTE) {
        // the SPH's shader type decides the stage, as Ryujinx's ShaderHeader.Stage (a real game's "ps" request can be a vertex
        // program); the request's label is only echoed in the reflection
        uint32_t type = size >= 0x34 ? (*(const uint32_t *)(blob + 0x30) >> 10) & 0xf : 0;
        if (type != 1 && type != 5) { free(blob); snprintf(err, errlen, "SPH shader type %u not supported", type); return 1; }
        stage = type == 1 ? STAGE_VERTEX : STAGE_FRAGMENT;
    }
    if (stage == STAGE_COMPUTE) {
        for (size_t i = 0x30 + 8; i < 0x30 + 0x100 && i < size; i++)
            if (blob[i]) { free(blob); snprintf(err, errlen, "compute code: header not as expected (byte %#zx)", i - 0x30); return 1; }
        code = blob + 0x30 + 0x100;
        code_size = size - 0x30 - 0x100;
    }
    ShaderKey key;
    memset(&key, 0, sizeof key);
    key.nvn = &nk;
    ShaderInfo *si = maxwell_translate(code, code_size, stage, &key);
    free(blob);
    if (!si->msl || !si->refl) { snprintf(err, errlen, "maxmetal: %s", si->error[0] ? si->error : "no output"); maxwell_free(si); return 1; }
    char name[600];
    snprintf(name, sizeof name, "%s_b", variant);
    if (!write_text(g_out, name, ".metal", si->msl)) { snprintf(err, errlen, "cannot write %s/%s.metal", g_out, name); maxwell_free(si); return 1; }
    // the reflection: the request's fields around the translator's (key order as the Ryujinx path's service)
    char *jtext = NULL;
    size_t jlen = 0;
    FILE *f = open_memstream(&jtext, &jlen);
    const J *c1 = jget(rq, "c1");
    fprintf(f, "{\"key\": ");
    jput_str(f, name);
    fprintf(f, ", \"route\": \"B\", \"chain\": ");
    jput_str(f, g_chain);
    fprintf(f, ", \"stage\": \"%s\", \"entry\": \"main0\", \"msl_entry_kind\": \"%s\", \"threadgroup_size\": ", st,
            stage == STAGE_VERTEX ? "vertex" : stage == STAGE_FRAGMENT ? "fragment" : "kernel");
    if (stage == STAGE_COMPUTE) fprintf(f, "[%u, %u, %u]", nk.local[0], nk.local[1], nk.local[2]);
    else fprintf(f, "null");
    fprintf(f, ", \"c1\": ");
    jput_str(f, c1 && c1->t == J_STR ? c1->str : "");
    fprintf(f, ", \"notes\": [], %s, \"raster\": {}, \"softfloat64\": false, \"translator\": \"maxmetal\"}\n", si->refl);
    fclose(f);
    bool ok = write_text(g_out, name, ".json", jtext);
    free(jtext);
    maxwell_free(si);
    if (!ok) { snprintf(err, errlen, "cannot write %s/%s.json", g_out, name); return 1; }
    return 0;
}

static void reply(int rc, const char *err) {
    if (!rc) { fputs("{\"ok\": true}\n", stdout); }
    else {
        char e[600];
        snprintf(e, sizeof e, "RuntimeError: %s", err);
        fputs("{\"ok\": false, \"error\": ", stdout);
        jput_str(stdout, e);
        fputs("}\n", stdout);
    }
    fflush(stdout);
}

static int run_line(const char *line) {
    J rq;
    char err[512] = "";
    const char *e = jparse(line, &rq);
    int rc;
    if (!e || rq.t != J_OBJ) { snprintf(err, sizeof err, "request is not a JSON object"); rc = 1; }
    else rc = handle(&rq, err, sizeof err);
    jfree(&rq);
    reply(rc, err);
    return rc;
}

static int usage(FILE *f) {
    fputs("usage: maxmetal translate [--glsl] [--features N] <vs|ps|cs> <code> [-o <out>]\n"
          "       maxmetal probe [--all] [--features N] <out dir> <vs|ps|cs> <code>...\n"
          "       maxmetal service --out <dir> --chain <name>\n"
          "       maxmetal request <request.json> --out <dir> --chain <name>\n"
          "<code>: a shader cache code file (graphics code from the SPH on, compute code after its 0x100-byte header)\n"
          "N: ShaderKey.features (1 resolution scale, 2 tint, 4 Link's Awakening patches; 7 all)\n", f);
    return 2;
}

// service / request (and the Ryujinx path service's arguments)
static int cmd_service(int argc, char **argv, bool service, const char *one) {
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--service")) service = true;
        else if (!strcmp(argv[i], "--one") && i + 1 < argc) one = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) g_out = argv[++i];
        else if (!strcmp(argv[i], "--chain") && i + 1 < argc) g_chain = argv[++i];
        else if (!strcmp(argv[i], "--spirv-cross") && i + 1 < argc) i++;  // (the Ryujinx path's; ignored)
        else if (!strcmp(argv[i], "--debug-mode") && i + 1 < argc) i++;
        else { fprintf(stderr, "maxmetal: unknown argument %s\n", argv[i]); return 2; }
    }
    if ((!service && !one) || !g_out || !g_chain) return usage(stderr);
    if (one) {
        size_t n;
        uint8_t *b = read_all(one, &n);
        if (!b) { fprintf(stderr, "cannot read %s\n", one); return 2; }
        int rc = run_line((const char *)b + 0x30);
        free(b);
        return rc;
    }
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    while ((len = getline(&line, &cap, stdin)) >= 0) {
        const char *p = jws(line);
        if (!*p) continue;
        run_line(p);
    }
    free(line);
    return 0;
}

// ---- translate / probe: code files in the translator's own binding contract
static int stage_of(const char *s) {
    return !strcmp(s, "vs") ? STAGE_VERTEX : !strcmp(s, "ps") ? STAGE_FRAGMENT : !strcmp(s, "cs") ? STAGE_COMPUTE : -1;
}

// The code file's shader translated, or NULL with the error in err.
static ShaderInfo *translate_file(const char *path, int stage, bool glsl, uint8_t features, char *err, size_t errlen) {
    size_t size;
    uint8_t *blob = read_all(path, &size);
    if (!blob) { snprintf(err, errlen, "unreadable"); return NULL; }
    if (stage == STAGE_COMPUTE && size < 0x30 + 0x100) { free(blob); snprintf(err, errlen, "compute code shorter than its header"); return NULL; }
    // the translator wants the 0x30-byte NVN header in front of graphics code and nothing in front of compute code
    const uint8_t *code = stage == STAGE_COMPUTE ? blob + 0x30 + 0x100 : blob;
    size_t code_size = stage == STAGE_COMPUTE ? size - 0x30 - 0x100 : size;
    ShaderKey key = {0};
    key.vs_out_mask = 0xffffffffu;
    key.glsl = glsl;
    key.features = features;
    ShaderInfo *si = maxwell_translate(code, code_size, stage, &key);
    free(blob);
    return si;
}

static int cmd_translate(int argc, char **argv) {
    const char *out = NULL, *st = NULL, *path = NULL;
    bool glsl = false;
    uint8_t features = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--glsl")) glsl = true;
        else if (!strcmp(argv[i], "--features") && i + 1 < argc) features = (uint8_t)strtoul(argv[++i], NULL, 0);
        else if (!st) st = argv[i];
        else if (!path) path = argv[i];
        else return usage(stderr);
    }
    int stage = st ? stage_of(st) : -1;
    if (stage < 0 || !path) return usage(stderr);
    char err[256];
    ShaderInfo *si = translate_file(path, stage, glsl, features, err, sizeof err);
    if (!si || !si->msl) { fprintf(stderr, "maxmetal: %s: %s\n", path, si ? si->error : err); maxwell_free(si); return 1; }
    FILE *f = out ? fopen(out, "w") : stdout;
    bool ok = f && fputs(si->msl, f) >= 0;
    if (out && f && fclose(f)) ok = false;
    maxwell_free(si);
    if (!ok) { fprintf(stderr, "maxmetal: cannot write %s\n", out ? out : "stdout"); return 1; }
    return 0;
}

static void probe_fail(const char *msg) { printf("unk %s\n", msg); }

static int cmd_probe(int argc, char **argv) {
    int a = 0;
    uint8_t features = 0;
    for (; a < argc && !strncmp(argv[a], "--", 2); a++) {
        if (!strcmp(argv[a], "--all")) maxwell_probe_fail = probe_fail;  // every failure, not just the first
        else if (!strcmp(argv[a], "--features") && a + 1 < argc) features = (uint8_t)strtoul(argv[++a], NULL, 0);
        else return usage(stderr);
    }
    if (argc - a < 3 || stage_of(argv[a + 1]) < 0) return usage(stderr);
    const char *out = argv[a];
    int stage = stage_of(argv[a + 1]);
    for (int i = a + 2; i < argc; i++) {
        const char *name = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
        if (maxwell_probe_fail) { printf("> %s\n", name); fflush(stdout); }
        char err[256];
        ShaderInfo *si = translate_file(argv[i], stage, false, features, err, sizeof err);
        if (!si || !si->msl) {
            printf("fail %s %s\n", name, si ? si->error : err);
        } else {
            const char *dot = strrchr(name, '.');
            char path[4096];
            snprintf(path, sizeof path, "%s/%.*s.metal", out, (int)(dot ? (size_t)(dot - name) : strlen(name)), name);
            FILE *f = fopen(path, "w");
            if (f) { fputs(si->msl, f); fclose(f); }
            printf("ok %s %u\n", name, si->num_insts);
        }
        maxwell_free(si);
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "";
    if (!strcmp(cmd, "translate")) return cmd_translate(argc - 2, argv + 2);
    if (!strcmp(cmd, "probe")) return cmd_probe(argc - 2, argv + 2);
    if (!strcmp(cmd, "service")) return cmd_service(argc - 2, argv + 2, true, NULL);
    if (!strcmp(cmd, "request") && argc > 2) return cmd_service(argc - 3, argv + 3, false, argv[2]);
    if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "help")) { usage(stdout); return 0; }
    if (!strncmp(cmd, "--", 2)) return cmd_service(argc - 1, argv + 1, false, NULL);  // the Ryujinx path service's arguments
    return usage(stderr);
}

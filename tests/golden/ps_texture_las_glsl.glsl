#version 460
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_shuffle : require
#extension GL_KHR_shader_subgroup_shuffle_relative : require
#extension GL_EXT_texture_shadow_lod : require
#define cbr(cb, off) cb[min((off) >> 4, uint(cb.length() - 1))][((off) >> 2) & 3u]
uint as_u(float x) { return floatBitsToUint(x); }
uint as_u(uint x) { return x; }
uint as_u(int x) { return uint(x); }
float as_f(uint x) { return uintBitsToFloat(x); }
float as_f(int x) { return intBitsToFloat(x); }
float as_f(float x) { return x; }
int as_i(uint x) { return int(x); }
int as_i(float x) { return floatBitsToInt(x); }
int sx8(uint v) { return bitfieldExtract(int(v), 0, 8); }
int sx8(int v) { return bitfieldExtract(v, 0, 8); }
int sx16(uint v) { return bitfieldExtract(int(v), 0, 16); }
int sx16(int v) { return bitfieldExtract(v, 0, 16); }
float saturate(float x) { return isnan(x) ? 0.0f : clamp(x, 0.0f, 1.0f); }
vec2 saturate(vec2 x) { return vec2(saturate(x.x), saturate(x.y)); }
float fmin(float a, float b) { return isnan(a) ? b : (isnan(b) ? a : min(a, b)); }
float fmax(float a, float b) { return isnan(a) ? b : (isnan(b) ? a : max(a, b)); }
uint clz(uint v) { return v == 0u ? 32u : uint(31 - findMSB(v)); }
uint popcount(uint v) { return uint(bitCount(v)); }
uint mulhi(uint a, uint b) { uint hi, lo; umulExtended(a, b, hi, lo); return hi; }
int mulhi(int a, int b) { int hi, lo; imulExtended(a, b, hi, lo); return hi; }
uint bfe_u(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return 0u; return bitfieldExtract(v, int(pos), int(min(len, 32u - pos))); }
uint bfe_s(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return (int(v) < 0) ? 0xFFFFFFFFu : 0u; return uint(bitfieldExtract(int(v), int(pos), int(min(len, 32u - pos)))); }
uint bfi(uint ins, uint ctl, uint base) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u || pos >= 32u) return base; return bitfieldInsert(base, ins, int(pos), int(min(len, 32u - pos))); }
float fswzadd(float a, float b, uint swz, uint lane) { uint m = (swz >> ((lane & 3u) * 2u)) & 3u; float ma = m == 1u ? -1.0f : (m == 3u ? 0.0f : 1.0f); float mb = m == 2u ? -1.0f : 1.0f; return a * ma + b * mb; }
uvec2 rsc(uvec2 c, vec4 s) { return (s.x == 1.0f && s.y == 1.0f) ? c : uvec2(floor((vec2(c) + 0.5f) * s.xy)); }
vec2 uvs(vec2 uv, vec4 s) { return (s.z == 1.0f && s.w == 1.0f) ? uv : min(uv, 1.0f) * s.zw; }
float h2f(uint h) { return unpackHalf2x16(h).x; }
vec2 unpack_h2(uint v) { return unpackHalf2x16(v); }
vec2 hx(uint v, uint swz) { if (swz == 1u) return vec2(uintBitsToFloat(v)); vec2 h = unpack_h2(v); return swz == 2u ? h.xx : (swz == 3u ? h.yy : h); }
uint hpack(vec2 r, uint merge, uint old) { if (merge == 1u) return floatBitsToUint(r.x); uint lo = packHalf2x16(vec2(r.x, 0.0f)), hi = packHalf2x16(vec2(r.y, 0.0f)); if (merge == 2u) return (old & 0xFFFF0000u) | lo; if (merge == 3u) return (old & 0xFFFFu) | (hi << 16); return lo | (hi << 16); }
uint prmt(uint a, uint b, uint sel) { uint r = 0u; for (uint i = 0u; i < 4u; i++) { uint s = (sel >> (i * 4u)) & 7u; uint bt = s < 4u ? (a >> (s * 8u)) & 0xFFu : (b >> ((s - 4u) * 8u)) & 0xFFu; r |= bt << (i * 8u); } return r; }
layout(std140, set = 1, binding = 18) uniform RScale { vec4 rscale[65]; };
layout(std140, set = 1, binding = 19) uniform Tint { vec4 ltint[4]; };
layout(set = 1, binding = 32) uniform sampler2D t0;
ivec3 tsize0(int l) { return ivec3(textureSize(t0, l), 1); }
layout(location = 0) in vec4 v0;
layout(location = 0) out vec4 c0;
void main() {
  uint r0 = 0u;
  uint r1 = 0u;
  uint r2 = 0u;
  uint r3 = 0u;
  uint r4 = 0u;
  uint r5 = 0u;
  uint r6 = 0u;
  uint r7 = 0u;
  do {
    r4 = as_u(gl_FragCoord[3]);
    r4 = as_u((1.0f / as_f(r4)));
    r5 = as_u(v0[0] * gl_FragCoord.w * as_f(r4));
    r6 = as_u(v0[1] * gl_FragCoord.w * as_f(r4));
    r7 = as_u(v0[2] * gl_FragCoord.w * as_f(r4));
    { vec4 t = texture(t0, uvs(vec2(as_f(r5), as_f(r6)), rscale[1]));
      r0 = as_u(t[0]);
      r1 = as_u(t[1]);
      r2 = as_u(t[2]);
      r3 = as_u(t[3]);
    }
    r0 = as_u((as_f(r0) * as_f(r7)));
    r1 = as_u((as_f(r1) * as_f(r7)));
    r2 = as_u((as_f(r2) * as_f(r7)));
    r3 = as_u((as_f(r3) * as_f(r7)));
    break;
  } while (false);
  c0[0] = as_f(r0);
  c0[1] = as_f(r1);
  c0[2] = as_f(r2);
  c0[3] = as_f(r3);
  if (ltint[0].w > 0.0f) { vec3 g = c0.rgb; float l = dot(g, vec3(0.299f, 0.587f, 0.114f));
    c0.rgb = mix(g, ltint[0].rgb * pow(l, ltint[1].w) + ltint[1].rgb * l, ltint[0].w); }
  else if (ltint[0].w < 0.0f) {
    vec3 rc_g = pow(max(c0.rgb, vec3(0.0f)), vec3(1.0f / 2.2f));
    vec4 rc_K = vec4(0.0f, -1.0f / 3.0f, 2.0f / 3.0f, -1.0f);
    vec4 rc_p = mix(vec4(rc_g.b, rc_g.g, rc_K.w, rc_K.z), vec4(rc_g.g, rc_g.b, rc_K.x, rc_K.y), vec4(step(rc_g.b, rc_g.g)));
    vec4 rc_q = mix(vec4(rc_p.x, rc_p.y, rc_p.w, rc_g.r), vec4(rc_g.r, rc_p.y, rc_p.z, rc_p.x), vec4(step(rc_p.x, rc_g.r)));
    float rc_d = rc_q.x - min(rc_q.w, rc_q.y);
    float rc_hh0 = abs(rc_q.z + (rc_q.w - rc_q.y) / (6.0f * rc_d + 1e-6f)), rc_ss0 = rc_d / (rc_q.x + 1e-6f), rc_vv0 = rc_q.x;
    float rc_sd0 = fract(rc_hh0 - ltint[1].x + 0.5f) - 0.5f, rc_dh0 = abs(rc_sd0);
    float rc_m = (ltint[1].y >= 0.5f ? 1.0f : 1.0f - smoothstep(ltint[1].y * 0.6f, ltint[1].y, rc_dh0)) *
              smoothstep(ltint[1].z * 0.5f, ltint[1].z + 1e-4f, rc_ss0);
    float rc_hh1 = fract(ltint[1].x + ltint[0].x + rc_sd0 * ltint[1].w), rc_ss1 = clamp(rc_ss0 * ltint[0].y, 0.0f, 1.0f);
    float rc_vv1 = min(rc_vv0 * ltint[0].z, max(rc_vv0, 1.0f));
    vec3 rc_k0 = clamp(abs(fract(vec3(rc_hh1) + vec3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f)) * 6.0f - vec3(3.0f)) - vec3(1.0f), vec3(0.0f), vec3(1.0f));
    vec3 rc_r = pow(rc_vv1 * mix(vec3(1.0f), rc_k0, vec3(rc_ss1)), vec3(2.2f));
    if (ltint[2].w < 0.0f) {
    float rc_sd2 = fract(rc_hh0 - ltint[3].x + 0.5f) - 0.5f, rc_dh2 = abs(rc_sd2);
    float rc_m2 = (ltint[3].y >= 0.5f ? 1.0f : 1.0f - smoothstep(ltint[3].y * 0.6f, ltint[3].y, rc_dh2)) *
              smoothstep(ltint[3].z * 0.5f, ltint[3].z + 1e-4f, rc_ss0);
    float rc_hh3 = fract(ltint[3].x + ltint[2].x + rc_sd2 * ltint[3].w), rc_ss3 = clamp(rc_ss0 * ltint[2].y, 0.0f, 1.0f);
    float rc_vv3 = min(rc_vv0 * ltint[2].z, max(rc_vv0, 1.0f));
    vec3 rc_k2 = clamp(abs(fract(vec3(rc_hh3) + vec3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f)) * 6.0f - vec3(3.0f)) - vec3(1.0f), vec3(0.0f), vec3(1.0f));
    vec3 rc_r2 = pow(rc_vv3 * mix(vec3(1.0f), rc_k2, vec3(rc_ss3)), vec3(2.2f));
      float rc_w = rc_m + rc_m2;
      if (rc_w > 0.0f) { rc_r = (rc_r * rc_m + rc_r2 * rc_m2) / rc_w; rc_m = min(rc_w, 1.0f); }
    }
    c0.rgb = mix(c0.rgb, rc_r, vec3(rc_m));
  }
}

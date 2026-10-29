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
float h2f(uint h) { return unpackHalf2x16(h).x; }
vec2 unpack_h2(uint v) { return unpackHalf2x16(v); }
vec2 hx(uint v, uint swz) { if (swz == 1u) return vec2(uintBitsToFloat(v)); vec2 h = unpack_h2(v); return swz == 2u ? h.xx : (swz == 3u ? h.yy : h); }
uint hpack(vec2 r, uint merge, uint old) { if (merge == 1u) return floatBitsToUint(r.x); uint lo = packHalf2x16(vec2(r.x, 0.0f)), hi = packHalf2x16(vec2(r.y, 0.0f)); if (merge == 2u) return (old & 0xFFFF0000u) | lo; if (merge == 3u) return (old & 0xFFFFu) | (hi << 16); return lo | (hi << 16); }
uint prmt(uint a, uint b, uint sel) { uint r = 0u; for (uint i = 0u; i < 4u; i++) { uint s = (sel >> (i * 4u)) & 7u; uint bt = s < 4u ? (a >> (s * 8u)) & 0xFFu : (b >> ((s - 4u) * 8u)) & 0xFFu; r |= bt << (i * 8u); } return r; }
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
    { vec4 t = texture(t0, vec2(as_f(r5), as_f(r6)));
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
}

#include <metal_stdlib>
using namespace metal;
static inline uint cbr(constant uint4 *cb, uint off) { return cb[off >> 4][(off >> 2) & 3]; }
static inline uint bfe_u(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return 0u; return extract_bits(v, pos, min(len, 32u - pos)); }
static inline uint bfe_s(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return (int(v) < 0) ? 0xFFFFFFFFu : 0u; return uint(extract_bits(int(v), pos, min(len, 32u - pos))); }
static inline uint bfi(uint ins, uint ctl, uint base) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u || pos >= 32u) return base; return insert_bits(base, ins, pos, min(len, 32u - pos)); }
static inline float fswzadd(float a, float b, uint swz, uint lane) { uint m = (swz >> ((lane & 3u) * 2u)) & 3u; float ma = m == 1u ? -1.0f : (m == 3u ? 0.0f : 1.0f); float mb = m == 2u ? -1.0f : 1.0f; return a * ma + b * mb; }
static inline float2 hx(uint v, uint swz) { if (swz == 1u) return float2(as_type<float>(v)); float2 h = float2(as_type<half2>(v)); return swz == 2u ? h.xx : swz == 3u ? h.yy : h; }
static inline uint hpack(float2 r, uint merge, uint old) { if (merge == 1u) return as_type<uint>(r.x); half2 o = as_type<half2>(old), n = half2(r); if (merge == 2u) o.x = n.x; else if (merge == 3u) o.y = n.y; else o = n; return as_type<uint>(o); }
static inline uint prmt(uint a, uint b, uint sel) { uint r = 0; for (uint i = 0; i < 4; i++) { uint s = (sel >> (i * 4)) & 7u; uint byte = s < 4 ? (a >> (s * 8)) & 0xFFu : (b >> ((s - 4) * 8)) & 0xFFu; r |= byte << (i * 8); } return r; }
struct FIn {
  float4 pos [[position]];
  float4 v0 [[user(locn0)]];
};
struct FOut {
  float4 c0 [[color(0)]];
};
fragment FOut main0(FIn in [[stage_in]], bool front_facing [[front_facing]], texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]]) {
  uint r0 = 0;
  uint r1 = 0;
  uint r2 = 0;
  uint r3 = 0;
  uint r4 = 0;
  uint r5 = 0;
  uint r6 = 0;
  uint r7 = 0;
  do {
    r4 = as_type<uint>(in.pos[3]);
    r4 = as_type<uint>((1.0f / as_type<float>(r4)));
    r5 = as_type<uint>(in.v0[0] * in.pos.w * as_type<float>(r4));
    r6 = as_type<uint>(in.v0[1] * in.pos.w * as_type<float>(r4));
    r7 = as_type<uint>(in.v0[2] * in.pos.w * as_type<float>(r4));
    { float4 t = t0.sample(s0, float2(as_type<float>(r5), as_type<float>(r6)));
      r0 = as_type<uint>(t[0]);
      r1 = as_type<uint>(t[1]);
      r2 = as_type<uint>(t[2]);
      r3 = as_type<uint>(t[3]);
    }
    r0 = as_type<uint>((as_type<float>(r0) * as_type<float>(r7)));
    r1 = as_type<uint>((as_type<float>(r1) * as_type<float>(r7)));
    r2 = as_type<uint>((as_type<float>(r2) * as_type<float>(r7)));
    r3 = as_type<uint>((as_type<float>(r3) * as_type<float>(r7)));
    break;
  } while (false);
  FOut o;
  o.c0[0] = as_type<float>(r0);
  o.c0[1] = as_type<float>(r1);
  o.c0[2] = as_type<float>(r2);
  o.c0[3] = as_type<float>(r3);
  return o;
}

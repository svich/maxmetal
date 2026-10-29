#include <metal_stdlib>
using namespace metal;
static inline uint cbr(constant uint4 *cb, uint off) { return cb[off >> 4][(off >> 2) & 3]; }
static inline uint bfe_u(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return 0u; return extract_bits(v, pos, min(len, 32u - pos)); }
static inline uint bfe_s(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return (int(v) < 0) ? 0xFFFFFFFFu : 0u; return uint(extract_bits(int(v), pos, min(len, 32u - pos))); }
static inline uint bfi(uint ins, uint ctl, uint base) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u || pos >= 32u) return base; return insert_bits(base, ins, pos, min(len, 32u - pos)); }
static inline float fswzadd(float a, float b, uint swz, uint lane) { uint m = (swz >> ((lane & 3u) * 2u)) & 3u; float ma = m == 1u ? -1.0f : (m == 3u ? 0.0f : 1.0f); float mb = m == 2u ? -1.0f : 1.0f; return a * ma + b * mb; }
static inline uint2 rsc(uint2 c, float4 s) { return (s.x == 1.0f && s.y == 1.0f) ? c : uint2(floor((float2(c) + 0.5f) * s.xy)); }
static inline float2 uvs(float2 uv, float4 s) { return (s.z == 1.0f && s.w == 1.0f) ? uv : min(uv, 1.0f) * s.zw; }
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
fragment FOut main0(FIn in [[stage_in]], bool front_facing [[front_facing]], constant float4 *rscale [[buffer(18)]], constant float4 *ltint [[buffer(19)]], texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]]) {
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
    { float4 t = t0.sample(s0, uvs(float2(as_type<float>(r5), as_type<float>(r6)), rscale[1]));
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
  if (ltint[0].w > 0.0f) { float3 g = o.c0.rgb; float l = dot(g, float3(0.299f, 0.587f, 0.114f));
    o.c0.rgb = mix(g, ltint[0].rgb * pow(l, ltint[1].w) + ltint[1].rgb * l, ltint[0].w); }
  else if (ltint[0].w < 0.0f) {
    float3 rc_g = pow(max(o.c0.rgb, float3(0.0f)), float3(1.0f / 2.2f));
    float4 rc_K = float4(0.0f, -1.0f / 3.0f, 2.0f / 3.0f, -1.0f);
    float4 rc_p = mix(float4(rc_g.b, rc_g.g, rc_K.w, rc_K.z), float4(rc_g.g, rc_g.b, rc_K.x, rc_K.y), float4(step(rc_g.b, rc_g.g)));
    float4 rc_q = mix(float4(rc_p.x, rc_p.y, rc_p.w, rc_g.r), float4(rc_g.r, rc_p.y, rc_p.z, rc_p.x), float4(step(rc_p.x, rc_g.r)));
    float rc_d = rc_q.x - min(rc_q.w, rc_q.y);
    float rc_hh0 = abs(rc_q.z + (rc_q.w - rc_q.y) / (6.0f * rc_d + 1e-6f)), rc_ss0 = rc_d / (rc_q.x + 1e-6f), rc_vv0 = rc_q.x;
    float rc_sd0 = fract(rc_hh0 - ltint[1].x + 0.5f) - 0.5f, rc_dh0 = abs(rc_sd0);
    float rc_m = (ltint[1].y >= 0.5f ? 1.0f : 1.0f - smoothstep(ltint[1].y * 0.6f, ltint[1].y, rc_dh0)) *
              smoothstep(ltint[1].z * 0.5f, ltint[1].z + 1e-4f, rc_ss0);
    float rc_hh1 = fract(ltint[1].x + ltint[0].x + rc_sd0 * ltint[1].w), rc_ss1 = clamp(rc_ss0 * ltint[0].y, 0.0f, 1.0f);
    float rc_vv1 = min(rc_vv0 * ltint[0].z, max(rc_vv0, 1.0f));
    float3 rc_k0 = clamp(abs(fract(float3(rc_hh1) + float3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f)) * 6.0f - float3(3.0f)) - float3(1.0f), float3(0.0f), float3(1.0f));
    float3 rc_r = pow(rc_vv1 * mix(float3(1.0f), rc_k0, float3(rc_ss1)), float3(2.2f));
    if (ltint[2].w < 0.0f) {
    float rc_sd2 = fract(rc_hh0 - ltint[3].x + 0.5f) - 0.5f, rc_dh2 = abs(rc_sd2);
    float rc_m2 = (ltint[3].y >= 0.5f ? 1.0f : 1.0f - smoothstep(ltint[3].y * 0.6f, ltint[3].y, rc_dh2)) *
              smoothstep(ltint[3].z * 0.5f, ltint[3].z + 1e-4f, rc_ss0);
    float rc_hh3 = fract(ltint[3].x + ltint[2].x + rc_sd2 * ltint[3].w), rc_ss3 = clamp(rc_ss0 * ltint[2].y, 0.0f, 1.0f);
    float rc_vv3 = min(rc_vv0 * ltint[2].z, max(rc_vv0, 1.0f));
    float3 rc_k2 = clamp(abs(fract(float3(rc_hh3) + float3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f)) * 6.0f - float3(3.0f)) - float3(1.0f), float3(0.0f), float3(1.0f));
    float3 rc_r2 = pow(rc_vv3 * mix(float3(1.0f), rc_k2, float3(rc_ss3)), float3(2.2f));
      float rc_w = rc_m + rc_m2;
      if (rc_w > 0.0f) { rc_r = (rc_r * rc_m + rc_r2 * rc_m2) / rc_w; rc_m = min(rc_w, 1.0f); }
    }
    o.c0.rgb = mix(o.c0.rgb, rc_r, float3(rc_m));
  }
  return o;
}

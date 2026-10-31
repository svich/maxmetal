#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

static inline float maxmetal_rcp(float x) { float r = fast::divide(1.0f, x), e = fma(fma(-x, r, 1.0f), r, r); return isfinite(e) ? e : r; }
struct maxmetal_cb
{
    uint4 _m0[4096];
};

struct maxmetal_sb
{
    uint _m0[1];
};

struct main0_out
{
    float4 c0 [[color(0)]];
};

struct main0_in
{
    float4 v0 [[user(locn0)]];
    float4 v1 [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint r4 = 0;
    bool p0 = false;
  do {
  do {
    r4 = as_type<uint>(gl_FragCoord[3]);
    r4 = as_type<uint>(maxmetal_rcp(as_type<float>(r4)));
    r0 = as_type<uint>(in.v0[0]);
    { bool cmp = (as_type<float>(r0) < as_type<float>(0x00000000u)); bool pp = true;
      p0 = cmp && pp;
    }
  if (!p0) {
    break;
  } else {
    r4 = 0u;
    discard_fragment();
    break;
  }
  } while (false);
    r0 = as_type<uint>(in.v1[0]);
    r1 = as_type<uint>(in.v1[1]);
    r2 = 0x00000000u;
    r3 = 0x3f800000u;
    break;
  } while (false);
    out.c0[0] = as_type<float>(r0);
    out.c0[1] = as_type<float>(r1);
    out.c0[2] = as_type<float>(r2);
    out.c0[3] = as_type<float>(r3);
    return out;
}


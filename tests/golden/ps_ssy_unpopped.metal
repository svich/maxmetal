#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

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
};

fragment main0_out main0(main0_in in [[stage_in]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint r4 = 0;
    uint r5 = 0;
    bool p0 = false;
  do {
  do {
    r4 = as_type<uint>(gl_FragCoord[3]);
    r4 = as_type<uint>((1.0f / as_type<float>(r4)));
    r5 = as_type<uint>(in.v0[0]);
    { bool cmp = (as_type<float>(r5) > as_type<float>(0x3f000000u)); bool pp = true;
      p0 = cmp && pp;
    }
  if (p0) {
    r0 = 0x00000000u;
    r1 = 0x3f800000u;
    break;
  } else {
    r0 = 0x3f800000u;
    r1 = 0x00000000u;
    break;
  }
  } while (false);
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


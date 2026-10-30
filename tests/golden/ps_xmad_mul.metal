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

fragment main0_out main0(float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint xs0 = 0u;
    uint xs1 = 0u;
    uint xs2 = 0u;
    do {
    r0 = 0x075bcd15u;
    r1 = 0x3ade68b1u;
    r2 = 0x00000005u;
    xs0 = r0; xs1 = r1; xs2 = r2;
    { uint xa = (r0 >> 0) & 0xFFFFu; uint xb = (r1 >> 0) & 0xFFFFu; uint xbu = r1;
      uint prod = xa * xb;
      uint cc_ = r2;
      uint res = prod + cc_;
      r3 = res;
    }
    { uint xa = (r0 >> 0) & 0xFFFFu; uint xb = (r1 >> 16) & 0xFFFFu; uint xbu = r1;
      uint prod = xa * xb;
      uint cc_ = 0u;
      uint res = prod + cc_;
      res = (res & 0xFFFFu) | (xbu << 16);
      r1 = res;
    }
    r0 = ((xs0 * xs1) + xs2);
    r1 = 0x00000000u;
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


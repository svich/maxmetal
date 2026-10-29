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
    do {
    r0 = 0x3f800000u;
    r1 = 0x3f000000u;
    r2 = 0x3e800000u;
    r3 = 0x3f800000u;
    break;
    } while (false);
    out.c0[0] = as_type<float>(r0);
    out.c0[1] = as_type<float>(r1);
    out.c0[2] = as_type<float>(r2);
    out.c0[3] = as_type<float>(r3);
    return out;
}


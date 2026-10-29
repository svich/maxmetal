#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T> static inline T maxmetal_nz(T v) { return select(v, T(0.0f), isnan(v)); }
struct maxmetal_cb
{
    uint4 _m0[4096];
};

struct maxmetal_sb
{
    uint _m0[1];
};

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t0 [[id(0)]];
    sampler fp_t0Smplr [[id(1)]];
};

struct main0_out
{
    float4 c0 [[color(0)]];
};

struct main0_in
{
    float4 v0 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint r4 = 0;
    uint r5 = 0;
    uint r6 = 0;
    uint r7 = 0;
    do {
    r4 = as_type<uint>(gl_FragCoord[3]);
    r4 = as_type<uint>((1.0f / as_type<float>(r4)));
    r5 = as_type<uint>(in.v0[0]);
    r6 = as_type<uint>(in.v0[1]);
    r7 = as_type<uint>(in.v0[2]);
    { float4 t = spvDescriptorSet0.fp_t0.sample(spvDescriptorSet0.fp_t0Smplr, maxmetal_nz(float2(as_type<float>(r5), as_type<float>(r6))));
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
    out.c0[0] = as_type<float>(r0);
    out.c0[1] = as_type<float>(r1);
    out.c0[2] = as_type<float>(r2);
    out.c0[3] = as_type<float>(r3);
    return out;
}


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

struct spvDescriptorSetBuffer0
{
    constant maxmetal_cb* vp_c3 [[id(0)]];
};

struct main0_out
{
    float4 v0 [[user(locn0)]];
    float4 pos [[position, invariant]];
    float psize [[point_size]];
};

struct main0_in
{
    float4 a0 [[attribute(0)]];
    float4 a1 [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    out.pos = float4(0.0f, 0.0f, 0.0f, 1.0f);
    out.psize = 1.0f;
    out.v0 = float4(0.0f, 0.0f, 0.0f, 1.0f);
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint r4 = 0;
    uint r5 = 0;
    uint r6 = 0;
    uint r7 = 0;
    do {
    r0 = as_type<uint>(in.a0[0]);
    r1 = as_type<uint>(in.a0[1]);
    r2 = as_type<uint>(in.a0[2]);
    r3 = as_type<uint>(in.a0[3]);
    r4 = as_type<uint>(in.a1[0]);
    r5 = as_type<uint>(in.a1[1]);
    r6 = as_type<uint>(in.a1[2]);
    r7 = as_type<uint>(in.a1[3]);
    r0 = as_type<uint>((as_type<float>(r0) * as_type<float>((*spvDescriptorSet0.vp_c3)._m0[0u][0])));
    r1 = as_type<uint>((as_type<float>(r1) * as_type<float>((*spvDescriptorSet0.vp_c3)._m0[0u][0])));
    r2 = as_type<uint>((as_type<float>(r2) * as_type<float>((*spvDescriptorSet0.vp_c3)._m0[0u][0])));
    out.pos[0] = as_type<float>(r0);
    out.pos[1] = as_type<float>(r1);
    out.pos[2] = as_type<float>(r2);
    out.pos[3] = as_type<float>(r3);
    out.v0[0] = as_type<float>(r4);
    out.v0[1] = as_type<float>(r5);
    out.v0[2] = as_type<float>(r6);
    out.v0[3] = as_type<float>(r7);
    break;
    } while (false);
    return out;
}


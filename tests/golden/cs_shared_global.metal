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

#define MAXMETAL_GAT(ga, k) device uint *gp = (*spvDescriptorSet0.cp_##k)._m0; uint go = uint(ga) - gk_##k.x; const bool gok = true;
#define MAXMETAL_GDECL device uint *gp = nullptr; uint go = 0u;
#define MAXMETAL_GIN(ga, x) if ((ga) - gb_##x < ulong(gn_##x)) { gp = (*spvDescriptorSet0.cp_##x)._m0; go = uint((ga) - gb_##x); }
#define MAXMETAL_GOK const bool gok = gp != nullptr;
#define MAXMETAL_GFIND(ga) MAXMETAL_GDECL MAXMETAL_GSEARCH(ga) MAXMETAL_GOK
#define MAXMETAL_GSEARCH(ga) for (uint gi = 0u; gi < 2u; gi++) if ((ga) - gsb[gi] < ulong(gsn[gi])) { gp = gsp[gi]; go = uint((ga) - gsb[gi]); break; }

#define MAXMETAL_SHW(a) min((a) >> 2, 1023u)

struct spvDescriptorSetBuffer0
{
    constant maxmetal_cb* cp_c0 [[id(0)]];
    device maxmetal_sb* cp_s0 [[id(1)]];
    device maxmetal_sb* cp_s1 [[id(2)]];
};

kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 ctaid [[threadgroup_position_in_grid]], uint3 tid [[thread_position_in_threadgroup]])
{
    threadgroup uint shm[1024];
    uint4 gk_s0 = (*spvDescriptorSet0.cp_c0)._m0[49u]; ulong gb_s0 = ulong(gk_s0.y) << 32 | ulong(gk_s0.x); uint gn_s0 = gk_s0.z;
    uint4 gk_s1 = (*spvDescriptorSet0.cp_c0)._m0[50u]; ulong gb_s1 = ulong(gk_s1.y) << 32 | ulong(gk_s1.x); uint gn_s1 = gk_s1.z;
    device uint *gsp[] = {(*spvDescriptorSet0.cp_s0)._m0, (*spvDescriptorSet0.cp_s1)._m0};
    ulong gsb[] = {gb_s0, gb_s1};
    uint gsn[] = {gn_s0, gn_s1};
    uint r0 = 0;
    uint r1 = 0;
    uint r2 = 0;
    uint r3 = 0;
    uint r4 = 0;
    uint r5 = 0;
    uint r6 = 0;
    uint r7 = 0;
    uint cc = 0; bool ccz = false, ccs = false;
    do {
    r0 = tid.x;
    r1 = ((0x00000002u) >= 32u ? 0u : (r0 << (0x00000002u)));
    { uint sa = r1 + 0x0u;
      shm[MAXMETAL_SHW(sa + 0u)] = r0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    { uint sa = r1 + 0x4u;
      r2 = shm[MAXMETAL_SHW(sa + 0u)];
    }
    r4 = (*spvDescriptorSet0.cp_c0)._m0[49u][0];
    r5 = (*spvDescriptorSet0.cp_c0)._m0[49u][1];
    { ulong ga = ((ulong(r5) << 32 | ulong(r4)) + ulong(0)); MAXMETAL_GAT(ga, s0)
      r3 = gok ? gp[(go >> 2) + 0u] : 0u;
    }
    r2 = as_type<uint>((as_type<float>(r2) + as_type<float>(r3)));
    r6 = (*spvDescriptorSet0.cp_c0)._m0[50u][0];
    r7 = (*spvDescriptorSet0.cp_c0)._m0[50u][1];
    { uint s = r6; uint t2 = r1; uint res = s + t2; cc = (res < s) ? 1u : 0u; ccz = (res == 0u); ccs = int(res) < 0;
      r6 = res;
    }
    r7 = (r7 + 0u + cc);
    { ulong ga = ((ulong(r7) << 32 | ulong(r6)) + ulong(0)); MAXMETAL_GFIND(ga)
      if (gok) gp[(go >> 2) + 0u] = r2;
    }
    break;
    } while (false);
}


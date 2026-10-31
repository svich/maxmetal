# Draw-uniform work is paid per pixel; hoisting it is the remaining bit-exact lever

Status: proposed (measured 2026-10-31 on an M4, not implemented). Follows ADR 0003.

## Where the hot fragment shaders' time goes

Measured in `maxmetal-diff` (paired, 1024 x 1024) on `37bb03a9`, the heaviest fragment shader, by replacing parts of the
translated body:

| Removed | GPU time |
|---|---|
| texture samples (22; coordinates kept live) | -33% |
| constant-buffer reads (258 reads, 132 words, as literals) | -8% |
| interpolant reads (as position-derived values) | no gain |
| NaN guard on sample coordinates (`maxmetal_nz`) | -3% (3 runs: -2.5, -3.0, -3.0%) |
| an added independent chain of 96 fma | +0.105 ms, the same as on a trivial shader |

The last row says the shader is ALU-throughput bound: extra work is not hidden. A compute copy of each hot fragment
shader reports 1024 threads per threadgroup, so registers do not limit occupancy. Its AIR holds 252 fma, 228 fmul,
99 fadd/fsub, 11 reciprocals, 9 exp2, 8 log2, 6 rsqrt, 4 sqrt and 22 samples: every one fixed by the bit-exact bar.
Paired vertex shaders (`79914e51`, `c74f69e7`, `bc3d2e31`, `4380c3b0`, `78b29311`, `345bb4ab`) time within 1.5% of
Ryujinx's, bound by their 36 divergent 16-byte constant loads (skinning), which the compiler already vectorises.

So per-invocation work is at its floor, except for work that does not have to be per invocation.

## The M4 computes draw-uniform expressions per thread

A kernel whose only work is a chain of 1024 fma on constant-buffer words (the same for every thread) costs as much as
the same chain on per-thread values (3.42 vs 3.54 ms for 4M threads); a fragment function with both costs 1.9x one with
the per-thread chain alone. The compiler moves uniform *loads* out of the main program (ADR 0003: direct binding cut code
10-21% without saving time) but not uniform *arithmetic*.

Share of a fragment shader's ALU that depends only on constant-buffer words and literals (AIR, `fneg` excluded; the
27 fragment shaders with the most pipelines in the shared list plus the hot ones):

| Shader | ALU ops | Uniform-only | Scalars to pass | Ops saved per scalar |
|---|---|---|---|---|
| `187b00a2` family (7 shaders, ~1260 ops) | 1260 | 10-13% | 85 | 2.0 |
| `3d31c9ca` | 186 | 16% | 13 | 2.2 |
| `833ae9b0` | 168 | 23% | 14 | 2.8 |
| `b73ad57d` | 324 | 6.5% | 13 | 2.0 |
| `5ec614bb` | 146 | 7% | 2 | 5.5 |
| `37bb03a9` | 1059 | 4% | 31 | 1.5 |
| `679c5257` | 960 | 4% | 39 | 1.1 |
| median of the 27 | | 11% | | |

Upper bound of the gain, measured as "every constant-buffer word a literal" (folds all uniform work and drops the loads):
`679c5257` -16%, `b73ad57d` -9%, `37bb03a9` -8%, `3d31c9ca` -3%, `5ec614bb` and `390a3d6e` within noise.

## The lever

Compute the uniform-only expressions once per vertex in the paired vertex function and pass them as `[[flat]]`
varyings. It is bit-exact by construction: the same operations run on the same GPU in safe math, and flat
interpolation passes the provoking vertex's bits unchanged. Metal links the two stages per pipeline, so the fragment
side only changes which values it reads.

Costs, measured:
- Each extra flat `float4` varying costs the vertex/tiler side 0.11 ns per vertex (1M one-pixel triangles: 1.50 ms with
  4 perspective varyings, +0.33 ms per added flat `float4` up to 16). `37bb03a9`'s 8 varyings would add 0.9 ns per
  vertex to a vertex shader that costs 0.6 ns per vertex today.
- Each flat read in the fragment function is at least one instruction, so a hoisted scalar must save more than one op.
  Net saving is about (ops saved - scalars): `3d31c9ca` ~9% of its ALU, `187b00a2` ~7%, `5ec614bb` ~6%, `37bb03a9` ~1.5%.
- Break-even is roughly 10-20 fragments per vertex for the heavy shaders. Pipelines below that (dense meshes, particles)
  must not hoist.

Requirements: the translator sees the (vertex, fragment) pair (the shared list's `R` rows name them), the renderer binds
the fragment stage's constant buffers to the vertex stage as well, and the hoisted set is chosen by a cost model (ops
saved per scalar >= 2, fragments per vertex from the pipeline's history or the draw's primitive count).

What has to change, besides the translator's analysis and emission:
- the renderer picks a pair-specific vertex function at pipeline creation and falls back to the generic one;
- the vertex stage gets the fragment stage's constant buffers (NVN binds per stage): the hoisted vertex function takes the
  fragment argument buffer as a second buffer argument, and the renderer sets it and extends `useResource` to the vertex
  stage for those pipelines;
- the translation requests, the seed and the shader cache are keyed by the pair for the whitelisted fragment programs;
- `maxmetal-diff` gets a paired mode (today it times each stage with its own grid vertex function).

Before any of that, hand-prototype one shader (`3d31c9ca` or the `187b00a2` family) and require a net gain of at least
5% at a realistic fragments-per-vertex ratio.

Not a win: hoisting in the fragment function itself (same per-thread cost); a per-draw compute dispatch (dispatch and
barrier per draw); a tile dispatch per draw writing imageblock data (serialises against fragment work).

## Checked and not levers (do not retry)

- **Cross-stage dead varyings:** Metal already drops vertex outputs the fragment function never reads at pipeline link
  (16 outputs, 1 read: vertex code 11,840 -> 2,640 bytes, time 71.7 -> 3.1 ms).
- **Colour write mask:** the pipeline's mask already removes the work behind masked channels (all 0.184 ms, red 0.092,
  alpha 0.044, none 0.005; code 2,960 -> 2,064 bytes).
- **Integer forms of float tests:** the M4 overlaps integer with fp32 work (1024 fma + 512 int ops in 3.76 ms, 1024 fma
  alone 3.78 ms; fcmp/select and icmp/select chains overlap alike), but a NaN guard written as `(bits << 1) > 0xff000000`
  with an integer select was not faster than the float form (+2.2%, -0.6%, within noise).
- **NaN guard dropped:** -3%, exact across the harness, but on the M4 a NaN coordinate behaves like +inf (last texel
  under clamp-to-edge, texel 0 under repeat, border under clamp-to-zero; a negative NaN like -inf), so dropping it changes
  the NaN case and stays a semantic choice (ADR 0003 keeps it).
- **Fewer distinct textures** (17 aliased to 3): -4%; descriptor pressure is not the limit.
- **Register pressure:** compute copies of all hot fragment shaders get 1024 threads per threadgroup.

## Tools

- `xctrace` from the command line records only "RT Unit Active" with the Metal GPU Counters instrument and the Game
  Performance template; the shader profiler tables stay empty. Counter profiles need the Instruments GUI.
- `applegpu-nt` accepts `-mllvm` and `-disable-optimizations` but the output is unchanged by them, and results are cached
  under `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.metal` by input: a `-stress-regalloc` sweep gave identical code.
  The pipeline script must have the `.mtlp-json` extension.
- Timing: the same process pair runs at one of two GPU clock states (0.9 or 2.45 ms per draw for `37bb03a9`); paired
  A/A agrees within 0.5% in the slow state and up to 5% in the fast one. Repeat a comparison in three processes.

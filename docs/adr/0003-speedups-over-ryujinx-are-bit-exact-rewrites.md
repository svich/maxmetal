# Speedups over the Ryujinx path are bit-exact rewrites only

maxmetal's output has to match Ryujinx + SPIRV-Cross bit for bit in `maxmetal-diff`, and the game compiles every
shader in Metal's safe math mode (`MTLMathModeSafe`). Within those rules the floating-point work is fixed: the same
operations in the same order. A speedup has to come from a cheaper form that gives the same bits for every input.
This records the rewrites kept and the ones that failed on Tears of the Kingdom 1.4.3's shaders, with the measurements
behind each, so a failed one isn't tried again.

## Kept

Three rewrites, each emitted in NVN mode:

- **Reciprocal (`MUFU.RCP`):** `1.0f / x` in safe math is a general correctly rounded division (+80 bytes of GPU code
  per scalar). The GPU's reciprocal (`fast::divide(1.0f, x)`) is at most 1 ulp off. One fma step corrects it, and a
  select keeps the raw result when the corrected one is not finite. That costs +32 bytes and matches `1.0f / x` on all
  2^32 inputs.
- **Bank c1 inlined:** c1 holds the program's own constants, the request's `c1`. Each read at a constant index becomes
  the word's bits instead of a load, except +-1.0 and +-0.0 (see below). +-1.0 is 6% of the reads in the corpus; +-0.0
  doesn't occur. Inlining is a pass over the finished body. It is skipped for the whole shader when a value computed
  only from constants, at least one of them an inlined word, may reach `exp2`, `log2`, `sin`, `cos`, `sqrt` or `rsqrt`
  (see below).
  - The check follows the variables that may hold such a value. It merges both branches of an if and every iteration
    of a loop, so it can raise false alarms but misses nothing.
  - Shaders that use maxmetal's `switch (pc)` fallback for unstructured control flow are skipped outright.
  - In the corpus it keeps the loads in 13 of the 18,992 shaders that read c1: 10 flagged, 3 skipped as `switch (pc)`
    shaders.
- **Unordered float compares** (`FSETP.LTU` etc.) are written as the negated ordered complement, `!(a >= b)`, instead of
  `(a < b) || isnan(a) || isnan(b)`. That is one compare instead of three. `!=` is already unordered. The two forms
  match on 16M input pairs, special values included.

The exactness checks behind the reciprocal and compare rewrites, and the identity folds behind the c1 rule, gave the
same answers on an M4 Mac and an iPhone 13 (A15 GPU, iOS 27.0.1):
- `maxmetal_rcp` matches `1.0f / x` on all 2^32 inputs on both.
- The GPU reciprocals differ from each other: the bare hardware reciprocal is off on 437,559,696 inputs on the M4 and
  816,341,400 on the A15.

Constant-only expressions fold further from the A15 than from the M4:

| Expression | Constants that differ, M4 | Constants that differ, A15 |
|---|---|---|
| `sin` | 0 | 1,437 |
| `cos` | 0 | 1,340 |
| `exp2` | 556 | 865 |
| `log2` | 529 | 677 |
| `rsqrt` | 43 | 225 |

(Out of 2,048 constants.) The corpus diff runs on the Mac, so it can't catch a c1 word inlined into a `sin` or `cos`.
That is why the inlining pass refuses any shader where an inlined word may reach a transcendental.

Results against the Ryujinx path:

- **Exactness:** every corpus variant the three rewrites change matches Ryujinx bit for bit, with and without
  `hw_layer_clamp`, except `9c2c6340`, one of the README's two exceptions.
- **GPU code** (a 2,050-variant sample):

  | | GPU code vs Ryujinx | Variants with more code than Ryujinx's |
  |---|---|---|
  | Vertex | −14.8% | 103 of 986 |
  | Fragment | −5.6% | 98 of 1,038 (52 with `hw_layer_clamp`) |
  | Compute | −7.6% | 3 of 26 |
  | 30 fragment shaders leading the most frame time | −6.3% (−11 to −13% on the largest) | |
- **GPU time** of those 30 fragment shaders, paired at 1024 × 1024. Eleven are heavy enough to time; the rest run under
  0.01 ms per draw, within ±10% noise.

  | Compared with | Total | Geometric mean |
  |---|---|---|
  | maxmetal without the three rewrites | −7.6% | −6.9% |
  | Ryujinx | −20% | −15% |

  - Against Ryujinx: `61315f71` −27%, `37bb03a9` −26%, `5ec614bb` −23%, `679c5257` −22%, `3d31c9ca` −17 to −23%,
    `b73ad57d` −14 to −18%, `390a3d6e` (the main geometry pass) −9 to −11%.
  - c1 inlining alone makes the hot shaders that read c1 3–8% faster (`37bb03a9` −7%).
  - Vertex and compute GPU time against Ryujinx is not measured.

## Failed

- **`fast::` forms of the other `MUFU` functions.** `exp2`, `log2`, `sqrt`, `rsqrt`, `sin` and `cos` compile to the same
  GPU code in safe math as their `fast::` forms. They also give the same bits on all 2^32 inputs. Both hold on the M4 and
  on the A15. `sin` and `cos` cost +96 bytes either way on the M4 and +16 on the A15. There is nothing to gain on either
  platform. The reciprocal and compare rewrites save GPU code on both:

  | | M4 | A15 |
  |---|---|---|
  | `1.0f / x` | +80 bytes | +64 bytes |
  | `maxmetal_rcp` | +16 bytes | +16 bytes |
  | `(a < b) \|\| isnan(a) \|\| isnan(b)` | +64 bytes | +48 bytes |
  | `!(a >= b)` | +16 bytes | +16 bytes |
- **The bare hardware reciprocal.**
  - It differs from `1.0f / x` on 437,559,696 of the 2^32 inputs, by 1 ulp (x = `0x008005a9`: `0x7e7ff4af` vs
    `0x7e7ff4ae`).
  - With the fma step but without the select, 16,777,218 inputs still differ: x = 0 and denormal x give NaN instead of
    infinity.
- **Every c1 word inlined.** Metal's compiler folds constant expressions with IEEE arithmetic. The GPU flushes denormals
  to zero, returns its default NaN `0x7fc00000`, and approximates the transcendentals. So folding changes bits:
  - **Identities:** the compiler folds `x * 1.0`, `x * -1.0`, `x / +-1.0`, `x - 0.0` and `x + -0.0` to `x` (or `-x`). With
    the constant read from a buffer, the GPU returns 0 for a denormal `x` and its default NaN for a NaN `x`. Hence the
    exception for those words.
  - **Expressions of constants only.** Out of 2,048 constants, the folded result differed from the GPU's for:

    | Expression | Constants that differ | Why |
    |---|---|---|
    | `log2(abs(x))` | 1,059 | approximation |
    | `exp2` | 556 | approximation |
    | `log2` | 529 | approximation |
    | `sqrt` | 293 | approximation |
    | float to int | 172 | out-of-range values fold to 0; the GPU saturates |
    | float to uint | 85 | same |
    | `rsqrt` | 43 | approximation |
    | multiply | 18 | denormal results |
    | reciprocal | 7 | denormal results |
    | `fma` | 3 | |
    | `floor` | 2 | |
    | `rint` | 1 | |
    | float to half | 1 | NaN payload |

    `sin` and `cos` did not differ on the M4; on the A15 they did (see above). The transcendentals among these are what
    the check guards against. The other differences need a denormal result or an out-of-range conversion, which a
    shader's own constants don't produce.
  - **Comparing compiled intermediate code** (Metal's AIR) is not a usable check: the Mac front end doesn't fold the
    `cos` of a constant that the A15's GPU compiler folds later. A check comparing the calls left in the compiled code
    with and without inlining also mistakes calls merged after the other rewrites for folds.
- **Returning right after `discard_fragment()`.** Tried in the alpha-tested `390a3d6e`, where nothing after the discard
  needs the thread. Timed 1.007× and 1.100×, while another GPU job ran: no gain seen. Metal appears to end a discarded
  fragment's work already.
- **Measured on `37bb03a9`** in MacNativeGames:
  - **Predicated blocks as `select()`:** no change; Metal's compiler already converts them.
  - **Computed-index constant-buffer reads as a clamped load plus a select**, instead of a bounds check and a branch:
    branches went from 42 to 10, GPU time stayed within ±1.3%. maxmetal emits no bounds check at all, as Ryujinx's
    output has none.
  - **Relaxed math** (`#pragma METAL fp math_mode(relaxed)`): Ryujinx's output gets 8.5% faster, maxmetal's 5%. It changes
    bits (a few half-float steps on under 0.2% of values), so it fails the bar.
  - **A hand rewrite of the shader in safe math:** 2–5% faster than Ryujinx, bit-identical, but not mechanical.
- **Advice from Apple's guides** (WWDC16 606 "Advanced Metal Shader Optimization", WWDC23 10127, the 2023 M3 tech
  talks, Philip Turner's metal-benchmarks), measured on the M4:
  - **Constant buffers bound directly** (`constant maxmetal_cb& c [[buffer(n)]]`) instead of through the argument
    buffer, which WWDC16 gives as the condition for preloading them into registers. Exact (20 of 20 variants). GPU
    code shrank a lot: −10 to −17% on half of 10 sampled vertex shaders, −5 to −21% on the larger fragment shaders. GPU
    time didn't follow: vertex −1.1% geomean (two of ten faster in both orders), fragment +0.4% (the largest, −5% code,
    1–1.5% slower). The loads seem to move out of the main program rather than go away. It would also change the
    renderer's binding model.
  - **`int` instead of `uint` buffer indices** (WWDC16: unsigned offsets may need address arithmetic): identical GPU code
    for computed constant-buffer and storage-buffer indices.
  - **`[[max_total_threads_per_threadgroup(n)]]`** with the kernel's real group size (WWDC23's occupancy hint): every
    sampled kernel already gets 1024 threads without it, so no kernel is register-limited.
  - **SIMD-group barriers:** the corpus's only barriers are in 4 variants with 256-thread groups.
  - Already done: `[[early_fragment_tests]]` exactly where Ryujinx's output has it, `saturate` (free on Apple GPUs)
    where Ryujinx's output clamps, and Maxwell's three-`XMAD` multiply as one 32-bit multiply.
  - FP16 arithmetic and interpolants, the main advice of the 2023 talks, change bits.
- **Closing the remaining code-size gaps to Ryujinx** (on the 2,050-variant sample):
  - **Constant buffers typed `float4`** (reads as `as_type<uint>(...)`), as Ryujinx's output has them. Exact. Vertex code
    median −0.9%, and vertex variants bigger than Ryujinx's dropped from 102 to 28. Fragment unchanged. Compute
    `7aa3e226` grew from 19,744 to 25,968 bytes. GPU time on the 40 vertex shaders with the biggest code savings:
    geomean −0.4%, within noise (timed with the output dump, without `MAXMETAL_DIFF_TIME_NODUMP`).
  - **No zero-fill of local memory** (`uint lmem[256] = {};`). The fill only costs code where local memory is indexed by
    a computed address: 42 of the corpus's 31,307 variants, none hot (`45608116`: 10,688 to 8,272 bytes). Without it,
    reads before writes are undefined. Not timed: those variants have loops driven by their inputs.
  - **Slots of global addresses spilled to shared or local memory resolved at translation**, as Ryujinx's
    `GlobalToStorage` does, instead of the runtime search of the 14 slots (`MAXMETAL_GFIND`). Exact; `7aa3e226` went from
    26,032 to 16,592 bytes. Only 13 variants in 6 shaders search, and their time didn't change. Ryujinx's rule also
    ignores stores between the spill and the reload, and maxmetal's body isn't in SSA form.

Ubershaders are covered by ADR 0002.

## Texture checks kept, though Ryujinx's output lacks them

maxmetal guards texture coordinates against NaN and clamps array layers. Ryujinx's output does neither for
`sample_compare`, and clamps no layer at all. Copying Ryujinx's form would match Ryujinx by construction. But the Metal
Shading Language specification (version 4.1) doesn't make any of these checks redundant:

- **NaN guard on coordinates** (`select(c, 0, isnan(c))`).
  - Specification (§8.7): the coordinates of `sample`, `sample_compare`, `gather`, `gather_compare`, `read` and `write`
    "cannot be INF or NaN", so the behaviour is undefined.
  - On an M4 Mac, unguarded `sample_compare` (Ryujinx) matches guarded (maxmetal) across the corpus.
  - Kept: the guard is the only defined behaviour, and on its own it adds no GPU code.
- **Array-layer clamp** (`min(layer, get_array_size() - 1)`).
  - Specification (§6.13): an out-of-range slice makes the access out of bounds, and an out-of-bounds read returns zero
    (alpha 1 where the format has none). It says nothing about `sample`, `gather` and `sample_compare`.
  - The probe: a 3-slice array sampled at its centre, at level 0, with clamp-to-edge, repeat and clamp-to-zero
    addressing. The arrays are `R32Float` and `Depth32Float`, with slice i filled with i + 1 and 0.25 (i + 1). On an
    M4 Mac and on an iPhone 13 (A15, iOS 27.0.1), for layers 3, 7 and `0xFFFFFFFF`, `sample`, `gather` and
    `sample_compare` use the last slice, and `read` returns zero.
  - Others rely on that behaviour:
    - WGSL requires the array index of `textureSample`, `textureSampleCompare`, `textureGather` and the rest to be
      clamped to `[0, textureNumLayers(t) - 1]`. Dawn's Metal output only applies `max(index, 0)`, with no upper bound
      (Tint fixture `textureSample/6717ca.wgsl.expected.msl`). Its robustness pass clamps the layer only for
      `textureLoad` and `textureStore`.
    - Vulkan requires the same clamp, and SPIRV-Cross (Ryujinx's output) doesn't add one.
  - Kept by default: it is redundant only through the hardware's behaviour, which the specification doesn't promise.
    It costs one descriptor query and a `min` per array sample. Without the clamp, GPU code shrinks by 1–6% in the hot shaders that use it (390a3d6e −3.9%,
    b73ad57d −6.4%), and the output stays exact.
- **Layer from float to uint** (`max(rint(z), 0)`, clamped to 65535).
  - Specification (§8.6): NaN gives 0 and the conversion rounds toward zero. Negative and too-large values are
    unspecified.
  - On an M4 Mac the GPU saturates, but the compiler folds a constant out-of-range value to 0.
  - Kept.

The clamp stays by default. `NvnKey.hw_layer_clamp` (service request `"hw_layer_clamp": true`) drops it for `sample`,
`gather` and `sample_compare`, for GPU families that pass the probe: the Apple M4 and A15. `read` keeps its own
handling. With the flag set, 6,522 of the corpus's 31,307 variants change. Before turning it on for
another GPU family, rerun the probe on that family.

## Consequences

- **Check exactness over every input, one form per kernel.** A check that computes both forms in one kernel and compares
  them is worthless. With the compiler free to merge them, it reports the bare hardware reciprocal and `1.0f / x` as
  identical everywhere. Write each form to its own buffer from its own kernel.
- **GPU code size is a usable static proxy.** `MAXMETAL_DIFF_ARCHIVE=<dir>` saves each pipeline as a binary archive. Its
  `applegpu` Mach-O slice has `__vertex`, `__fragment` or `__compute` sections, whose sizes come in 16-byte steps.
  With `MAXMETAL_DIFF_COMPILE_ONLY=1` the pipelines are built and saved without running, so sizing a sample never hangs
  the GPU. It only screens candidates: binding constant buffers directly cut code by up to 21% and saved no time (see
  Failed). Time a change before keeping it.
- **Timing needs pairing.**
  - With the display active, one process's GPU times for the same shader vary up to 3×.
  - Command buffers in flight together overlap, which makes the second side look 5–6% slower.
  - `MAXMETAL_DIFF_TIME_PAIRED=N` alternates the sides pass by pass (ab ba ...), for fragment and vertex shaders:
    - each pass is a command buffer of about 4 ms, committed and waited on;
    - it runs after about 100 ms of warming up;
    - it reports each side's lower quartile.
  - A/A runs agree within ±1% on most shaders and ±4–9% on memory-bound ones, whose passes run at one of two speeds.

# Game shader variants are translated one by one, not merged into ubershaders

The game ships each shader variant compiled, with no source. Every variant is translated on its own, and its output
matches the Ryujinx path's. The alternative is a Dolphin-style ubershader: one MSL function that runs any of a program's
variants, picked at draw time. We built such ubershaders two ways, on Tears of the Kingdom 1.4.3's agl shaders:
- by hand, for one program;
- mechanically, for every agl program, by merging the translations.

Both matched the variants bit for bit and compiled far faster. Both ran slower on the GPU, and for the merge the cost
grows with the number of variants in one function:
- about 1× up to ~10 variants;
- 1.3–1.4× for 11–126;
- about 3× for ~600.

The game draws few of the variants a merge removes, so it saves seed and warm-up work, not stalls in play. We kept the
per-variant translation.

## Where the GPU time goes

A per-pass GPU profile (MacNativeGames `flag pass_gpu`; 60 frames of one 1920 × 1080 scene;
13.1 ms of GPU per frame; each pass credited to its first fragment shader) splits the frame like this:

| Passes led by | Share of frame |
|---|---|
| agl | 37% |
| material | 12% |
| compute (no shader recorded) | 10% |
| grass | 8.5% |
| system | 4.4% |
| effects | 1% |

Nearly all the agl time is in programs with few variants:

| Program | Variants | Share of frame |
|---|---|---|
| `g_buffer_expand_material_id` | 11 | 5.4% |
| `bloom_gaussian` | 2 | 3.5% |
| `scene_shading_analyzer` | 6 | 3.0% |
| `render_buffer_color` | 9 | 2.5% |
| `super_resolution_pass_fs` | 5 | 1.8% |
| `dof_final` | 637 | 1.1% |

`hdr_compose`, `shadow_pre_pass` and `bloom_mask` were not drawn.

## Hand-written: `hdr_compose`

The program has four macros: bloom compose 0–2, colour correction 0–1, tonemapping 0–6 and gamma 0–2. That gives 126
fragment variants sharing one vertex shader. The ubershader is 117 lines, against 15,494 for the 126 translations; it
reads the macro values from a buffer.

- **Exactness:** every variant matched, over 3 input seeds, after three branches were added. Each repeats an operation
  the Switch compiler had fused across two steps:
  - tonemapper 3 followed by gamma: `log2(exp2(x))` folded to `x`;
  - tonemapper 4 followed by gamma: `c * s` fused into the subtraction;
  - tonemapper 1 followed by the 3D LUT: `(1 − e) · s + o` rewritten as `fma(e, −s, s) + o`.

  The last one showed only in a test mode that returns the LUT coordinate instead of sampling. A lookup hides a 1-ulp
  coordinate error unless it crosses a texel.
- **GPU time vs the variants** (1024 × 1024 draws):
  - with the macro values read at run time: 1.16× median, 1.19× total;
  - with them baked into the same source: 1.00×.

  The cost is the run-time branching.
- **Cold compile:** 20.1 s for the 126 variants, 0.22 s for the ubershader.

## Mechanical merge: every agl program

**How the merge works:**
- **Inputs:** the agl package's program table gives each program's variants, and the translations are merged as they
  are. The merge itself doesn't need the table: any translated fragment shaders with compatible interfaces can share a
  function.
- **Each variant:** its code becomes a function of its own, `body_vN`, and `main0` switches on a variant index the draw
  binds. Its bindings map to one shared argument buffer by binding kind, NVN slot and type.
- **Grouping:** variants share a function only when they have the same entry attributes (`[[early_fragment_tests]]`),
  the same outputs, and stage inputs of the same type and interpolation. An output a variant lacks would overwrite that
  attachment.
- **`noinline`:** 847 variants keep a non-inlined function. These are the ones whose implicit-derivative operations
  (`sample` without `level`, `dfdx`, `fwidth`) sit in branches or loops, or share the shader with a discard. Derivatives
  there are undefined and follow the code's layout. Inlined, 3 of `fxaa`'s 26 variants differed; non-inlined, none did.

**Results** (187 programs with two or more fragment variants):

| | Per variant | Merged |
|---|---|---|
| Fragment shaders | 3,462 | 280 functions |
| Bit-exact (`maxmetal-diff`) | — | 3,462 of 3,462 (`fxaa` on 3 input seeds) |
| Cold compile | 927 s | ~111 s |
| Render pipelines in the shared list | 360 | 301 |

The largest function, `shadow_pre_pass`, has 576 variants in 190k lines (10.8 MB). It compiles in 12.6 s against 384 s
for its variants, but its single pipeline takes 6.9 s to build.

**GPU time vs the variants** (up to 40 variants per program, 1024 × 1024 draws, both orders):

| Program | Variants | Median | p90 | Total |
|---|---|---|---|---|
| `bloom_gaussian` | 2 | 0.90× | 0.93× | 0.90× |
| `super_resolution_pass_fs` | 5 | 0.96× | 1.23× | 1.00× |
| `scene_shading_analyzer` | 6 | 1.00× | 1.20× | 1.02× |
| `render_buffer_color` | 9 | 1.04× | 1.10× | 0.99× |
| `image_filter_gaussian` | 18 | 1.02× | 1.34× | 1.05× |
| `fxaa` (14 of 26 non-inlined) | 26 | 1.06× | 1.48× | 1.08× |
| `g_buffer_expand_material_id` | 11 | 1.41× | 1.77× | 1.43× |
| `hdr_compose` | 126 | 1.27× | 1.91× | 1.25× |
| `hdr_compose`, every variant non-inlined | 126 | 1.57× | 2.23× | 1.53× |
| `dof_final` | 637 | 3.03× | 4.55× | 2.91× |
| `shadow_pre_pass` | 576 | 3.04× | 6.69× | 2.73× |

**Use:** the shared list names only 204 of the 3,354 distinct variants the merge covers.

## Material shaders (not built)

The same grouping turns `material.bfsha`'s 4,543 fragment shaders into 17 functions. The largest holds 1,930 variants,
about 2.9M lines. 3,710 of the variants would need a non-inlined function. The list's render pipelines with these
shaders would drop from 12,144 to 8,651. From the agl trend a function that size would cost about 3× or more on the
material passes, about 12% of the frame. Chunks of about 10 variants might stay near parity, but that is not measured.

## Considered Options

- **A permanent ubershader** (hand-written or merged): it fails the bar of being no slower than the Ryujinx path,
  except for programs of up to ~10 variants, where there is little to save.
- **One source, specialized per variant** (macro values baked in, or function constants): it keeps GPU parity but saves
  no library or pipeline compile.
- **Hybrid, as in Dolphin:** a merged function draws while the variant's own pipeline compiles in the background.
  - What it gives: exact output makes the switch invisible. It would let the warm-up skip the ~3,150 agl variants the
    list doesn't name without a stall when one is first drawn.
  - What it costs: every drawn variant is still compiled, and the stand-in pipelines come on top. The large ones take
    seconds each and would have to be built at warm-up.
  - Not built.
- **Warm only listed variants, with no stand-in:** it saves the same warm-up work. An unlisted variant then stalls on its
  first draw on a Mac, or is skipped on iPhone and iPad.

## Consequences

- If this is revisited, the variants of an agl program can be mapped mechanically. The package (`.sharcb`, magic
  `BAHS`) holds two lists, each starting with a `<u32 size, u32 count>` header: the binary entry table first, then the
  program list.
  - Each binary entry is:

    ```
    <u32 size, u32 stage, u32, u32 size − 16, u64 code offset in the pool, u32 control size, i32 control offset>
    ```

    The control offset counts from the u64. The entries hash to the runtime's shader key as
    `prepare_shader_seed.py sharcb_shaders` hashes them.
  - Each program is:

    ```
    <u32 size, u32 name length, u32 stage mask (3 vertex + fragment, 8 compute), u32 base, name>
    ```

    It is followed by three macro sections, each `<u32 size, u32 count>`. The first holds the macros that make
    variants: `<u32 size, u32 name length, u32 value count, u32 default, name, values>`.
  - A variant's index counts through the macro values, last macro fastest. Its shaders are the entries from
    `base + variant × stages in the mask`, one per stage.

  All 12 packages parse with every entry accounted for: 329 programs, 5,431 macro combinations, 4,103 distinct shaders.
- A merge has to keep these details or it stops being exact:
  - each variant's compiler constants (`c1`) embedded as exact bits, the whole bank when it is indexed at run time;
  - its constant buffers cast back to its own struct;
  - helper definitions emitted once;
  - a brace initializer inside parentheses kept as one declaration.
- `maxmetal-diff` tests an ubershader unchanged:
  - give every variant's file the ubershader's MSL;
  - pass the variant index as a `c1`-kind binding on a bank the variants don't use, filled from the reflection's `c1`;
  - add a pass with LUT samples replaced by their coordinates;
  - put the loop cap into the body functions in test builds, since the tool caps only `main0`'s loops.

  With the sides swapped, a binding the ubershader adds for another variant shows as "bound by one side only". That is
  not a value difference.

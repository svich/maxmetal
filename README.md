# maxmetal

Translates Nintendo Switch shader binaries (Maxwell, SM 5.x) straight to Metal Shading Language, or Vulkan GLSL.
A C library (`libmaxmetal`) and a command-line tool (`maxmetal`).

## Why

Switch games ship their shaders as Maxwell GPU machine code, and on a Mac, iPhone or iPad every one of them has to
become Metal before it can draw. The established route is an emulator's: Ryujinx decodes the binary into its own IR,
optimizes it and emits SPIR-V, then SPIRV-Cross turns the SPIR-V into MSL. That is two compilers and an intermediate
language per shader, one of them written in C#.

maxmetal does it in one step: Maxwell in, MSL out, in plain C with no dependencies and no SPIR-V.

- **On the device.** It builds for iPhone and iPad as well as the Mac, so shaders can be translated on the device
  itself, as the game asks for them, and compiled by Metal there.
- **No IR, no optimizer of its own.** Ryujinx's shader pipeline translates into its own IR, runs optimization passes
  on it and generates SPIR-V for SPIRV-Cross to turn into MSL. maxmetal skips all of that: Metal's compiler is a full
  optimizing compiler and does that work on the MSL, so the GPU code comes out as fast as Ryujinx's, and sometimes
  faster. With one level of translation instead of three there is none of the generated boilerplate the compiler has
  to see through, and room for targeted optimizations Ryujinx's general pipeline can't make: a global memory access,
  for example, goes straight to the one storage buffer data flow found for it, unchecked as in Ryujinx.
- **Same results.** It aims for the emulator route's results, not just plausible ones: on a real game's shader set,
  31305 of 31307 variants give bit-identical GPU output to Ryujinx + SPIRV-Cross (the other two: a mip selection in
  divergent control flow, a shader whose own stores race). The heaviest shaders of the game's frame take 9–27% less
  GPU time than the Ryujinx path's ([ADR 0003](docs/adr/0003-speedups-over-ryujinx-are-bit-exact-rewrites.md)). Its
  NVN mode emits the binding layout SPIRV-Cross would, so it can take that pipeline's place without changing the
  renderer.

Two binding contracts:

- its own: constant buffers, global memory and textures at fixed buffer / texture indices (`include/maxmetal/maxmetal.h`);
- NVN (`ShaderKey.nvn`): every resource in one argument buffer at `[[buffer(0)]]` with SPIRV-Cross's names and
  access forms, plus a JSON reflection: the layout of Ryujinx + SPIRV-Cross output.

## Origin

maxmetal is built on the Maxwell -> MSL translator of [LAS Recomp](https://github.com/peiikai/LASRecomp), Peiikai's
static recompilation of *The Legend of Zelda: Link's Awakening* (`runtime/nvn/maxwell/` at commit `993774b`, MIT),
which covers what that one game needs. maxmetal extends it to the full shader set of a much larger game: texture
gathers and queries, bindless images, FP64, video ops, atomics and more, structured control flow in place of a
`switch (pc)` state machine, the NVN binding layout, and global memory resolved to storage buffers by data flow.

Ryujinx's shader pipeline (its instruction decoders, IR translation and passes such as GlobalToStorage) is the
reference: where hardware behaviour is unclear, maxmetal does what Ryujinx does, and `maxmetal-diff` checks the two
against each other on the GPU. The instruction bit layouts come from Ryujinx's decoders, by way of LAS Recomp, and the
GPU documentation from [envytools](https://github.com/envytools/envytools).

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
cmake --install build --prefix /usr/local   # optional
```

Produces `build/libmaxmetal.a` (`-DBUILD_SHARED_LIBS=ON` for a shared library), `build/maxmetal`, and on macOS
`build/maxmetal-diff`. Other CMake projects can use `add_subdirectory(maxmetal)` or, after install,
`find_package(maxmetal)`, then link `maxmetal::maxmetal`. As a subproject, and for iOS (`-DCMAKE_SYSTEM_NAME=iOS`),
only the library is built by default: `MAXMETAL_BUILD_CLI`, `MAXMETAL_BUILD_DIFF` and `MAXMETAL_BUILD_TESTS` turn
the rest on.

## Library

```c
#include <maxmetal/maxmetal.h>

ShaderKey key = {0};
key.vs_out_mask = 0xffffffffu;
// code: 0x30-byte NVN header, then the SPH (graphics stages) and the instructions
ShaderInfo *si = maxwell_translate(code, size, STAGE_FRAGMENT, &key);
if (si->msl) puts(si->msl);          // entry point "main0"
else fprintf(stderr, "%s\n", si->error);
maxwell_free(si);
```

`ShaderInfo` also reports what the shader binds: constant buffers and their sizes, textures, attributes, outputs,
global memory use. Set `key.glsl` for Vulkan GLSL, `key.nvn` for the NVN binding layout (its reflection in
`si->refl`), `key.features` for the [Link's Awakening features](#links-awakening-features).

## Link's Awakening features

Three extras of the translator's own contract, for LAS Recomp's renderer, chosen by `ShaderKey.features`. All off by
default: plain output, no buffers beyond the contract. NVN output ignores them.

| Flag | Shaders | Reads | Effect |
|---|---|---|---|
| `MAXMETAL_FEAT_RSCALE` (1) | fragment, compute | buffer 18, `float4 rscale[65]` | resolution scale: pixel positions, texel coordinates, UVs and texture sizes are mapped to render targets and textures allocated at another resolution than the Switch's |
| `MAXMETAL_FEAT_TINT` (2) | fragment, writing a float colour target 0 | buffer 19, `float4 ltint[4]` | per-draw tint of the final colour: `ltint[0].w` > 0 highlights (a colour plus glow), < 0 recolours (an HSV shift in up to two hue windows), 0 leaves it alone |
| `MAXMETAL_FEAT_LAS` (4) | compute | - | Link's Awakening's light-culling shader, recognised by its instructions, made right at wide aspect ratios |

GLSL takes the buffers as uniform blocks at bindings 18 and 19. `ShaderInfo.uses_rscale` / `uses_tint` say whether
a shader reads one; bind it then. `rscale[0]` is the render target's scale (`.xy`) and offset (`.zw`), `rscale[1 + i]`
texture i's allocation scale (`.xy`) and the part of it its contents fill (`.zw`): `(1, 1, 0, 0)` and `(1, 1, 1, 1)`
change nothing, nor does an all-zero `ltint`. `key.flip_x` (mirror mode) implies `MAXMETAL_FEAT_RSCALE`: the render
target's width is `rscale[65].x`.

## CLI

```
maxmetal translate [--glsl] [--features N] <vs|ps|cs> <code> [-o <out>]  one shader's MSL (GLSL) on stdout or in <out>
maxmetal probe [--all] [--features N] <out dir> <vs|ps|cs> <code>...     translate many: "ok <name> <insts>" / "fail <name> <error>"
maxmetal service --out <dir> --chain <name>                              NVN translation service (JSON lines on stdin)
maxmetal request <request.json> --out <dir> --chain <name>               one service request
```

`<code>` is a shader cache code file: graphics code from the SPH on, compute code after its 0x100-byte header.
`probe --all` lists every unsupported instruction instead of stopping at the first. `--features N` sets
`ShaderKey.features` (the flags summed: 7 for all three).

The service reads one JSON request per line (`{"variant", "stage", "code": path, "c1": hex, "tex": {slot: type},
"local": [x, y, z], ...}`), writes `<out>/<variant>_b.metal` and `<variant>_b.json`, and replies `{"ok": true}` or
`{"ok": false, "error": "..."}`. It also accepts `maxmetal --service --spirv-cross <ignored> --out <dir> --chain <name>`,
the arguments of a Ryujinx + SPIRV-Cross translation service, so it can be started in that one's place.

`"hw_layer_clamp": true` (`NvnKey.hw_layer_clamp`) drops the `min(layer, get_array_size() - 1)` on the array layer of
`sample`, `gather` and `sample_compare`, which saves 1–6% of the GPU code of a shader that samples arrays. The GPU then
has to clamp an out-of-range layer to the last one itself, as Maxwell does. Metal's specification doesn't say what
happens. Checked GPUs: Apple M4 and A15. Set it only for GPU families checked. Texel reads (`read`) are unaffected.
On an unchecked GPU, an out-of-range layer could sample something else. In-range layers give the same result either
way. [ADR 0003](docs/adr/0003-speedups-over-ryujinx-are-bit-exact-rewrites.md) has the probe that checks a GPU.

## Tests

```sh
cmake --build build && ctest --test-dir build --output-on-failure
MAXMETAL_CORPUS=<shader cache dir> ctest --test-dir build -R corpus --output-on-failure
```

- `translate`: small hand-assembled programs (`tests/test_translate.c`: vertex, fragment and compute; NVN, plain
  and GLSL, with and without the Link's Awakening features; branches, loops, discard, textures, shared and global memory) against their expected output in
  `tests/golden`. After an intended change, `MAXMETAL_UPDATE_GOLDEN=1 build/test_translate tests/golden build/tests-out`
  rewrites them: review the diff.
- `metal_compile`: those outputs through the Metal compiler.
- `corpus`: every shader of a shader cache directory (`<variant>.code` + `<variant>_b.json`) translated, compiled,
  and compared with `tests/corpus-baseline.txt` (hashes only: no game data in the repository). Skipped without
  `MAXMETAL_CORPUS`.
  After an intended change, `tests/corpus.py --corpus <dir> --update` rewrites the baseline: its diff names the
  shaders whose output changed.

## maxmetal-diff (macOS)

```
maxmetal-diff [--time N] <ryujinx dir> <maxmetal dir> <variant>...
```

Runs both translations of each variant on the GPU with the same random inputs, bound by their reflections, and
compares outputs: exact, close, different, capped or skipped. `--time N` also reports GPU time. Random inputs can
make shaders loop forever, so loops are capped (`MAXMETAL_DIFF_LOOP_CAP`, default 4096, all of a run's loops together;
`MAXMETAL_DIFF_LOOP_CAP_ENTRY=N` also stops each loop N iterations after it is entered, so equivalent loops stop at
the same iteration on both sides) and every run times out after `GPU_TIMEOUT` seconds (default 20). A variant that
hits the cap and differs runs again with its buffers' words integers below 16 instead of floats (`inputs=ints`): loop
counts read from them stay small and its loops end. Even so, run it one process at a time: a GPU hang resets the
display for the whole Mac. Other knobs: `MAXMETAL_DIFF_DUMP=<dir>`, `MAXMETAL_DIFF_ONE_LEVEL=1`,
`MAXMETAL_DIFF_COMPILE_ONLY=1`, `MAXMETAL_DIFF_SEED=<text>` (other random inputs), `MAXMETAL_DIFF_INTS=N` (integers
below N for every variant), `CS_TIME_GROUPS`, `CS_TIME_SCALE`, and for `--time` `MAXMETAL_DIFF_TIME_SIZE` (the
fragment target's side, default 32) and `MAXMETAL_DIFF_TIME_INSTANCES` (instances of the 64 vertices, default 1).
`MAXMETAL_DIFF_ARCHIVE=<dir>` also saves each pipeline's GPU binary there (`<variant>.<side>.bin`, a binary archive).
The size of its code screens a change cheaply, but GPU time doesn't always follow it
([ADR 0003](docs/adr/0003-speedups-over-ryujinx-are-bit-exact-rewrites.md)). With `MAXMETAL_DIFF_COMPILE_ONLY=1` as well, the
pipelines are built and saved but never run (`fail <variant> build: ...` if one doesn't build): code sizes for any number
of variants with no risk of a GPU hang.

With the display active, a shader's GPU time can vary 3× from one process to the next, so comparisons need these
`--time` options:
- `MAXMETAL_DIFF_TIME_PAIRED=N` (fragment and vertex shaders):
  - each side's render passes take turns: N of each, about 4 ms apiece, after about 100 ms of warming up;
  - each side reports its lower quartile;
  - repeated runs on one shader agree within about 1%, or 4–9% for memory-bound shaders.
- `MAXMETAL_DIFF_TIME_NODUMP=1` (vertex shaders): time the function as it is, without the stores that dump its outputs,
  and read the outputs with a fragment function that sums them. In `830d912d` the dump's 34 stores per vertex were a
  quarter of the time at 256 instances. With 1024 instances, paired, A/A runs agree within about 1% (one shader in ten: 3%).
- `MAXMETAL_DIFF_TIME_ROUNDS=N`: the other stages' medians over N rounds, the sides alternating which goes first.
- `MAXMETAL_DIFF_TIME_ONEPASS=1`: all timed draws in one render pass.
- `MAXMETAL_DIFF_TIME_LOG=1`: every round's times, on stderr.

## Environment

| Variable | Effect |
|---|---|
| `MAXMETAL_STATE_MACHINE=1` | NVN output: always the `switch (pc)` state machine, no structured control flow |
| `MAXMETAL_SAVE_MSL=1` | comment each instruction's pc and word in the output |
| `MAXMETAL_NO_DISCARD=1` | debug: KIL does not discard |
| `MAXMETAL_BRX_ALL_LABELS=1` | label every instruction as a BRX target |
| `MAXMETAL_VK_EXACT_H2F=1` | GLSL: half -> float by bits in every stage |

## License

MIT (`LICENSE`): LAS Recomp's code © Peiikai, the rest © Aleksandr Svidchenkov. Ryujinx's MIT notice (© Ryujinx Team
and Contributors) is kept in `licenses/Ryujinx.txt`, as LAS Recomp keeps it, for the parts modelled on its decoders.

Nintendo Switch, NVN and The Legend of Zelda are trademarks of Nintendo. maxmetal is not affiliated with or endorsed
by Nintendo, and this repository contains no game files or keys: shaders come from the user's own copy.

# Vertex inputs stay on Metal's vertex descriptor

A vertex function's inputs are `[[stage_in]]` attributes that the renderer feeds through a `MTLVertexDescriptor`, so it
needs one pipeline per vertex layout. We measured two alternatives against the Tears of the Kingdom warm list (67,462
render pipelines, MacNativeGames `games/totk/assets/shader_list.tsv`):
- Vertex pulling: `main0` fetches its own inputs, with formats, offsets, strides and step given per draw.
- Metal 4 flexible pipelines.

We kept the descriptor. Pulling gives bit-identical results, but it makes the vertex stage 1.5–2× slower on the GPU and
saves no compile time. Flexible colour state would merge 4% of the pipelines.

## Considered Options

- **Metal 4 flexible render pipelines.** Colour formats, blend and write mask are left unspecialized, then
  `newRenderPipelineStateBySpecializationWithDescriptor` fills them in. 64,758 pipelines would be left. Within a
  vertex/fragment shader pair it is the vertex layout that varies: 18,805 of the 32,301 extra pipelines differ only there.
- **Formats in the function, offsets / strides / step per draw:** 62,556 pipelines (−7%). The formats are what vary.
- **Vertex pulling.** It leaves 40,725 pipelines, but that count overstates the saving. Metal caches compiled stages per
  function and vertex descriptor. A pipeline that differs only in layout already reuses its fragment stage and recompiles
  just the vertex stage, at about 0.74× a cold compile. So the vertex stages to compile drop from 60,655 to 35,930.
  Measured on 200 seed vertex shaders, each with a layout its pipelines bind (GPU time for the vertex stage alone, no
  rasterization):

  | Decode | GPU time vs descriptor | Compile per vertex stage |
  |---|---|---|
  | Inlined per input | 1.48× median (p90 2.59×) | 2.2–2.6× |
  | One copy in a loop that is not unrolled | 2.07× | 1.42× |

  Varyings were bit-identical on all 200. First-run compile time comes out about even, and the GPU time fails the bar
  of being no slower than the Ryujinx path.

## Consequences

- Not measured: a pulled pipeline per vertex/fragment shader pair could stand in for a new layout while that layout's
  own pipeline compiles in the background. That would avoid a stall in play, not save compiles.
- If pulling is revisited, these are the bits Metal's fetch gives:
  - Normalized formats give a correctly rounded `c / (2^n − 1)` (snorm clamped to −1), except `Int1010102Normalized`,
    which gives `c * (1.0f / 511)`.
  - Texture-buffer reads of the R8 / R16 normalized formats match the fetch exactly.
  - Missing components are 0, 0 and 1 (integer 1 for integer formats).

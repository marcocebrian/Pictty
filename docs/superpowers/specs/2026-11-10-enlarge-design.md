# Enlarge: a learned 2× / 4× upscale as an edit

Date: 2026-11-10 · Branch: `editing` · Status: approved design, awaiting spec review

## Why

Small pictures (web photos, old phone shots, crops) look soft when printed or viewed large. A study
in `/tmp/upscale-study` compared Lanczos, Apple's VideoToolbox super-resolution (macOS 26), and
seven open models on 1.5 MP photos enlarged 4× against the real camera originals. Apple's scaler was
indistinguishable from Lanczos. **BHI RealPLKSR 4× real** (Philip Hofmann, CC-BY-4.0) gave a clear,
visible gain on fabric, fur, foliage and printed matter at about 2 s per input megapixel; DAT2 was
slightly more natural but 10× slower; NomosWebPhoto painted grain and garbled text. The model is
weak on human faces and on 24 MP originals, where it can only invent texture.

## What the person sees

- An **Enlarge** button in the toolbar next to Crop (SF Symbol `arrow.up.backward.and.arrow.down.forward.square`),
  which opens a small icon strip like the compare picker: **2×**, **4×**, **Off**. The button is
  highlighted while an enlargement is on.
- Offered only when the picture **as cropped** is **8 MP or less**, and the picture is not HDR.
  Otherwise the button is disabled and its tooltip says why ("Enlarge works on pictures up to 8 MP:
  crop this one first" / "…not for HDR pictures"). A crop that later grows past 8 MP turns Enlarge off
  with a toast.
- The picture's pixel size on screen becomes 2× or 4×; zoom modes, window fit, Before/After, compare,
  the loupe, the status line, Save, Save As and Print all treat it like any other edit.
- While the network runs, the same progress ring the denoiser uses; a toast when done
  ("Enlarged 4× · 1500×1000 → 6000×4000 · 3.8 s").

## How it fits the edit pipeline (approach A)

Enlarge is the **last pixel edit**: original → adjustments (incl. noise reduction) → crop → **enlarge**
→ turn/mirror. Sliders stay as fast as today and denoise runs on real pixels, not enlarged noise.

- New edit state: `ViewerModel.enlarge: Int?` (nil, 2 or 4). Part of `EditState`, `EditSnapshot`,
  `hasPixelEdits`, revert and `endLight` (reset with the other edits when leaving the picture).
- **On screen, fit or smaller:** `present(_:full:session:)` reports `pixelSize × factor` and shows the
  screen-size edit as is (at that size a plain enlargement and the network look the same).
- **Zoomed past screen size** (`requestEditedFull`): the network runs on the full-resolution edited,
  cropped picture; the canvas shows a Lanczos enlargement first, then the network result. After a
  slider or crop change, the network runs again 0.6 s after the last change (debounced), only if
  zoomed in. The result is cached per (url, adjustments, crop, factor) on the `LightSession`.
- **Save / Save As / Print:** `renderEdited` applies the enlargement after the crop, before the turn.
  Export's own "longest side" resize still applies afterwards.

## The engine: `Sources/Pictty/Render/NeuralUpscaler.swift`

Modelled on `NeuralDenoiser`:

- `static let shared`, model `Upscale.mlmodelc` from the bundle, `computeUnits = .cpuAndGPU`,
  `warmUp()` when the Adjust panel or the Enlarge strip opens.
- `func enlarge(_ image: CGImage, factor: Int, progress:) -> CGImage?` — off the main thread,
  cancellable through the session's renderer.
- Input in the picture's own encoded values, 0…1, RGB. Tiles of the converted size with an overlap
  (≥32 input px) blended across it, so no seams. Alpha is enlarged with Lanczos and put back.
- A tile with non-finite values, or far from a Lanczos enlargement of itself, is replaced by that
  Lanczos enlargement (the safeguard the denoiser has).
- **Faces:** `VNDetectFaceRectanglesRequest` on the input; a feathered elliptical mask per face
  (feather ≈ 25 % of the face size) blends the result back to a Lanczos enlargement inside faces.
- **2×:** the 4× result shrunk by half with Lanczos **in linear light** (decode sRGB transfer →
  Lanczos → encode). Measured on the study photos: slightly more of the original's detail kept
  (0.98→1.01, 0.88→0.92, 0.81→0.83 detail ratio), same brightness, visually near identical.
- Wide-gamut and 16-bit pictures go through in their own colour space at float precision; HDR is not
  offered.

## The model: `Models/Upscale.mlpackage`

- Built by `Models/make-upscale-model.py` from `4xBHI_realplksr_dysample_real.safetensors`
  (release `4xBHI_realplksr_dysample_real` of github.com/Phhofm/models): spandrel loads it; DySample
  is rewritten with a constant grid and fixed sizes for conversion; GroupNorm is fed `x / 64` with
  `eps / 64²`.
- Precision: half precision except the 17×17 convolutions, the attention convolutions and the
  upsampler tail, which stay in 32-bit (pure half precision gave NaN and wrong pixels; mixed matched
  PyTorch at 49 dB and was ~20 % faster than PyTorch on MPS).
- **Acceleration work, measured, keep the fastest that matches PyTorch ≥ 45 dB PSNR on the study
  crops:** larger tiles (576 → 768 / 1024), fewer layers kept in 32-bit (e.g. DySample's coordinates
  only, made exact in half precision by computing offsets relative to the pixel), weight-only 8-bit
  palettisation if it does not cost quality. Neural Engine measured slower; GPU only.
- `build.sh` compiles it like `Denoise.mlpackage`; `Models/README.md` gets its credit and licence
  (CC-BY-4.0: "4xBHI_realplksr_dysample_real by Philip Hofmann"), shipped as
  `Upscale-LICENSE.txt` in the app, and listed where the other models are credited.

## Strings

English and Spanish (`Resources/es.lproj/Localizable.strings`, local only): "Enlarge", "Enlarge 2×",
"Enlarge 4×", "Off", the two disabled reasons, the toast, the progress label.

## Testing

- Unit (PicttyCore / app tests): the 8 MP rule on the cropped size; edit order (enlarge after crop,
  before turn) in `renderEdited`; linear-light 2× keeps a flat grey at its level; `EditState`
  changes when the factor changes.
- Model check: the app's Core ML output on the four study inputs against the PyTorch outputs
  (≥ 45 dB), and timing per megapixel printed.
- Dev hooks: `enlarge <0|2|4>` and the existing `dump`, `shot`, `saveto` to check the canvas size,
  zoom, Before/After, Save As and an 8 MP+ crop being refused, in the real app.
- `swift test` passes (95 today).

## Out of scope

Other models, DAT2 "best quality" mode, arbitrary target sizes, enlarging in batch or in Export.

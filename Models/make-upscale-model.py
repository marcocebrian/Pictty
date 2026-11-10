#!/usr/bin/env python3
"""Makes Models/Upscale.mlpackage: Pictty's Enlarge. BHI RealPLKSR 4× "real" by Philip Hofmann
(CC-BY-4.0, github.com/Phhofm/models), a 7.4 M parameter network trained on photos with realistic
noise, blur and JPEG/WebP compression, converted to Core ML for fixed square tiles.

    uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python torch coremltools spandrel safetensors pillow
    gh release download 4xBHI_realplksr_dysample_real -R Phhofm/models -p '4xBHI_realplksr_dysample_real.safetensors'
    .venv/bin/python Models/make-upscale-model.py 4xBHI_realplksr_dysample_real.safetensors Models/Upscale.mlpackage
    .venv/bin/python Models/make-upscale-model.py --check Models/Upscale.mlpackage 4xBHI_realplksr_dysample_real.safetensors <dir of PNGs>

Two rewrites, each giving the same numbers as the original:
- DySample (the upsampler) builds its sampling grid from the tile's size on every call, which Core
  ML's converter cannot follow. For a fixed tile the grid is a constant, computed once here.
- GroupNorm squares its input to find the spread: values in the thousands overflow half precision
  (NaN on the GPU). The normalisation does not change if the input is divided by a constant first,
  so it is fed x / 64, with eps / 64² to keep the result the same.

Precision: the convolutions, nearly all of the work, run in half precision; everything else (the
residual sums, the attention's products, the norms, DySample's coordinates) stays in 32-bit.
Measured against PyTorch on four photos, worst photo:
  all 32-bit                                   69 dB   5.1 s/MP
  convolutions 16-bit, the rest 32-bit         69 dB   1.9 s/MP   <- this
  16-bit but 17×17 convs, attention, upsampler 44 dB   2.5 s/MP   (pure 16-bit: NaN)
  only the products (mul) in 16-bit            42 dB
The sums and products are where half precision goes wrong (busy, bright texture lost 37 dB tiles),
not the convolutions.
--check compares the model with PyTorch on whole pictures, tiled the way Pictty tiles them, and
prints the PSNR between the two (45 dB or more passes) and the time per input megapixel.

The tile and margin are written into the model's metadata ("tile", "margin"); Pictty reads them.
"""
import argparse, glob, os, sys, time
import numpy as np, torch
import torch.nn.functional as F
from safetensors.torch import load_file
from spandrel import ModelLoader


def load(weights, size):
    m = ModelLoader().load_from_state_dict(load_file(weights)).model.eval()
    x = torch.rand(1, 3, size, size)
    with torch.no_grad(): reference = m(x)
    from spandrel.architectures.__arch_helpers.dysample import DySample

    def fixed_forward(self, x):
        offset = self.offset(x) * self.scope(x).sigmoid() * 0.5 + self.init_pos
        B, H, W, S, G = 1, size, size, int(self.scale), int(self.groups)   # plain numbers, not traced sizes
        offset = offset.view(B, 2, -1, H, W)
        # 2·(grid + offset)/n − 1 as (2·grid/n − 1) + offset·(2/n): the large term is a constant.
        coords = self.base + offset * self.scale2
        coords = (F.pixel_shuffle(coords.reshape(B, -1, H, W), S)
                  .view(B, 2, -1, S * H, S * W).permute(0, 2, 3, 4, 1).contiguous().flatten(0, 1))
        out = F.grid_sample(x.reshape(B * G, -1, H, W), coords, mode="bilinear", align_corners=False,
                            padding_mode="border").view(B, -1, S * H, S * W)
        return self.end_conv(out) if self.end_convolution else out

    for mod in m.modules():
        if isinstance(mod, DySample):
            c = torch.arange(size) + 0.5
            grid = torch.stack(torch.meshgrid([c, c], indexing="ij")).transpose(1, 2).unsqueeze(1).unsqueeze(0).float()
            n = torch.tensor([size, size], dtype=torch.float32).view(1, 2, 1, 1, 1)
            mod.base = 2 * grid / n - 1
            mod.scale2 = 2 / n
            mod.forward = fixed_forward.__get__(mod)
    K = 64.0

    def safe_group_norm(self, x):
        return F.group_norm(x / K, self.num_groups, self.weight, self.bias, self.eps / (K * K))
    for mod in m.modules():
        if isinstance(mod, torch.nn.GroupNorm): mod.forward = safe_group_norm.__get__(mod)
    with torch.no_grad(): d = float((m(x) - reference).abs().max())
    print(f"rewritten for {size}² tiles, max difference from the original: {d:.2e}")
    assert d < 1e-3
    return m, x


def convert(weights, out, tile, margin, half_types, quantize):
    import coremltools as ct
    size = tile + 2 * margin
    m, x = load(weights, size)
    traced = torch.jit.trace(m, x)
    ml = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=x.shape)], outputs=[ct.TensorType(name="output")],
                    compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in half_types),
                    minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram",
                    compute_units=ct.ComputeUnit.CPU_AND_GPU)
    if quantize:
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
        ml = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
    ml.short_description = "4xBHI_realplksr_dysample_real by Philip Hofmann (CC-BY-4.0), for Pictty's Enlarge"
    ml.user_defined_metadata["tile"] = str(tile)
    ml.user_defined_metadata["margin"] = str(margin)
    ml.save(out)
    print("saved", out, f"tile {tile} + {margin} margin, 16-bit: {','.join(sorted(half_types))}, 8-bit weights: {quantize}")


def tiled(run, im, tile, margin):
    """`im` (H×W×3, 0…1) enlarged 4× tile by tile; edges reflected so every tile has the same size."""
    H, W, _ = im.shape
    pad = np.pad(im, ((margin, margin + tile), (margin, margin + tile), (0, 0)), mode="reflect")
    out = np.zeros((H * 4, W * 4, 3), np.float32)
    for y in range(0, H, tile):
        for x in range(0, W, tile):
            r = run(np.ascontiguousarray(pad[y:y + tile + 2 * margin, x:x + tile + 2 * margin].transpose(2, 0, 1)[None]))
            r = r[0].transpose(1, 2, 0)
            h, w = (min(y + tile, H) - y) * 4, (min(x + tile, W) - x) * 4
            out[y * 4:y * 4 + h, x * 4:x * 4 + w] = r[margin * 4:margin * 4 + h, margin * 4:margin * 4 + w]
    return np.clip(out, 0, 1)


def check(package, weights, folder):
    import coremltools as ct
    from PIL import Image
    ml = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    tile, margin = int(ml.user_defined_metadata["tile"]), int(ml.user_defined_metadata["margin"])
    dev = torch.device("mps")
    ref = ModelLoader().load_from_state_dict(load_file(weights)).model.eval().to(dev)

    def torch_run(t):
        with torch.inference_mode(): return ref(torch.from_numpy(t).to(dev)).cpu().numpy()
    worst, times = 99.0, []
    for i, p in enumerate(sorted(glob.glob(os.path.join(folder, "*.png")))):
        im = np.asarray(Image.open(p).convert("RGB"), np.float32) / 255
        coreml_run = lambda t: ml.predict({"input": t})["output"]
        if i == 0: tiled(coreml_run, im[:tile, :tile], tile, margin)   # warm-up
        t0 = time.time(); a = tiled(coreml_run, im, tile, margin); dt = time.time() - t0
        b = tiled(torch_run, im, tile, margin)
        bad = int((~np.isfinite(a)).sum())
        psnr = 10 * np.log10(1 / max(np.mean((np.nan_to_num(a) - b) ** 2), 1e-12))
        mp = im.shape[0] * im.shape[1] / 1e6
        times.append(dt / mp); worst = min(worst, psnr if bad == 0 else 0)
        print(f"{os.path.basename(p)} {im.shape[1]}×{im.shape[0]}: {psnr:.1f} dB vs PyTorch, {bad} non-finite, {dt:.2f} s ({dt / mp:.2f} s/MP)")
    ok = worst >= 45
    print(f"{'PASS' if ok else 'FAIL'}: worst {worst:.1f} dB, {np.mean(times):.2f} s per input MP")
    return ok


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--check", action="store_true")
    a.add_argument("paths", nargs="+")
    a.add_argument("--tile", type=int, default=512)
    a.add_argument("--margin", type=int, default=32)
    a.add_argument("--half", default="conv", help="op types computed in 16-bit; the rest stay 32-bit")
    a.add_argument("--quantize", action="store_true")
    o = a.parse_args()
    if o.check:
        sys.exit(0 if check(*o.paths) else 1)
    convert(o.paths[0], o.paths[1], o.tile, o.margin, {k for k in o.half.split(",") if k}, o.quantize)

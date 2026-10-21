#!/usr/bin/env python3
"""Makes Models/Denoise.mlpackage: NAFNet (MIT, megvii-research/NAFNet), width 32, trained on SIDD,
converted to Core ML for 512 × 512 tiles, weights quantised to 8 bits (29 MB; within 0.006 of fp16).

    uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python "torch==2.7.0" coremltools
    curl -L https://raw.githubusercontent.com/megvii-research/NAFNet/main/basicsr/models/archs/NAFNet_arch.py -o NAFNet_arch.py
    curl -L "https://drive.usercontent.google.com/download?id=1lsByk21Xw-6aW7epCwOQxvm6HYCQZPHZ&export=download&confirm=t" -o NAFNet-SIDD-width32.pth
    .venv/bin/python tools/make-denoise-model.py NAFNet_arch.py NAFNet-SIDD-width32.pth

Measured on an M5 Pro: 21 ms a tile on the GPU (Core ML, CPU and GPU), about 1.3 s for 12 megapixels.
"""
import sys
import torch, coremltools as ct
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

TILE = 512
arch, weights = sys.argv[1], sys.argv[2]

class LayerNorm2d(torch.nn.Module):
    # NAFNet's own LayerNorm2d is a custom autograd function, which does not trace.
    def __init__(self, c, eps=1e-6):
        super().__init__()
        self.weight = torch.nn.Parameter(torch.ones(c)); self.bias = torch.nn.Parameter(torch.zeros(c)); self.eps = eps
    def forward(self, x):
        mu = x.mean(1, keepdim=True); var = (x - mu).pow(2).mean(1, keepdim=True)
        return self.weight.view(1, -1, 1, 1) * (x - mu) / (var + self.eps).sqrt() + self.bias.view(1, -1, 1, 1)

src = '\n'.join(l for l in open(arch).read().split('\n') if not l.startswith('from basicsr'))
src = src.replace('class NAFNetLocal(Local_Base, NAFNet):', 'class _Unused:')
src = src.replace('return x[:, :, :H, :W]', 'return x')  # fixed tiles: nothing to crop
ns = {'LayerNorm2d': LayerNorm2d}
exec(compile(src, 'NAFNet_arch.py', 'exec'), ns)
m = ns['NAFNet'](img_channel=3, width=32, middle_blk_num=12, enc_blk_nums=[2, 2, 4, 8], dec_blk_nums=[2, 2, 2, 2])
sd = torch.load(weights, map_location='cpu', weights_only=False)
m.load_state_dict(sd.get('params', sd), strict=True)
m.check_image_size = lambda x: x  # tiles are a multiple of 16
m.eval()
x = torch.rand(1, 3, TILE, TILE)
with torch.no_grad():
    traced = torch.jit.trace(m, x)
ml = ct.convert(traced, inputs=[ct.TensorType(name='input', shape=x.shape)], outputs=[ct.TensorType(name='output')],
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15, convert_to='mlprogram')
ml = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric', dtype='int8')))
ml.short_description = 'NAFNet width 32 (SIDD), MIT licence, megvii-research/NAFNet. Input and output: sRGB-encoded RGB, 0…1.'
ml.save('Models/Denoise.mlpackage')
print('Models/Denoise.mlpackage')

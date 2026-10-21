#!/usr/bin/env python3
"""Makes Models/Denoise.mlpackage: SCUNet (Apache 2.0, cszn/SCUNet), the "real GAN" weights, trained
on realistic camera noise, JPEG and their mixtures, converted to Core ML for 512 × 512 tiles, weights
quantised to 8 bits (20 MB; a quarter of an 8-bit level from fp16 on average).

    uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python "torch==2.7.0" coremltools einops timm thop
    curl -L https://raw.githubusercontent.com/cszn/SCUNet/main/models/network_scunet.py -o network_scunet.py
    curl -L https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_gan.pth -o scunet_color_real_gan.pth
    .venv/bin/python Models/make-denoise-model.py network_scunet.py scunet_color_real_gan.pth

Core ML cannot follow SCUNet's window attention as written (its masks and position table are made
from tensor shapes at run time), so it is rewritten here for fixed tiles, giving the same numbers:
sizes become constants, the relative position table is computed once, the shifted windows' mask is
applied only to the last row and column of windows (the only ones that straddle the wrap-around; a
full mask would take 33 MB a block), einsum becomes matrix products and roll becomes slicing.

Measured on an M5 Pro: about 100 ms a tile on the GPU (the Neural Engine takes seconds).
"""
import importlib.util, sys
import torch, coremltools as ct
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

TILE = 512
arch, weights = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('network_scunet', arch)
N = importlib.util.module_from_spec(spec); spec.loader.exec_module(N)


def roll2(x, s, H, W):
    # torch.roll over dims 1 and 2 by s, as slicing.
    s1, s2 = s % H, s % W
    x = torch.cat([x[:, -s1:], x[:, :-s1]], 1) if s1 else x
    return torch.cat([x[:, :, -s2:], x[:, :, :-s2]], 2) if s2 else x


def attention(self, x):
    p = self.window_size
    # Sizes are fixed per tile: recorded on the first (untraced) run, constants in the trace.
    if not hasattr(self, '_dims'): self._dims = tuple(int(v) for v in x.shape)
    _, H, W, C = self._dims
    hw, ww, n, nh = H // p, W // p, p * p, self.n_heads
    if self.type != 'W': x = roll2(x, -(p // 2), H, W)
    x = x.reshape(hw, p, ww, p, C).permute(0, 2, 1, 3, 4).reshape(hw, ww, n, C)
    qkv = self.embedding_layer(x).reshape(hw * ww, n, 3 * nh, self.head_dim).permute(2, 0, 1, 3)
    q, k, v = (qkv[i * nh:(i + 1) * nh].reshape(nh, hw, ww, n, self.head_dim) for i in range(3))
    if not hasattr(self, '_rel'):
        self._rel = self.relative_embedding().detach()[:, None, None]
        if self.type != 'W':
            m = self.generate_mask(hw, ww, p, shift=p // 2).float().reshape(hw, ww, n, n) * -1e4
            self._row, self._col = m[-1][None], m[:, -1][None]

    def attend(q, k, v, bias):
        s = torch.matmul(q, k.transpose(-1, -2)) * self.scale + bias
        return torch.matmul(torch.softmax(s, dim=-1), v)

    out = attend(q, k, v, self._rel)
    if self.type != 'W':
        rel = self._rel[:, 0]
        out = torch.cat([out[:, :-1], attend(q[:, -1], k[:, -1], v[:, -1], rel + self._row)[:, None]], 1)
        out = torch.cat([out[:, :, :-1], attend(q[:, :, -1], k[:, :, -1], v[:, :, -1], rel + self._col)[:, :, None]], 2)
    out = self.linear(out.permute(1, 2, 3, 0, 4).reshape(hw, ww, n, C))
    out = out.reshape(hw, ww, p, p, C).permute(0, 2, 1, 3, 4).reshape(1, H, W, C)
    return roll2(out, p // 2, H, W) if self.type != 'W' else out


def tile(self, x0):
    # Tiles are a multiple of 64 already: no padding, no crop.
    x1 = self.m_head(x0); x2 = self.m_down1(x1); x3 = self.m_down2(x2); x4 = self.m_down3(x3)
    x = self.m_body(x4); x = self.m_up3(x + x4); x = self.m_up2(x + x3); x = self.m_up1(x + x2)
    return self.m_tail(x + x1)


m = N.SCUNet(in_nc=3, config=[4] * 7, dim=64)
m.load_state_dict(torch.load(weights, map_location='cpu'), strict=True)
m.eval()
x = torch.rand(1, 3, TILE, TILE) * 0.8 + 0.1
with torch.no_grad():
    reference = m(x)
    N.WMSA.forward, N.SCUNet.forward = attention, tile
    rewritten = m(x)
    assert float((rewritten - reference).abs().max()) < 1e-4, 'the rewrite must give the same numbers'
    traced = torch.jit.trace(m, x)
ml = ct.convert(traced, inputs=[ct.TensorType(name='input', shape=x.shape)], outputs=[ct.TensorType(name='output')],
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15, convert_to='mlprogram')
ml = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric', dtype='int8')))
ml.short_description = ('SCUNet real GAN (Zhang et al. 2023), Apache 2.0, cszn/SCUNet. '
                        'Input and output: sRGB-encoded RGB, 0…1, 512 × 512.')
ml.save('Models/Denoise.mlpackage')
print('Models/Denoise.mlpackage')

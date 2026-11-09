"""greycard's learned demosaic and denoise ("best", v20) as a Core ML model for Pictty.

greycard (Jess Olmstead, https://github.com/jessolmstead/greycard, GPL-3.0-or-later) publishes the
network as ONNX on Hugging Face (jessolmstead/greycard-denoise, denoise-v20.onnx, sha256
c20aed71a45b2a984570e09d8456c54ce8eff43a334b54c7ebb480c21518f9be). Core ML no longer reads ONNX,
so this script rebuilds the graph op for op with coremltools' MIL builder, in half precision, for
the one tile shape Pictty runs (608 x 608 packed: 1024 photosites and a 96-photosite margin each
side), then checks it against ONNX Runtime.

    uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python coremltools onnx onnxruntime numpy
    .venv/bin/python Models/make-sensor-network.py denoise-v20.onnx Models/SensorNetwork.mlpackage 608

Measured: largest difference from ONNX Runtime 0.014, mean 0.002, in the network's own units
(the noise is 1 there); 9.7 MB.
"""
import sys, numpy as np, onnx
from onnx import numpy_helper, helper
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

src, dst, side = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = onnx.load(src); g = m.graph
init = {t.name: numpy_helper.to_array(t) for t in g.initializer}
attrs = lambda n: {a.name: helper.get_attribute_value(a) for a in n.attribute}

@mb.program(input_specs=[mb.TensorSpec(shape=(1, 4, side, side), dtype=types.fp32)], opset_version=ct.target.macOS13)
def prog(packed):
    vals = {"packed": mb.cast(x=packed, dtype="fp16")}   # MIL vars, half precision throughout
    consts = dict(init)         # numpy values known at build time
    def v(name):
        if name in vals: return vals[name]
        return consts[name]
    for n in g.node:
        a = attrs(n); o = n.output[0]; t = n.op_type
        if t == "Constant":
            consts[o] = numpy_helper.to_array(a["value"]); continue
        if t == "Shape":
            consts[o] = np.array(vals[n.input[0]].shape, dtype=np.int64); continue
        if t == "Gather":
            consts[o] = np.take(consts[n.input[0]], consts[n.input[1]], axis=a.get("axis", 0)); continue
        if t == "Unsqueeze":
            consts[o] = np.expand_dims(consts[n.input[0]], tuple(consts[n.input[1]].tolist())); continue
        if t == "Concat" and all(i in consts for i in n.input):
            consts[o] = np.concatenate([consts[i] for i in n.input], axis=a["axis"]); continue
        if t == "ConstantOfShape":
            shape = tuple(int(x) for x in consts[n.input[0]])
            # Zero planes the size of the mosaic, made from the input times 0 so that no pass folds
            # them into a stored constant (megabytes of zeros in the file).
            mosaic = vals[[k for k in vals if "DepthToSpace" in k][0]]
            assert tuple(mosaic.shape[2:]) == shape[2:] and mosaic.shape[1] == 1, (mosaic.shape, shape)
            zero = mb.mul(x=mosaic, y=np.float16(0))
            vals[o] = zero if shape[1] == 1 else mb.concat(values=[zero] * shape[1], axis=1); continue
        if t == "Conv":
            w = init[n.input[1]].astype(np.float16); b = init[n.input[2]].astype(np.float16) if len(n.input) > 2 else None
            p = a.get("pads", [0, 0, 0, 0])
            vals[o] = mb.conv(x=v(n.input[0]), weight=w, bias=b, strides=a.get("strides", [1, 1]), pad_type="custom",
                              pad=[p[0], p[2], p[1], p[3]], dilations=a.get("dilations", [1, 1]), groups=a.get("group", 1))
        elif t == "LeakyRelu":
            vals[o] = mb.leaky_relu(x=v(n.input[0]), alpha=np.float16(a["alpha"]))
        elif t == "MaxPool":
            vals[o] = mb.max_pool(x=v(n.input[0]), kernel_sizes=a["kernel_shape"], strides=a["strides"], pad_type="valid")
        elif t == "Resize":
            scales = consts[n.input[2]]
            assert a["mode"] == b"nearest" and list(scales[2:]) == [2.0, 2.0], scales
            vals[o] = mb.upsample_nearest_neighbor(x=v(n.input[0]), scale_factor_height=2, scale_factor_width=2)
        elif t == "Concat":
            vals[o] = mb.concat(values=[v(i) for i in n.input], axis=a["axis"])
        elif t == "DepthToSpace":
            assert a["mode"] == b"CRD"
            vals[o] = mb.pixel_shuffle(x=v(n.input[0]), upscale_factor=a["blocksize"])
        else:
            raise SystemExit(f"unhandled {t}")
    return mb.cast(x=vals[g.output[0].name], dtype="fp32", name="rgb")

model = ct.convert(prog, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                   minimum_deployment_target=ct.target.macOS13)
model.short_description = "greycard denoise, best (v20): demosaic and denoise of a variance-stabilized Bayer mosaic. GPL-3.0-or-later, https://github.com/jessolmstead/greycard"
model.save(dst)

# Check against ONNX Runtime on a stabilized-looking input.
import onnxruntime as ort
rng = np.random.default_rng(0)
x = (rng.standard_normal((1, 4, side, side)) + np.linspace(0, 40, side)[None, None, None, :]).astype(np.float32)
want = ort.InferenceSession(src, providers=["CPUExecutionProvider"]).run(["rgb"], {"packed": x})[0]
got = model.predict({"packed": x})["rgb"]
print("shape", got.shape, "max abs err", float(np.abs(got - want).max()), "mean abs err", float(np.abs(got - want).mean()), "range", float(want.min()), float(want.max()))

# Models

`Denoise.mlpackage` is Pictty's noise reduction: **SCUNet** (Zhang, Li, Liang, Cao, Zhang, Tang,
Wen, Timofte and Van Gool, *Practical Blind Image Denoising via Swin-Conv-UNet and Data Synthesis*,
Machine Intelligence Research 2023), the "real GAN" weights its authors trained on realistic camera
noise, JPEG compression and their mixtures, from [cszn/SCUNet](https://github.com/cszn/SCUNet) under
the Apache 2.0 licence (`SCUNet-LICENSE`).

Chosen over NAFNet (SIDD), Restormer, DRUNet and FBCNN, and SCUNet's own PSNR weights, on clean
crops with camera noise, strong noise, noise and JPEG, and film grain from 0.5 to 3 pixels, by
LPIPS: closest to the clean picture as people see it, everywhere. NAFNet left film grain looking
worse than before.

Converted to Core ML for 512 × 512 tiles, weights quantised to 8 bits (20 MB) by
`make-denoise-model.py`, which says how to rebuild it and why the attention is rewritten.
`build.sh` compiles it into the app. Measured on an M5 Pro: about 100 ms a tile on the GPU.

`SensorNetwork.mlpackage` is how Pictty develops camera RAWs: a learned demosaic and denoise on the
sensor's mosaic itself, read by LibRaw (`Sources/LibRaw`), before any demosaic has smeared the noise.
It develops 24 megapixels in 1.3 s. Converted to Core ML for 608 × 608 packed tiles in half precision
(9.7 MB) by `make-sensor-network.py`. SCUNet stays for every other picture, and for RAWs the network
cannot take (Fujifilm X-Trans, linear DNGs such as Apple ProRAW).

Credit: the network is by Jess Olmstead (https://github.com/jessolmstead/greycard), GPL-3.0-or-later;
its licence is `SensorNetwork-LICENSE`, shipped in the app.

`Upscale.mlpackage` is Pictty's Enlarge: **4xBHI_realplksr_dysample_real** by Philip Hofmann, from
[Phhofm/models](https://github.com/Phhofm/models), under the Creative Commons Attribution 4.0 licence
(`Upscale-LICENSE`, shipped in the app). A 7.4 M parameter RealPLKSR network trained on photos with
realistic noise, blur and JPEG/WebP compression.

Chosen over Real-ESRGAN, SPAN, Compact, NomosWebPhoto, Nomos2 and the slower DAT2, and over Apple's
VideoToolbox super-resolution (indistinguishable from Lanczos), on ~1.5 MP photos enlarged 4× and
compared with the camera's own pixels: the clearest real gain on fabric, fur, foliage and print. It
invents texture on 24 MP originals, hence Pictty's 8 MP limit, and is weak on faces, which Pictty
keeps plain.

Converted to Core ML for 576 × 576 tiles (512 kept + 32 of margin) by `make-upscale-model.py`, which
says how to rebuild it and check it against PyTorch. The convolutions run in half precision, the
rest in 32-bit; measured on an M5 Pro, against PyTorch on four photos (worst photo):

| Precision | Match | Speed |
|---|---|---|
| all 32-bit | 69 dB | 5.1 s per input MP |
| **convolutions 16-bit, the rest 32-bit** | **69 dB** | **1.9 s per input MP** |
| 16-bit except 17×17 convolutions, attention and upsampler | 44 dB | 2.5 s per input MP |
| all 16-bit | NaN | — |
| as chosen, 768 tiles | 70 dB | 2.5 s per input MP |
| as chosen, 8-bit weights | 23 dB | 2.0 s per input MP |

The Neural Engine is several times slower for this network; Pictty uses the GPU.

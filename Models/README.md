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

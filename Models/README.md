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

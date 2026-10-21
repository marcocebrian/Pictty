# Models

`Denoise.mlpackage` is Pictty's noise reduction: **NAFNet** (Chen, Chu, Zhang and Sun, *Simple Baselines
for Image Restoration*, ECCV 2022), width 32, trained on SIDD by its authors at Megvii, from
[megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) under the MIT licence
(`NAFNet-LICENSE`).

Converted to Core ML for 512 × 512 tiles, weights quantised to 8 bits (29 MB; within two 8-bit
levels of fp16) by `make-denoise-model.py`, which says how to rebuild it. `build.sh` compiles it
into the app. Measured on an M5 Pro: 21 ms a tile on the GPU, about 2.6 s for 12 megapixels.

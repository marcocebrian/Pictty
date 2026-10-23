<p align="center">
  <img src="https://www.noxdrop.com/img/pictty/icon-256.png" width="128" height="128" alt="Pictty icon">
</p>

<h1 align="center">Pictty</h1>

<p align="center"><b>The good-looking MacOS native technical image viewer.</b><br>
Pictty always draws your picture with the best possible algorithm: the GPU while it moves, Lanczos in linear light the moment it rests. And it edits, on its own GPU engine.</p>

<p align="center">
  <a href="https://www.noxdrop.com/pictty.html#preview"><img src="https://www.noxdrop.com/img/pictty/tour-v5.webp" width="900" alt="Pictty in action: the pixel loupe on a motorcycle engine, the information panel with its histogram, and a wipe comparison. Click for the full one-minute video."></a>
</p>

<p align="center">
  <a href="https://www.noxdrop.com/pictty.html"><img src="https://www.noxdrop.com/img/pictty/download-button.svg" width="300" alt="Download Pictty for Mac"></a>
</p>

<p align="center">Free and open source (GPL-3.0) · macOS 15+ · Liquid Glass · <a href="https://www.noxdrop.com/pictty.html">noxdrop.com/pictty</a></p>

---

## Nothing between you and the picture

<p align="center">
  <img src="https://www.noxdrop.com/img/pictty/clean-v3.webp" width="820" alt="The Pictty window showing one picture and nothing else: the toolbar, file pill and filmstrip have stepped aside.">
</p>

In Best Fit the window takes the shape of the picture. The toolbar, the file pill and the filmstrip float over it in Liquid Glass while you move the pointer, and step aside when you stop. What stays is the picture.

## Four ways to compare

<table>
  <tr>
    <td align="center" width="25%"><img src="https://www.noxdrop.com/img/pictty/grid-v3.webp" alt="Four photos in a grid, pan and zoom in sync."><br><b>Side by side, grid</b><br>Up to four, pan and zoom in sync</td>
    <td align="center" width="25%"><img src="https://www.noxdrop.com/img/pictty/stacked-v3.webp" alt="Two photos stacked top and bottom."><br><b>Stacked</b><br>One above the other</td>
    <td align="center" width="25%"><img src="https://www.noxdrop.com/img/pictty/wipe-v3.webp" alt="A wipe line between the original portrait and a small copy."><br><b>Wipe</b><br>Drag the line between two versions</td>
    <td align="center" width="25%"><img src="https://www.noxdrop.com/img/pictty/blink-v3.webp" alt="Blink showing the second of two versions."><br><b>Blink</b><br>Press B to flip; changes jump out</td>
  </tr>
</table>

## Edit on its own engine

<p align="center">
  <img src="https://www.noxdrop.com/img/pictty/edit-v1.webp" width="820" alt="The Adjust panel beside a sunset over rocks: exposure raised by regions opens up the dark rocks while the sun keeps its light.">
</p>

Press E and the Adjust panel opens beside the picture, with a live histogram on top. Pictty loads the picture once as linear light in 16-bit floating point and runs every slider on the GPU, in Metal, while you drag it. Each slider has one method, picked for what that slider has to do.

| Light | Colour | Detail |
|---|---|---|
| Exposure, by regions | White balance, with Auto and an eyedropper | Texture |
| Contrast | Vibrance, by regions | Clarity |
| Brightness, by regions | Saturation, by regions | Sharpening |
| Highlights, local Laplacian | Colour grading on three wheels | Noise reduction, a neural network on the GPU |
| Shadows | | |
| Dehaze | | |

<table>
  <tr>
    <td align="center" width="50%"><img src="https://www.noxdrop.com/img/pictty/noise-v1.webp" alt="A rhododendron garden at 100 %: the original's noise on the left of the line, after noise reduction on the right."><br><b>Noise reduction</b><br>Noise and grain gone, detail kept</td>
    <td align="center" width="50%"><img src="https://www.noxdrop.com/img/pictty/crop-v1.webp" alt="The crop frame with rounded corners on a motorcycle engine, and the crop toolbar."><br><b>Crop</b><br>Ratios for social, screens and print, rounded corners</td>
  </tr>
</table>

Crop with ratios and rounded corners, flip to the original with Y, and save over the file in its own format and quality, or as anything else. How each one works is [below](#editing).

## Features

- **High-quality preview first**: a preview made for your screen with the best algorithms, turning seamlessly into the full-resolution picture when the zoom needs it.
- **Pixel-exact at rest**: when the picture rests, the visible region is redrawn with Lanczos at one picture pixel per screen pixel, placed to a tenth of a pixel.
- **Linear-light shrinking**: reductions average **real light**, not the stored numbers, so fine detail keeps its brightness.
- **Clean enlarging**: up to 300 % with Lanczos; beyond that, smooth GPU filtering.
- **Full refresh rate in motion**: the **GPU** moves, zooms and rotates the picture through Core Animation, on whole device pixels.
- **Real RAW**: Apple's RAW engine develops every camera file; the camera's embedded preview shows at once.
- **True HDR**: gain maps, PQ and HLG with extended dynamic range and the display's live headroom.
- **Giant pictures**: **every pixel** past the GPU's 16,384-pixel texture limit, at 100 % and beyond.
- **Huge folders, instantly**: a folder of 2,000+ photos is ready in milliseconds, and thumbnails load in parallel without weighing your Mac down.
- **Formats**: JPEG, HEIC, AVIF, JPEG XL, WebP, PNG, TIFF, GIF (animated), BMP, OpenEXR, PSD, TGA, SVG and RAW from hundreds of cameras.
- **Pixel loupe** with RGB values and the hex colour; ⌥-click copies it.
- **Histogram and clipping warnings**: blown highlights in red, blocked shadows in blue.
- **Information panel**: camera, lens, exposure, size, colour profile, dates, location and provenance.
- **Compare** up to four pictures: side by side, stacked, grid, wipe and blink, with synced pan and zoom.
- **Adjust**: light, colour and detail on Pictty's own GPU engine, live on the picture at any zoom.
- **Noise reduction** by a neural network on this Mac's GPU, at the scale the picture's grain needs.
- **Crop** with ratios for social, screens and print, and rounded corners.
- **Save and Save As**: over the file in its own format and quality, turns without re-encoding, or as JPEG, HEIC, AVIF, PNG, TIFF, OpenEXR and more, with the file's size shown before you save.
- **Print**: the picture on your printer's own papers, dragged into place, at photo-lab sizes or your own, with its quality in ppi and an offer to upscale when the picture is short of pixels.
- **Five zoom modes**: Actual Size, Best Fit, Fit to Window, Remember Zoom, and Lock Zoom & Window.
- **Filmstrip**, slideshow, rotate, mirror, copy, reveal in Finder, move to Trash.
- **Multiple windows**, one per folder, chosen automatically when you open pictures from Finder.
- **Default viewer**: Pictty can open your pictures on a double-click in Finder.
- **Liquid Glass** toolbar, filmstrip, pills and panels on macOS 26 and later.
- **English and Spanish**, and a key for every action.
- **Private**: no account, no analytics; the only network connection is a daily update check, which you can turn off.

## In detail

### Rendering

The picture is a Core Animation layer tree. While you pinch, pan or scroll, the **GPU** filters the decoded picture (trilinear mipmaps down, bilinear up) and every frame lands on **whole device pixels**, so motion runs at the display's **full refresh rate**.

Once the view rests for a moment, Pictty renders the visible region again on a background queue with **vImage** (Accelerate): a separable **Lanczos-3** resample at exactly **one source pixel per output pixel**, with sub-pixel placement, laid over the GPU picture. The work is skipped when the GPU picture is already 1:1. Shrinking runs in **linear light** (extended linear sRGB, half-float buffers); a checkerboard of black and white shrinks to the grey of real light, not to the darker grey that averaging the stored values gives. Above 300 % the settled render uses a bilinear kernel, which is what you want when every source pixel already covers many screen pixels.

> [!NOTE]
> **Linear light.** A file stores brightness on a curve, not as amounts of light. Averaging those stored numbers, as most viewers do when they shrink a picture, makes fine detail darker than it is: foliage, stars, hair and text go dull. Pictty turns the numbers back into real light first, averages, and only then converts back.

Vectors are not rasterised once and scaled. SVG is **drawn from the vector** at the exact size of the visible region, even during a long pinch, at most every 150 ms.

### Decoding

ImageIO does the decoding, with Apple's **hardware decoders** where the format has them. A **high-quality preview** comes first, decoded for the size of your screen and drawn with the same Lanczos and linear-light rendering as everything else. It turns **seamlessly** into the **full-resolution** picture the moment the zoom needs more pixels than the preview holds. The neighbours on each side are decoded ahead (how many is a setting). Past 16,384 pixels, the largest texture the GPU takes, an uncapped decode feeds the settled render, so a 180-megapixel panorama still shows every pixel at 100 %. When macOS reports memory pressure, Pictty drops every decode it can make again.

Big folders feel small. Pictty reads a folder of 2,400 photos in about 20 milliseconds and has the first one on screen in about a quarter of a second. Everything heavy happens in the background, spread across your Mac's cores, so moving, zooming and editing never wait for it. Thumbnails keep to a fixed memory budget, so thousands of photos stay light.

Transparency is checked against the file: some decoders return RGBA for opaque files (iPhone HEIC and AVIF among them), so when the header does not say, the alpha values are checked once and an opaque picture is drawn as opaque.

### RAW

A camera RAW opens with the preview the camera stored in it, so it appears **at once**. A floating RAW badge and the orb show while **Apple's RAW engine** develops the real picture at screen size; it replaces the preview when it is ready, and the full develop follows on zoom.

### HDR

**Gain-map** pictures, **PQ** and **HLG** are decoded to HDR and shown with **extended dynamic range**. The headroom (how much brighter than white the display can go right now) is read from the display the window is on and followed as it changes with brightness and other HDR content.

### Looking closer

- **Loupe** (hold ⌥): a 15 × 15 pixel grid around the pointer, magnified without smoothing, with the RGB values, the hex colour and the pixel's coordinates in the original picture. ⌥-click copies the hex colour.
- **Information** (I): a histogram (red, green, blue and luminance), then camera, lens, exposure, image, dates, location and software, read from EXIF, TIFF, IPTC, GPS, XMP and the RAW maker data. Any value can be copied.
- **Clipping warnings** (J): a pixel counts as blown only when **two of its channels** are at the top, so a saturated colour (a red sign, a sodium street lamp) is not a false alarm. RAW and HDR pictures roll their highlights off below white; for them Pictty looks for the pile of pixels where the highlights stop and counts from there.

### Comparing

D adds the next picture to the comparison, and ⌘-click on thumbnails adds any picture, up to four. L cycles the layouts:

| Layout | What it does |
|---|---|
| Side by side, stacked, grid | Each picture in its own pane; Tab picks the pane the keys act on |
| Wipe | One picture exactly over the other; drag the line, or click, to move it |
| Blink | The two stacked, one shown at a time; B flips |

P syncs pan and ⇧P syncs zoom (matched by width), so the same detail stays in view in every pane.

### Editing

Every picture that is not a camera RAW goes through Pictty's own engine. The picture is uploaded to the GPU once as linear light in 16-bit floating point (extended sRGB, so wide-gamut colour and HDR survive), and each change of a slider runs a few Metal compute passes over it. The edit replaces the picture on the canvas, so the zoom, the settled render, the loupe, the histogram and the clipping warnings all show it, and zooming past the screen-sized edit renders every pixel.

Several sliders work **by regions**. An edge-aware map of the picture's brightness or colour (a guided filter, which smooths inside a region and stops at its edges) says what each region is; the slider decides what to do with the region, and every pixel in it follows by the same ratio. Texture is not flattened, edges get no halos, and a brighter region always stays brighter.

**Light**

- **Exposure**, ±4 stops. Raised, it works by regions: a region darker than 3 % of white gets all the stops, a region at half of white gets none, evenly in between, and pixels near white ease into it on a shoulder that keeps their colour. A face under a lamp keeps its light while the night around it opens up. Lowered, it multiplies the light.
- **Contrast**: an S-curve on each pixel's brightness around mid-grey. Black and white stay in place; colours keep their hue.
- **Brightness** lifts the picture's own midtones, around the middle brightness measured from the picture, by regions. Black and white stay put.
- **Highlights** go through a fast local Laplacian pyramid (Aubry et al.): the curve is applied at every scale of the picture, so detail survives at every size without halos. Variations no larger than the picture's noise follow the curve, so the noise in a pulled-down sky does not grow.
- **Shadows**: a tone curve that opens the dark end. Black stays black.
- **Dehaze** uses the dark channel prior (He, Sun and Tang): in a clear scene some channel is nearly black in every small patch, so whatever lifts the darkest channel is haze. The haze's own colour is read from the haziest bright part of the picture, the haze map is made to follow the picture's edges, and the haze comes out of the light before exposure and the rest. Lowered, it adds haze, more where the picture is already hazy.

**Colour**

- **White balance** is a chromatic adaptation (CAT02) from the light the picture was taken under. Temperature moves that light along the colours of real light sources (the Planckian locus), Tint across them. **Auto** looks for grey surfaces at edges: across an edge a grey surface changes brightness by the same ratio in red, green and blue, whatever the light (the Grayness Index). It then adapts the way the eye does, taking a daylight cast out completely and a lamp's only partly, so an evening keeps its warmth. The eyedropper reads anything you click as grey.
- **Vibrance** and **Saturation** work in Oklab, keeping lightness and hue, and by regions: a region's colour gets the whole boost and the colour noise inside it a quarter. Vibrance raises muted colours most and skin hardly at all, and gives a dull picture more than a vivid one. Saturation raises every colour, skin by half; at −100 it is black and white. A colour pushed hard comes to rest at the edge of Display P3 instead of clipping a channel, which would turn its hue.
- **Colour grading**: a wheel each for shadows, midtones and highlights (the angle is the colour, the distance how much) and a Balance slider for where the ranges meet. The tint never changes a pixel's brightness.

**Detail**

- **Texture**, **Clarity** and **Sharpening** come from one Laplacian pyramid of the brightness: sharpening is the finest levels, at the radius the picture's own softness calls for (its edges are measured when it loads); texture the middle levels; clarity the coarse ones, in the midtones. A change no larger than the picture's noise is grain and is left alone; one as large as an edge is left alone too, which keeps halos away. Sharpening and texture never take a pixel more than a hair past its neighbours, so nothing overshoots or rings.
- **Noise reduction** is **SCUNet** (Zhang et al.), a neural network trained on realistic camera noise and JPEG compression, run by Core ML on the GPU in overlapping 512-pixel tiles. Nothing leaves the Mac. Pictty first measures how the noise changes as the picture shrinks: pixel-sized noise is taken out at full size; grain of about a pixel at half size and then full; coarser grain at half size only, where it is pixel-sized again, and only what the network removed there comes back up, so the picture's own detail is not smoothed. Along the Amount slider, colour noise goes twice as fast as brightness grain. **Auto** sets the amount from the measured noise and leaves a clean picture alone. The network runs once per picture and resolution; after that the slider is instant.

**Camera RAWs** develop in Apple's RAW engine, where the sensor's headroom is: exposure and white balance in the develop, then highlights, shadows, contrast and brightness, and Apple's noise reduction. Pictty's engine adds dehaze, detail, vibrance, saturation and colour grading to the developed picture.

**Crop** (C) puts a frame on the whole picture: corners and edges resize, the inside moves, thirds show while it moves. Ratios come as common, social (Instagram, Stories and Reels, YouTube, X, Facebook, LinkedIn, Pinterest), screens (iPhone, iPad, Mac, Apple Watch) and print (A-series, Letter, 4 × 6, 5 × 7, 8 × 10); X turns the ratio on its side and R rounds the corners, all four or one at a time. The crop is kept in the file's own coordinates, so turning the picture afterwards turns the crop with it.

**Before and after** (Y) swaps between the edit and the original in one step. Each side is kept as it was last on screen, settled render included, so after the first press neither side is redrawn.

**Saving.** ⌘S writes over the file in its own format, colour profile, bit depth and metadata; a JPEG is re-encoded at the quality it was made with, matched to its own quantisation table, so it does not grow or soften for nothing. A turn or a mirror on its own rewrites the orientation tag and no pixel. ⇧⌘S saves a copy or converts: each format is a card that says what it can hold (lossless, HDR, transparency, bit depth), every setting is there, and the foot shows how large the file will be. The file is written beside the destination and moved over it, so a failure never leaves half a picture behind. Moving away from unsaved edits asks first.

### Printing

**Print** (⌘P) shows the sheet of paper as it will come out, the printer's own papers and margins included, borderless ones too. The picture is dragged into place and clicks onto the centre and the margins; its corners resize it, ⌥-drag chooses what a crop keeps, and the arrow keys nudge it a millimetre (⇧ for ten). One button makes it as large as the printer reaches on that paper, the paper turned whichever way gives more. Sizes are the page fitted or filled, the sizes photo labs print (10 × 15 to 60 × 90 cm, 4 × 6 to 24 × 36 in) or any width and height, in centimetres, inches or millimetres; a frame of another shape is filled and cropped, or holds the whole picture.

**Quality** is said in ppi and in words, judged from the distance a print that size is looked at: a 10 × 15 is held at reading distance and wants about 290 ppi, a 40 × 60 is seen from its diagonal and 150 is plenty. Below 240 ppi the printer would enlarge the pixels itself, coarsely, so Pictty recommends upscaling: it enlarges the printed part to 300 ppi before the printer sees it, with Lanczos in half float and each pixel held to the range of the source pixels around it, so edges come out crisp with no halo. The rating then counts the enlargement as finer than the printer's own, but not as fine as real pixels. It also says the largest size the picture prints at 300 ppi, and sets it in one click. Pictures with far more pixels than any printer uses go out at 600 ppi.

What is printed is what Save would write, every pixel with the edits on screen; HDR is brought into the paper's range rather than clipped. Sharpening for the paper (off, low, standard, high; glossy or matte) is applied last, at the resolution sent. The colour profile goes with the picture, with perceptual or relative colorimetric rendering, and a caption (file name, date and camera, or your own text) can go under it. Then the system's panel takes the printer's own settings: paper type, quality, copies, or a PDF.

### Browsing and windows

The filmstrip hides by itself and comes back at the bottom edge; T pins it. A picture opened from Finder goes to the window that already shows its folder, where it is selected; a picture from another folder opens a new window. Pictty can become the default viewer for the 28 picture types people actually have (photos, camera RAW, HDR, layers and vectors); macOS asks you to confirm each one, and Pictty never asks again for a type it already opens.

### Privacy

Pictty reads the pictures you open and the other pictures in their folder, and keeps decoded pictures in memory only. It writes nothing but its preferences and what you save, changes a file only when you save an edit over it or choose Move to Trash, and its **only network connection** is a daily check for a new version (Settings ▸ Updates turns it off; the Mac App Store version has none). Read the [privacy policy](https://www.noxdrop.com/picttyprivacy.html).

## Keyboard

| Keys | Action |
|---|---|
| ← → · Space · Home End | Previous / next / first / last picture |
| 1 – 5 | Actual · Best Fit · Fit · Remember · Lock |
| Z · ⌘+ · ⌘− · ⌘0 | 100 % at the pointer · zoom in · zoom out · back to the zoom mode |
| ⌥ · ⌥-click | Loupe · copy the colour |
| I · J · G · / | Information · clipping · background · file pill |
| D · L · B · P · Tab | Compare · layout · blink · sync pan · next pane |
| [ ] · M · two fingers | Rotate · mirror · rotate on the trackpad |
| E · C · Y | Adjust · crop · the original and back |
| ⌘S · ⇧⌘S · ⌘P | Save · Save As or convert · print |
| S · T · F or ↩ | Slideshow · filmstrip · full screen |
| ? · Esc | All shortcuts · close what is open, then leave full screen |

## Build from source

Requires macOS 15 or later on Apple silicon and Xcode 26 or later (Swift 6 toolchain; the macOS 26 SDK for Liquid Glass).

```sh
swift build -c release   # release build with full optimisation
swift test               # the engine's tests (resampling, zoom maths, analysis, editing)
```

| Path | What is there |
|---|---|
| `Sources/PicttyCore` | The engine: decoding, Lanczos and linear-light resampling, zoom maths, histogram and clipping analysis, SVG, the editing engine (Metal), saving |
| `Sources/Pictty` | The app: canvas and Core Animation layers, windows, toolbar, filmstrip, inspector, settings |
| `Tests/PicttyCoreTests` | Tests for the engine |
| `Models` | The noise reduction network, the script that converts it, and its licence |

## Licence

Pictty is free and open source: © 2026 Marco Cebrián Muiño, released under the [GNU General Public License v3.0](LICENSE). You may use, study, change and share it; anything you distribute that is built from it must be released under the same licence, with its source.

The noise reduction network is SCUNet by Kai Zhang and colleagues, from [cszn/SCUNet](https://github.com/cszn/SCUNet), under the Apache License 2.0 (`Models/SCUNet-LICENSE`).

---

<p align="center"><a href="https://www.noxdrop.com/pictty.html">Pictty on noxdrop.com</a> · <a href="https://www.noxdrop.com">More apps by Marco Cebrián Muiño</a></p> 

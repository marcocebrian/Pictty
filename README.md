<p align="center">
  <img src="https://www.noxdrop.com/img/pictty/icon-256.png" width="128" height="128" alt="Pictty icon">
</p>

<h1 align="center">Pictty</h1>

<p align="center"><b>The good-looking MacOS native technical image viewer.</b><br>
Pictty always draws your picture with the best possible algorithm: the GPU while it moves, Lanczos in linear light the moment it rests.</p>

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

## Features

- **High-quality preview first**: a preview made for your screen with the best algorithms, turning seamlessly into the full-resolution picture when the zoom needs it.
- **Pixel-exact at rest**: when the picture rests, the visible region is redrawn with Lanczos at one picture pixel per screen pixel, placed to a tenth of a pixel.
- **Linear-light shrinking**: reductions average **real light**, not the stored numbers, so fine detail keeps its brightness.
- **Clean enlarging**: up to 300 % with Lanczos; beyond that, smooth GPU filtering.
- **Full refresh rate in motion**: the **GPU** moves, zooms and rotates the picture through Core Animation, on whole device pixels.
- **Real RAW**: Apple's RAW engine develops every camera file; the camera's embedded preview shows at once.
- **True HDR**: gain maps, PQ and HLG with extended dynamic range and the display's live headroom.
- **Giant pictures**: **every pixel** past the GPU's 16,384-pixel texture limit, at 100 % and beyond.
- **Formats**: JPEG, HEIC, AVIF, JPEG XL, WebP, PNG, TIFF, GIF (animated), BMP, OpenEXR, PSD, TGA, SVG and RAW from hundreds of cameras.
- **Pixel loupe** with RGB values and the hex colour; ⌥-click copies it.
- **Histogram and clipping warnings**: blown highlights in red, blocked shadows in blue.
- **Information panel**: camera, lens, exposure, size, colour profile, dates, location and provenance.
- **Compare** up to four pictures: side by side, stacked, grid, wipe and blink, with synced pan and zoom.
- **Five zoom modes**: Actual Size, Best Fit, Fit to Window, Remember Zoom, and Lock Zoom & Window.
- **Filmstrip**, slideshow, rotate, mirror, copy, reveal in Finder, move to Trash.
- **Multiple windows**, one per folder, chosen automatically when you open pictures from Finder.
- **Default viewer**: Pictty can open your pictures on a double-click in Finder.
- **Liquid Glass** toolbar, filmstrip, pills and panels on macOS 26 and later.
- **English and Spanish**, and a key for every action.
- **Private**: no account, no analytics, no network connections.

## In detail

### Rendering

The picture is a Core Animation layer tree. While you pinch, pan or scroll, the **GPU** filters the decoded picture (trilinear mipmaps down, bilinear up) and every frame lands on **whole device pixels**, so motion runs at the display's **full refresh rate**.

Once the view rests for a moment, Pictty renders the visible region again on a background queue with **vImage** (Accelerate): a separable **Lanczos-3** resample at exactly **one source pixel per output pixel**, with sub-pixel placement, laid over the GPU picture. The work is skipped when the GPU picture is already 1:1. Shrinking runs in **linear light** (extended linear sRGB, half-float buffers); a checkerboard of black and white shrinks to the grey of real light, not to the darker grey that averaging the stored values gives. Above 300 % the settled render uses a bilinear kernel, which is what you want when every source pixel already covers many screen pixels.

> [!NOTE]
> **Linear light.** A file stores brightness on a curve, not as amounts of light. Averaging those stored numbers, as most viewers do when they shrink a picture, makes fine detail darker than it is: foliage, stars, hair and text go dull. Pictty turns the numbers back into real light first, averages, and only then converts back.

Vectors are not rasterised once and scaled. SVG is **drawn from the vector** at the exact size of the visible region, even during a long pinch, at most every 150 ms.

### Decoding

ImageIO does the decoding, with Apple's **hardware decoders** where the format has them. A **high-quality preview** comes first, decoded for the size of your screen and drawn with the same Lanczos and linear-light rendering as everything else. It turns **seamlessly** into the **full-resolution** picture the moment the zoom needs more pixels than the preview holds. The neighbours on each side are decoded ahead (how many is a setting). Past 16,384 pixels, the largest texture the GPU takes, an uncapped decode feeds the settled render, so a 180-megapixel panorama still shows every pixel at 100 %. When macOS reports memory pressure, Pictty drops every decode it can make again.

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

### Browsing and windows

The filmstrip hides by itself and comes back at the bottom edge; T pins it. A picture opened from Finder goes to the window that already shows its folder, where it is selected; a picture from another folder opens a new window. Pictty can become the default viewer for the 28 picture types people actually have (photos, camera RAW, HDR, layers and vectors); macOS asks you to confirm each one, and Pictty never asks again for a type it already opens.

### Privacy

Pictty reads the pictures you open and the other pictures in their folder, and keeps decoded pictures in memory only. It writes nothing but its preferences, changes a file only when you choose Move to Trash, and makes **no network connections**. Read the [privacy policy](https://www.noxdrop.com/picttyprivacy.html).

## Keyboard

| Keys | Action |
|---|---|
| ← → · Space · Home End | Previous / next / first / last picture |
| 1 – 5 | Actual · Best Fit · Fit · Remember · Lock |
| Z · ⌘+ · ⌘− · ⌘0 | 100 % at the pointer · zoom in · zoom out · back to the zoom mode |
| ⌥ · ⌥-click | Loupe · copy the colour |
| I · J · G · / | Information · clipping · background · file pill |
| D · L · B · P · Tab | Compare · layout · blink · sync pan · next pane |
| [ ] · M | Rotate · mirror |
| S · T · F or ↩ | Slideshow · filmstrip · full screen |
| ? · Esc | All shortcuts · close what is open, then the window |

## Build from source

Requires macOS 15 or later on Apple silicon and Xcode 26 or later (Swift 6 toolchain; the macOS 26 SDK for Liquid Glass).

```sh
./build.sh            # release build with full optimisation and LTO → build/Pictty.app
swift test            # the engine's tests (resampling, zoom maths, analysis)
tools/release.sh      # Developer ID signing, notarisation, and the DMG
```

`tools/release.sh` needs a Developer ID certificate and an Apple account signed in to Xcode; `--no-notarize` skips the upload.

| Path | What is there |
|---|---|
| `Sources/PicttyCore` | The engine: decoding, Lanczos and linear-light resampling, zoom maths, histogram and clipping analysis, SVG |
| `Sources/Pictty` | The app: canvas and Core Animation layers, windows, toolbar, filmstrip, inspector, settings |
| `Tests/PicttyCoreTests` | Tests for the engine |
| `Resources` | Info.plist and the Spanish translation |
| `tools` | Icon, translation, string-coverage and release scripts |

## Licence

Pictty is free and open source: © 2026 Marco Cebrián Muiño, released under the [GNU General Public License v3.0](LICENSE). You may use, study, change and share it; anything you distribute that is built from it must be released under the same licence, with its source.

---

<p align="center"><a href="https://www.noxdrop.com/pictty.html">Pictty on noxdrop.com</a> · <a href="https://www.noxdrop.com">More apps by Marco Cebrián Muiño</a></p> 

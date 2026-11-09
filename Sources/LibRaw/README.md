# LibRaw 0.22.3

[LibRaw](https://www.libraw.org) by LibRaw LLC, vendored unchanged from the 0.22.3 release
(https://github.com/LibRaw/LibRaw/tree/0.22.3) and compiled into Pictty as a static library.
Pictty uses it only to read a camera's sensor mosaic, its levels, white balance and colour
matrix (see `Sources/PicttyCore/SensorDevelop.swift`); it does not use LibRaw's own demosaic
or processing.

LibRaw is dual-licensed under the GNU Lesser General Public License 2.1 (`LICENSE.LGPL`) and
the Common Development and Distribution License 1.0 (`LICENSE.CDDL`); Pictty uses it under the
CDDL 1.0. `COPYRIGHT` is LibRaw's own notice.

To update: replace `src`, `libraw` and `internal` with a new release's, and the `sources`
list in `Package.swift` with its `Makefile.am`'s `lib_libraw_a_SOURCES`.

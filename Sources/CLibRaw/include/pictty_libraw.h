// Pictty's calls into LibRaw, which is compiled in (Sources/LibRaw): it reads a camera's sensor
// mosaic. Only LibRaw's C API is used.
#ifndef PICTTY_LIBRAW_H
#define PICTTY_LIBRAW_H

#include "libraw.h"

/// The file opened and its mosaic unpacked; NULL when LibRaw cannot read it.
libraw_data_t *pictty_libraw_open(const char *path);

/// The filter colour at a row and column of the visible area: 0 red, 1 green, 2 blue, 3 the
/// second green.
int pictty_libraw_color(libraw_data_t *raw, int row, int col);

/// LibRaw's black-level table (`color.cblack`), which is too large for Swift to import: four per
/// colour, then the size of a repeating pattern and the pattern itself.
unsigned pictty_libraw_cblack(libraw_data_t *raw, int index);

void pictty_libraw_close(libraw_data_t *raw);

#endif

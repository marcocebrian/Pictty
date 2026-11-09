#include "pictty_libraw.h"

libraw_data_t *pictty_libraw_open(const char *path) {
    libraw_data_t *raw = libraw_init(0);
    if (!raw) return NULL;
    if (libraw_open_file(raw, path) != LIBRAW_SUCCESS || libraw_unpack(raw) != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return NULL;
    }
    return raw;
}

int pictty_libraw_color(libraw_data_t *raw, int row, int col) { return libraw_COLOR(raw, row, col); }

unsigned pictty_libraw_cblack(libraw_data_t *raw, int index) {
    return index >= 0 && index < LIBRAW_CBLACK_SIZE ? raw->color.cblack[index] : 0;
}

void pictty_libraw_close(libraw_data_t *raw) {
    if (raw) libraw_close(raw);
}

#ifndef OLOGN_JPEG_H
#define OLOGN_JPEG_H

#include <stddef.h>
#include <stdint.h>

/* progressive: 1 = progressive, 0 = sequential, -1 = keep source scan type.
   markers: 0 = none, 1 = ICC (APP2) only, 2 = all APPn + COM.
   Returns 0 on success; *out is malloc'd (caller free()s). */
int ologn_jpeg_transcode(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len,
                         int progressive, int markers, char err[200]);

/* 1 = same dimensions, components, sampling factors, quant tables and every DCT coefficient;
   0 = differ; <0 = decode error. */
int ologn_jpeg_coefficients_equal(const uint8_t *a, size_t a_len, const uint8_t *b, size_t b_len,
                                  char err[200]);

#endif

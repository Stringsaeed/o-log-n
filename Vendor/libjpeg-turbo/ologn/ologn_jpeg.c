/* o-log-n JPEG coefficient transcoder.
   libjpeg reports errors with longjmp. That jump stays inside this file. */

#include "ologn_jpeg.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jerror.h"
#include "jpeglib.h"

struct ologn_jpeg_err {
    struct jpeg_error_mgr pub;
    jmp_buf jmp;
    char message[200];
};

static void ologn_error_exit(j_common_ptr cinfo) {
    struct ologn_jpeg_err *err = (struct ologn_jpeg_err *)cinfo->err;
    (*cinfo->err->format_message)(cinfo, err->message);
    err->message[sizeof(err->message) - 1] = '\0';
    longjmp(err->jmp, 1);
}

static void ologn_emit_message(j_common_ptr cinfo, int msg_level) {
    (void)cinfo;
    (void)msg_level;
}

static void ologn_output_message(j_common_ptr cinfo) {
    (void)cinfo;
}

static void ologn_prepare_err(struct ologn_jpeg_err *err) {
    jpeg_std_error(&err->pub);
    err->pub.error_exit = ologn_error_exit;
    err->pub.emit_message = ologn_emit_message;
    err->pub.output_message = ologn_output_message;
    err->message[0] = '\0';
}

static void ologn_copy_err(char err[200], const struct ologn_jpeg_err *src) {
    if (err == NULL) {
        return;
    }
    snprintf(err, 200, "%s", src->message[0] ? src->message : "jpeg error");
}

static void ologn_save_markers(j_decompress_ptr src, int markers) {
    int m;
    if (markers == 1) {
        jpeg_save_markers(src, JPEG_APP0 + 2, 0xFFFF);
        return;
    }
    if (markers != 2) {
        return;
    }
    jpeg_save_markers(src, JPEG_COM, 0xFFFF);
    for (m = 0; m < 16; m++) {
        jpeg_save_markers(src, JPEG_APP0 + m, 0xFFFF);
    }
}

static void ologn_copy_markers(j_decompress_ptr src, j_compress_ptr dst) {
    jpeg_saved_marker_ptr marker;
    for (marker = src->marker_list; marker != NULL; marker = marker->next) {
        if (dst->write_JFIF_header && marker->marker == JPEG_APP0 && marker->data_length >= 5 &&
            marker->data[0] == 0x4A && marker->data[1] == 0x46 && marker->data[2] == 0x49 &&
            marker->data[3] == 0x46 && marker->data[4] == 0) {
            continue;
        }
        if (dst->write_Adobe_marker && marker->marker == JPEG_APP0 + 14 && marker->data_length >= 5 &&
            marker->data[0] == 0x41 && marker->data[1] == 0x64 && marker->data[2] == 0x6F &&
            marker->data[3] == 0x62 && marker->data[4] == 0x65) {
            continue;
        }
        jpeg_write_marker(dst, marker->marker, marker->data, marker->data_length);
    }
}

static int ologn_blocks_equal(j_decompress_ptr a, jvirt_barray_ptr *ca, j_decompress_ptr b,
                              jvirt_barray_ptr *cb) {
    int ci;
    if (a->image_width != b->image_width || a->image_height != b->image_height) {
        return 0;
    }
    if (a->num_components != b->num_components || a->data_precision != b->data_precision) {
        return 0;
    }
    for (ci = 0; ci < a->num_components; ci++) {
        jpeg_component_info *ia = &a->comp_info[ci];
        jpeg_component_info *ib = &b->comp_info[ci];
        int q;
        JDIMENSION row;
        if (ia->h_samp_factor != ib->h_samp_factor || ia->v_samp_factor != ib->v_samp_factor ||
            ia->quant_tbl_no != ib->quant_tbl_no || ia->width_in_blocks != ib->width_in_blocks ||
            ia->height_in_blocks != ib->height_in_blocks) {
            return 0;
        }
        if (ia->quant_tbl_no < 0 || ia->quant_tbl_no >= NUM_QUANT_TBLS) {
            return 0;
        }
        if (a->quant_tbl_ptrs[ia->quant_tbl_no] == NULL || b->quant_tbl_ptrs[ib->quant_tbl_no] == NULL) {
            return 0;
        }
        for (q = 0; q < DCTSIZE2; q++) {
            if (a->quant_tbl_ptrs[ia->quant_tbl_no]->quantval[q] !=
                b->quant_tbl_ptrs[ib->quant_tbl_no]->quantval[q]) {
                return 0;
            }
        }
        for (row = 0; row < ia->height_in_blocks; row++) {
            JBLOCKARRAY ba = (*a->mem->access_virt_barray)((j_common_ptr)a, ca[ci], row, 1, FALSE);
            JBLOCKARRAY bb = (*b->mem->access_virt_barray)((j_common_ptr)b, cb[ci], row, 1, FALSE);
            if (memcmp(ba[0], bb[0], (size_t)ia->width_in_blocks * sizeof(JBLOCK)) != 0) {
                return 0;
            }
        }
    }
    return 1;
}

/* Every value longjmp can observe lives in this heap object. The destination buffer is ours
   until success hands it to the caller; a growth realloc is stored here before any further
   libjpeg call, so the error path frees the current block exactly once. */
struct ologn_ctx {
    struct ologn_jpeg_err jerr;
    struct jpeg_decompress_struct src;
    struct jpeg_compress_struct dst;
    struct jpeg_destination_mgr dest;
    uint8_t *buffer;
    size_t capacity;
    size_t length;
    int src_ready;
    int dst_ready;
    int want_progressive;
    int markers;
    jvirt_barray_ptr *coefs;
};

struct ologn_eq {
    struct ologn_jpeg_err jerr;
    struct jpeg_decompress_struct a;
    struct jpeg_decompress_struct b;
    int a_ready;
    int b_ready;
};

static struct ologn_ctx *ologn_ctx_from(j_compress_ptr cinfo) {
    return (struct ologn_ctx *)cinfo->client_data;
}

static void ologn_init_dest(j_compress_ptr cinfo) {
    struct ologn_ctx *ctx = ologn_ctx_from(cinfo);
    size_t initial = 65536;
    uint8_t *buffer = (uint8_t *)malloc(initial);
    if (buffer == NULL) {
        ERREXIT(cinfo, JERR_OUT_OF_MEMORY);
    }
    ctx->buffer = buffer;
    ctx->capacity = initial;
    ctx->length = 0;
    cinfo->dest->next_output_byte = buffer;
    cinfo->dest->free_in_buffer = initial;
}

static boolean ologn_empty_dest(j_compress_ptr cinfo) {
    struct ologn_ctx *ctx = ologn_ctx_from(cinfo);
    size_t next;
    uint8_t *grown;
    /* Called only when the buffer is full. The compressor's free_in_buffer is a
       local copy and is still stale here, so the whole allocation is live data.
       Same contract as libjpeg's empty_mem_output_buffer. */
    if (ctx->capacity > SIZE_MAX / 2) {
        ERREXIT(cinfo, JERR_OUT_OF_MEMORY);
    }
    next = ctx->capacity * 2;
    grown = (uint8_t *)realloc(ctx->buffer, next);
    if (grown == NULL) {
        ERREXIT(cinfo, JERR_OUT_OF_MEMORY);
    }
    ctx->buffer = grown;
    cinfo->dest->next_output_byte = grown + ctx->capacity;
    cinfo->dest->free_in_buffer = ctx->capacity;
    ctx->capacity = next;
    return TRUE;
}

static void ologn_term_dest(j_compress_ptr cinfo) {
    struct ologn_ctx *ctx = ologn_ctx_from(cinfo);
    ctx->length = ctx->capacity - cinfo->dest->free_in_buffer;
}

static void ologn_transcode_fail(struct ologn_ctx *ctx, char err[200]) {
    if (ctx->buffer != NULL) {
        free(ctx->buffer);
        ctx->buffer = NULL;
    }
    if (ctx->dst_ready) {
        jpeg_destroy_compress(&ctx->dst);
        ctx->dst_ready = 0;
    }
    if (ctx->src_ready) {
        jpeg_destroy_decompress(&ctx->src);
        ctx->src_ready = 0;
    }
    ologn_copy_err(err, &ctx->jerr);
    free(ctx);
}

int ologn_jpeg_transcode(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len,
                         int progressive, int markers, char err[200]) {
    struct ologn_ctx *volatile ctx;
    uint8_t *handed;

    if (out) {
        *out = NULL;
    }
    if (out_len) {
        *out_len = 0;
    }
    if (in == NULL || out == NULL || out_len == NULL || in_len == 0 || in_len > 0xFFFFFFFFUL) {
        if (err) {
            snprintf(err, 200, "bad argument");
        }
        return -1;
    }

    ctx = (struct ologn_ctx *)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        if (err) {
            snprintf(err, 200, "out of memory");
        }
        return -1;
    }
    ctx->markers = markers;
    ologn_prepare_err(&ctx->jerr);
    ctx->src.err = &ctx->jerr.pub;
    ctx->dst.err = &ctx->jerr.pub;

    if (setjmp(ctx->jerr.jmp)) {
        ologn_transcode_fail(ctx, err);
        return -1;
    }

    jpeg_create_decompress(&ctx->src);
    ctx->src_ready = 1;
    jpeg_mem_src(&ctx->src, in, (unsigned long)in_len);
    ologn_save_markers(&ctx->src, markers);
    jpeg_read_header(&ctx->src, TRUE);
    ctx->want_progressive = (progressive > 0) || (progressive < 0 && ctx->src.progressive_mode);
    ctx->coefs = jpeg_read_coefficients(&ctx->src);

    jpeg_create_compress(&ctx->dst);
    ctx->dst_ready = 1;
    jpeg_copy_critical_parameters(&ctx->src, &ctx->dst);
    ctx->dst.optimize_coding = TRUE;
    if (ctx->want_progressive) {
        jpeg_simple_progression(&ctx->dst);
    }
    ctx->dst.optimize_coding = TRUE;
    /* markers == 2 keeps the source APP0, including a JFIF thumbnail. Suppress the
       header the library would emit so jpeg_write_marker can place the original after SOI. */
    if (markers == 2) {
        ctx->dst.write_JFIF_header = FALSE;
        ctx->dst.write_Adobe_marker = FALSE;
    }
    ctx->dest.init_destination = ologn_init_dest;
    ctx->dest.empty_output_buffer = ologn_empty_dest;
    ctx->dest.term_destination = ologn_term_dest;
    ctx->dst.dest = &ctx->dest;
    ctx->dst.client_data = (void *)ctx;
    jpeg_write_coefficients(&ctx->dst, ctx->coefs);
    if (markers != 0) {
        ologn_copy_markers(&ctx->src, &ctx->dst);
    }
    jpeg_finish_compress(&ctx->dst);
    jpeg_finish_decompress(&ctx->src);

    handed = ctx->buffer;
    *out_len = ctx->length;
    ctx->buffer = NULL;
    jpeg_destroy_compress(&ctx->dst);
    ctx->dst_ready = 0;
    jpeg_destroy_decompress(&ctx->src);
    ctx->src_ready = 0;
    free(ctx);
    *out = handed;
    if (err) {
        err[0] = '\0';
    }
    return 0;
}

int ologn_jpeg_coefficients_equal(const uint8_t *a, size_t a_len, const uint8_t *b, size_t b_len,
                                  char err[200]) {
    struct ologn_eq *volatile eq;
    jvirt_barray_ptr *ca;
    jvirt_barray_ptr *cb;
    int same;

    if (a == NULL || b == NULL || a_len == 0 || b_len == 0 || a_len > 0xFFFFFFFFUL || b_len > 0xFFFFFFFFUL) {
        if (err) {
            snprintf(err, 200, "bad argument");
        }
        return -1;
    }

    eq = (struct ologn_eq *)calloc(1, sizeof(*eq));
    if (eq == NULL) {
        if (err) {
            snprintf(err, 200, "out of memory");
        }
        return -1;
    }
    ologn_prepare_err(&eq->jerr);
    eq->a.err = &eq->jerr.pub;
    eq->b.err = &eq->jerr.pub;

    if (setjmp(eq->jerr.jmp)) {
        if (eq->b_ready) {
            jpeg_destroy_decompress(&eq->b);
        }
        if (eq->a_ready) {
            jpeg_destroy_decompress(&eq->a);
        }
        ologn_copy_err(err, &eq->jerr);
        free(eq);
        return -1;
    }

    jpeg_create_decompress(&eq->a);
    eq->a_ready = 1;
    jpeg_mem_src(&eq->a, a, (unsigned long)a_len);
    jpeg_read_header(&eq->a, TRUE);
    ca = jpeg_read_coefficients(&eq->a);

    jpeg_create_decompress(&eq->b);
    eq->b_ready = 1;
    jpeg_mem_src(&eq->b, b, (unsigned long)b_len);
    jpeg_read_header(&eq->b, TRUE);
    cb = jpeg_read_coefficients(&eq->b);

    same = ologn_blocks_equal(&eq->a, ca, &eq->b, cb);

    jpeg_finish_decompress(&eq->a);
    jpeg_finish_decompress(&eq->b);
    jpeg_destroy_decompress(&eq->b);
    eq->b_ready = 0;
    jpeg_destroy_decompress(&eq->a);
    eq->a_ready = 0;
    free(eq);
    if (err) {
        err[0] = '\0';
    }
    return same ? 1 : 0;
}

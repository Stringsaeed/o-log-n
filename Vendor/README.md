# Vendored codecs

SIMD is disabled in libjpeg-turbo (`WITH_SIMD` is never defined). libdeflate keeps its own architecture paths; the SwiftPM target compiles `lib/` unmodified.

Both archives were fetched on 2026-11-19 and checked against the sha256 values in `docs/architecture.md` §2.1 before the tree below was copied in.

| Library | Version | License | URL | sha256 |
|---|---|---|---|---|
| libdeflate | v1.26 | MIT | https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.26.tar.gz | `bba03fffc5538576213675ce6968fcff6ce2e67d82e4d5febea2d05f9f13cf85` |
| libjpeg-turbo | 3.2.1 | IJG + BSD-3-Clause | https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.2.1.tar.gz | `6f5819c51649bce2571a23b1b0cd41eae2f57fc3f8908c7ec9e7047efb65ca13` |

## Local files (not from the upstream tarballs)

- `libdeflate/include/libdeflate.h` — one-line public header that includes `../libdeflate.h`.
- `libjpeg-turbo/src/jconfig.h` — hand-written config (`JPEG_LIB_VERSION` 62, arithmetic coding, memory source/destination).
- `libjpeg-turbo/src/jconfigint.h` — hand-written internal config. `WITH_SIMD` is undefined.
- `libjpeg-turbo/src/jversion.h` — upstream `jversion.h.in` with `@COPYRIGHT_YEAR@` replaced by `1991-2026`.
- `libjpeg-turbo/ologn/ologn_jpeg.c` and `ologn/include/ologn_jpeg.h` — coefficient transcode and coefficient compare. libjpeg's `longjmp` stays inside the C file.

Upstream files under `libdeflate/` (except the public header above) and under `libjpeg-turbo/src/` are unmodified tag sources. `jcstest.c`, `jdatadst-tj.c`, and `jdatasrc-tj.c` are not part of this tree. The SwiftPM target compiles the 101 libjpeg translation units listed in §2.1 plus `ologn_jpeg.c`, not every `.c` file that sits next to them (the unsuffixed templates exist only so the bit-depth wrappers can `#include` them).

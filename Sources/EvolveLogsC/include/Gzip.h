#ifndef EVOLVE_GZIP_H
#define EVOLVE_GZIP_H

/*
 * Minimal gzip (RFC 1952) wrapper over the system zlib — the SDK posts with
 * Content-Encoding: gzip, which is the gzip container, not zlib's own
 * format. deflateInit2 with windowBits = 15 + 16 selects it.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Worst-case compressed size of `len` input bytes, plus container overhead. */
size_t evolve_gzip_bound(size_t len);

/*
 * Compresses `src` into a gzip stream at `dst` (capacity `cap`). Returns the
 * compressed size, or 0 on failure.
 */
size_t evolve_gzip(const uint8_t *src, size_t len, uint8_t *dst, size_t cap);

/*
 * Decompresses a gzip stream. Returns the plain size, or 0 on failure.
 */
size_t evolve_gunzip(const uint8_t *src, size_t len, uint8_t *dst, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* EVOLVE_GZIP_H */

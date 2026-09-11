#include "Gzip.h"

#include <string.h>
#include <zlib.h>

size_t evolve_gzip_bound(size_t len) {
    return deflateBound(NULL, (uLong)len) + 32; /* container + header slack */
}

size_t evolve_gzip(const uint8_t *src, size_t len, uint8_t *dst, size_t cap) {
    if (src == NULL || dst == NULL) {
        return 0;
    }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    /* windowBits 15 + 16 = gzip container; default compression. */
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        return 0;
    }
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)len;
    stream.next_out = (Bytef *)dst;
    stream.avail_out = (uInt)cap;
    int rc = deflate(&stream, Z_FINISH);
    size_t out = stream.total_out;
    deflateEnd(&stream);
    if (rc != Z_STREAM_END) {
        return 0;
    }
    return out;
}

size_t evolve_gunzip(const uint8_t *src, size_t len, uint8_t *dst, size_t cap) {
    if (src == NULL || dst == NULL) {
        return 0;
    }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    /* windowBits 15 + 16 accepts the gzip container. */
    if (inflateInit2(&stream, 15 + 16) != Z_OK) {
        return 0;
    }
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)len;
    stream.next_out = (Bytef *)dst;
    stream.avail_out = (uInt)cap;
    int rc = inflate(&stream, Z_FINISH);
    size_t out = stream.total_out;
    inflateEnd(&stream);
    if (rc != Z_STREAM_END) {
        return 0;
    }
    return out;
}

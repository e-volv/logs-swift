#include "CrashBuffer.h"

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * The pre-allocated crash buffer — see the header for the design and the
 * async-signal-safety argument. Everything here is C89-flavoured, free of
 * malloc on the write path.
 */

#define EVOLVE_CRASH_BUF_SIZE (256 * 1024)

static char *g_buf = NULL;
static char *g_suffix = NULL;
static size_t g_prefix_len = 0;
static size_t g_suffix_len = 0;
static char *g_path = NULL;

void evolve_crash_buffer_init(void) {
    if (g_buf != NULL) {
        return;
    }
    g_buf = (char *)malloc(EVOLVE_CRASH_BUF_SIZE);
    g_suffix = (char *)malloc(1024);
}

int evolve_crash_buffer_set_prefix(const char *bytes, size_t len) {
    if (g_buf == NULL || bytes == NULL || len == 0 || len >= EVOLVE_CRASH_BUF_SIZE) {
        return -1;
    }
    memcpy(g_buf, bytes, len);
    g_prefix_len = len;
    return 0;
}

int evolve_crash_buffer_set_suffix(const char *bytes, size_t len) {
    if (g_suffix == NULL || bytes == NULL || len == 0 || len >= 1024) {
        return -1;
    }
    memcpy(g_suffix, bytes, len);
    g_suffix_len = len;
    return 0;
}

int evolve_crash_buffer_set_path(const char *path) {
    if (path == NULL) {
        return -1;
    }
    free(g_path);
    size_t len = strlen(path) + 1;
    g_path = (char *)malloc(len);
    if (g_path == NULL) {
        return -1;
    }
    memcpy(g_path, path, len);
    return 0;
}

static const char *signal_name(int signo) {
    switch (signo) {
#ifdef SIGABRT
    case SIGABRT: return "SIGABRT";
#endif
#ifdef SIGBUS
    case SIGBUS: return "SIGBUS";
#endif
#ifdef SIGFPE
    case SIGFPE: return "SIGFPE";
#endif
#ifdef SIGILL
    case SIGILL: return "SIGILL";
#endif
#ifdef SIGSEGV
    case SIGSEGV: return "SIGSEGV";
#endif
#ifdef SIGTRAP
    case SIGTRAP: return "SIGTRAP";
#endif
    default: return "SIG???";
    }
}

/* open + write + close; async-signal-safe. */
static long write_file(const char *path, const char *bytes, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        return -1;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, bytes + off, len - off);
        if (n <= 0) {
            close(fd);
            return -1;
        }
        off += (size_t)n;
    }
    close(fd);
    return (long)len;
}

/* Shared tail: bounds-check the formatted middle, append the suffix, write. */
static long finish_write(char *mid, size_t mid_cap, int mid_len) {
    if (mid_len < 0) {
        return -1;
    }
    if ((size_t)mid_len >= mid_cap) {
        mid_len = (int)mid_cap - 1; /* truncated middle; still valid JSON text */
    }
    memcpy(g_buf + g_prefix_len + (size_t)mid_len, g_suffix, g_suffix_len);
    return write_file(g_path, g_buf, g_prefix_len + (size_t)mid_len + g_suffix_len);
}

long evolve_crash_buffer_write_signal(int signo, int si_code, uintptr_t fault_addr) {
    if (g_buf == NULL || g_suffix == NULL || g_path == NULL ||
        g_prefix_len == 0 || g_suffix_len == 0) {
        return -1;
    }
    char *mid = g_buf + g_prefix_len;
    size_t mid_cap = EVOLVE_CRASH_BUF_SIZE - g_prefix_len - g_suffix_len - 1;
    int mid_len = snprintf(mid, mid_cap,
                           "\"exception.type\":\"signal\","
                           "\"exception.message\":\"%s (code %ld, fault 0x%lx)\",",
                           signal_name(signo), (long)si_code, fault_addr);
    return finish_write(mid, mid_cap, mid_len);
}

long evolve_crash_buffer_write_exception(const char *name, const char *reason) {
    if (g_buf == NULL || g_suffix == NULL || g_path == NULL ||
        g_prefix_len == 0 || g_suffix_len == 0) {
        return -1;
    }
    char *mid = g_buf + g_prefix_len;
    size_t mid_cap = EVOLVE_CRASH_BUF_SIZE - g_prefix_len - g_suffix_len - 1;
    int mid_len = snprintf(mid, mid_cap,
                           "\"exception.type\":\"%s\",\"exception.message\":\"%s\",",
                           name != NULL ? name : "NSException",
                           reason != NULL ? reason : "");
    return finish_write(mid, mid_cap, mid_len);
}

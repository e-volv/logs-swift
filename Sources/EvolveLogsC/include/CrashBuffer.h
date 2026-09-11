#ifndef EVOLVE_CRASH_BUFFER_H
#define EVOLVE_CRASH_BUFFER_H

/*
 * Crash-time write path for the e-volv Observer iOS SDK.
 *
 * A fatal-signal handler runs in the crashed process, where almost nothing
 * is safe: malloc may be interrupted mid-free and the Swift runtime may
 * deadlock on a lock held by the interrupted thread. Everything this file
 * does on the write path is async-signal-safe: snprintf(3), memcpy(3),
 * open(2), write(2), close(2) — see signal(3). All allocation happens at
 * install time (evolve_crash_buffer_init), never in the handler.
 *
 * Layout of the pre-allocated buffer:
 *
 *   [ prefix JSON ][ middle: formatted at crash time ][ suffix JSON ]
 *
 * The prefix and suffix are serialized once, ahead of time, by Swift and
 * stored separately; at crash time the middle is formatted with snprintf
 * (signal name, code and fault address, or the NSException name/reason)
 * into the scratch after the prefix, and the suffix is memcpy'd right
 * behind it, so one write(2) sends the contiguous whole.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Allocates the buffer. Idempotent; safe to call again after fork. */
void evolve_crash_buffer_init(void);

/* Copies the pre-serialized prefix into the buffer. Returns 0 on success. */
int evolve_crash_buffer_set_prefix(const char *bytes, size_t len);

/*
 * Copies the pre-serialized suffix into the buffer (it is relocated behind
 * the formatted middle at write time). Returns 0 on success.
 */
int evolve_crash_buffer_set_suffix(const char *bytes, size_t len);

/* Stores the destination file path (copied; allocation happens at install). */
int evolve_crash_buffer_set_path(const char *path);

/*
 * Signal-crash write: formats the middle (signal name, code, fault address)
 * and writes prefix+middle+suffix to the stored path with one write(2) after
 * open(2). Returns the number of bytes written, or -1.
 */
long evolve_crash_buffer_write_signal(int signo, int si_code, uintptr_t fault_addr);

/*
 * NSException write: same, but the middle is the exception name and reason.
 * Unlike the signal path this runs in a (crashing) ObjC context where
 * allocation is legal; the caller passes C strings.
 */
long evolve_crash_buffer_write_exception(const char *name, const char *reason);

#ifdef __cplusplus
}
#endif

#endif /* EVOLVE_CRASH_BUFFER_H */

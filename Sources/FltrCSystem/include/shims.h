#ifndef FLTR_CSYSTEM_SHIMS_H
#define FLTR_CSYSTEM_SHIMS_H

#include <termios.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

// Wrapper for ioctl with TIOCGWINSZ to avoid variadic function issues on Linux
static inline int fltr_ioctl_TIOCGWINSZ(int fd, struct winsize *ws) {
    return ioctl(fd, TIOCGWINSZ, ws);
}

// Portable VMIN/VTIME setters.
// On macOS c_cc is a 20-element tuple (VMIN=16, VTIME=17); on Linux
// glibc/musl it is a 32-element array (VMIN=6, VTIME=5).  These helpers
// let Swift callers avoid platform-specific tuple-index access.
static inline void fltr_termios_setVMIN(struct termios *t, cc_t value) {
    t->c_cc[VMIN] = value;
}
static inline void fltr_termios_setVTIME(struct termios *t, cc_t value) {
    t->c_cc[VTIME] = value;
}

// Non-blocking terminal output helpers. The Swift writer uses these instead
// of FileDescriptor.writeAll so cancellation can be observed between partial
// writes and bounded poll waits.
static inline int fltr_fd_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags == -1 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static inline ssize_t fltr_write_bytes(int fd, const void *bytes, size_t count) {
    return write(fd, bytes, count);
}

static inline int fltr_wait_writable(int fd, int timeout_ms) {
    struct pollfd descriptor = { .fd = fd, .events = POLLOUT, .revents = 0 };
    return poll(&descriptor, 1, timeout_ms);
}

static inline int fltr_errno_is_interrupted(void) { return errno == EINTR; }
static inline int fltr_errno_is_would_block(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK;
}

#endif /* FLTR_CSYSTEM_SHIMS_H */

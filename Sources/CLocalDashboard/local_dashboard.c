#include "CLocalDashboard.h"
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <spawn.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <time.h>
extern char **environ;

static int64_t dashboard_monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

// Child-process notifications must not restart the administrator's whole wait.
static int dashboard_poll_until(int fd, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - dashboard_monotonic_ms();
        if (remaining <= 0) return 0;
        struct pollfd waiter = {fd, POLLIN, 0};
        int ready = poll(&waiter, 1, remaining > INT_MAX ? INT_MAX : (int)remaining);
        if (ready < 0 && errno == EINTR) continue;
        return ready;
    }
}

static void dashboard_reap(pid_t pid, int terminate) {
    if (terminate) kill(pid, SIGTERM);
    int status;
    int64_t deadline = dashboard_monotonic_ms() + 1000;
    for (;;) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return;
        if (dashboard_monotonic_ms() >= deadline) break;
        struct timespec pause = {0, 20000000};
        nanosleep(&pause, NULL);
    }
    // Only the fixed authopen child created by this request is terminated.
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

int aa_open_dashboard_hosts(int writable) {
    if (writable != 0 && writable != 1) { errno = EINVAL; return -1; }
    // authopen rejects O_NOFOLLOW. Validate the fixed regular file before and
    // after receiving its descriptor, before the caller can change any bytes.
    struct stat expected;
    if (lstat("/private/etc/hosts", &expected) != 0) return -1;
    if (!S_ISREG(expected.st_mode)) { errno = ELOOP; return -1; }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return -1;
    fcntl(sockets[0], F_SETFD, FD_CLOEXEC);
    fcntl(sockets[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, sockets[0]);
    posix_spawn_file_actions_addclose(&actions, sockets[1]);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    char *read_args[] = {"/usr/libexec/authopen", "-stdoutpipe", "/private/etc/hosts", NULL};
    char *write_args[] = {"/usr/libexec/authopen", "-stdoutpipe", "-w", "-a", "/private/etc/hosts", NULL};
    char **args = writable ? write_args : read_args;
    pid_t pid;
    int error = posix_spawn(&pid, args[0], &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);
    if (error) { close(sockets[0]); errno = error; return -1; }
    int descriptor = -1, saved = EACCES;
    int ready = dashboard_poll_until(sockets[0], dashboard_monotonic_ms() + 600000);
    if (ready > 0) {
        char byte;
        struct iovec data = {&byte, 1};
        union {struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))];} control;
        memset(&control, 0, sizeof(control));
        struct msghdr message = {0};
        message.msg_iov = &data; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        ssize_t received;
        do { received = recvmsg(sockets[0], &message, 0); } while (received < 0 && errno == EINTR);
        if (received > 0 && !(message.msg_flags & MSG_CTRUNC)) {
            struct cmsghdr *header = CMSG_FIRSTHDR(&message);
            if (header && header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS && header->cmsg_len >= CMSG_LEN(sizeof(int)))
                memcpy(&descriptor, CMSG_DATA(header), sizeof(descriptor));
        }
    } else { saved = ready == 0 ? ETIMEDOUT : errno; }
    close(sockets[0]);
    dashboard_reap(pid, descriptor < 0);
    if (descriptor >= 0) {
        struct stat actual, current;
        int flags = fcntl(descriptor, F_GETFL);
        if (fstat(descriptor, &actual) != 0 || lstat("/private/etc/hosts", &current) != 0
            || !S_ISREG(actual.st_mode) || !S_ISREG(current.st_mode)
            || expected.st_dev != actual.st_dev || expected.st_ino != actual.st_ino
            || current.st_dev != actual.st_dev || current.st_ino != actual.st_ino
            || flags < 0 || (flags & O_ACCMODE) != (writable ? O_RDWR : O_RDONLY)
            || (writable && !(flags & O_APPEND))) {
            close(descriptor); errno = EINVAL; return -1;
        }
        fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    } else errno = saved;
    return descriptor;
}

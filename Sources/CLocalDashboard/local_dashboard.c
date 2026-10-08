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
extern char **environ;

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
    struct pollfd waiter = {sockets[0], POLLIN, 0};
    int ready;
    do { ready = poll(&waiter, 1, 600000); } while (ready < 0 && errno == EINTR);
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
    } else { saved = ready == 0 ? ETIMEDOUT : errno; kill(pid, SIGTERM); }
    close(sockets[0]);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
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

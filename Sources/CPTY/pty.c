#include "CPTY.h"
#include <util.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <string.h>

// All allocations and Swift work happen before fork. The child uses only
// async-signal-safe libc calls before execve; it never enters the Swift runtime.
int ap_pty_spawn(const char *cwd, char *const argv[], char *const env[], int rows, int columns, int *pid, int *master, char *tty) {
    int errors[2];
    if (pipe(errors) < 0) return errno;
    fcntl(errors[0], F_SETFD, FD_CLOEXEC); fcntl(errors[1], F_SETFD, FD_CLOEXEC);
    int fd_limit = getdtablesize();
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    sigset_t empty; sigemptyset(&empty);
    struct sigaction action; memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    int child = forkpty(master, tty, NULL, &size);
    if (child < 0) { int result = errno; close(errors[0]); close(errors[1]); return result; }
    if (child == 0) {
        close(errors[0]);
        for (int fd = 3; fd < fd_limit; fd++) if (fd != errors[1]) close(fd);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &action, NULL);
        if (chdir(cwd) == 0) execve(argv[0], argv, env);
        int result = errno; write(errors[1], &result, sizeof(result)); _exit(127);
    }
    close(errors[1]);
    int result = 0; ssize_t count;
    do { count = read(errors[0], &result, sizeof(result)); } while (count < 0 && errno == EINTR);
    close(errors[0]);
    if (count != 0) { close(*master); kill(child, SIGHUP); waitpid(child, NULL, 0); return result ? result : EIO; }
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(*master, F_SETFL, fcntl(*master, F_GETFL) | O_NONBLOCK);
    *pid = child; return 0;
}
int ap_pty_resize(int master, int rows, int columns) {
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(master, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

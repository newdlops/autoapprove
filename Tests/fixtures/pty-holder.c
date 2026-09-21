// Test fixture: run an inert executable on an isolated controlling PTY.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static pid_t child = -1;
static void stop(int signal_number) {
    (void)signal_number;
    if (child > 0) kill(child, SIGTERM);
}
int main(int argc, char **argv) {
    if (argc == 1) {
        char buffer[64];
        while (read(STDIN_FILENO, buffer, sizeof(buffer)) > 0) {}
        return 0;
    }
    if (argc != 2) return 2;
    int master = -1;
    struct winsize size = { .ws_row = 24, .ws_col = 100 };
    child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) { perror("forkpty"); return 1; }
    if (child == 0) { execl(argv[1], argv[1], (char *)NULL); _exit(127); }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    close(master);
    if (WIFSIGNALED(status)) fprintf(stderr, "Fixture child signal: %d\n", WTERMSIG(status));
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) fprintf(stderr, "Fixture child exit: %d\n", WEXITSTATUS(status));
    return 0;
}

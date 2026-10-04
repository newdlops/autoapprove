// An inert orphaned foreground group. Its leader exits while one member waits.
// Used only on a ManagedPTY created in the private integration-test profile.
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "leader")) {
        usleep(300000);
        return 0;
    }
    const pid_t group = getpgrp();
    if (group == getpid()) return 3;
    signal(SIGHUP, SIG_IGN);
    // zsh keeps the pipeline in the foreground while this right-hand member
    // waits, and independently reaps the left-hand process group leader.
    while (kill(group, 0) == 0 || errno != ESRCH) usleep(10000);
    printf("DEAD-GROUP:%d MEMBER:%d SID:%d\r\n", group, getpid(), getsid(0));
    fflush(stdout);
    while (1) pause();
}

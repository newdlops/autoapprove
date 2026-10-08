#include "../../Sources/CLocalDashboard/local_dashboard.c"
#include <sys/time.h>
#include <stdlib.h>

static volatile sig_atomic_t interruptions;
static void interrupt_wait(int signal) {
    (void)signal;
    if (++interruptions == 20) {
        struct itimerval off = {0};
        setitimer(ITIMER_REAL, &off, NULL);
    }
}

int main(void) {
    int pipes[2];
    if (pipe(pipes) != 0) return 1;
    struct sigaction action = {0};
    action.sa_handler = interrupt_wait;
    sigaction(SIGALRM, &action, NULL);
    struct itimerval timer = {.it_interval={0,10000}, .it_value={0,10000}};
    setitimer(ITIMER_REAL, &timer, NULL);
    int64_t started = dashboard_monotonic_ms();
    int result = dashboard_poll_until(pipes[0], started + 80);
    int64_t elapsed = dashboard_monotonic_ms() - started;
    struct itimerval off = {0};
    setitimer(ITIMER_REAL, &off, NULL);
    if (result != 0 || elapsed < 70 || elapsed > 160 || interruptions < 2) return 2;
    puts("PASS administrator deadline remains bounded during repeated real signals");
    if (write(pipes[1], "x", 1) != 1 || dashboard_poll_until(pipes[0], dashboard_monotonic_ms()+80) != 1) return 3;
    close(pipes[0]); close(pipes[1]);
    puts("PASS ready descriptor still returns immediately");
    int child_ready[2]; if (pipe(child_ready) != 0) return 4;
    pid_t child = fork();
    if (child < 0) return 4;
    if (child == 0) {
        close(child_ready[0]); signal(SIGTERM,SIG_IGN);
        if (write(child_ready[1],"r",1) != 1) _exit(6);
        close(child_ready[1]); for (;;) pause();
    }
    close(child_ready[1]); char acknowledged;
    if (read(child_ready[0],&acknowledged,1) != 1 || acknowledged != 'r') return 5;
    close(child_ready[0]);
    started = dashboard_monotonic_ms(); dashboard_reap(child,1);
    if (dashboard_monotonic_ms()-started > 1500 || waitpid(child,NULL,WNOHANG) != -1 || errno != ECHILD) return 5;
    puts("PASS cancelled unresponsive child is reaped within the bounded grace period");
    return 0;
}

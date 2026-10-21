#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static size_t number(const char *text) {
    char *end; unsigned long long value = strtoull(text, &end, 10);
    if (!*text || *end || value > 134217728) _exit(2);
    return (size_t)value;
}
static int send_bytes(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    while (count) {
        ssize_t written = write(fd, bytes, count);
        if (written > 0) { bytes += written; count -= (size_t)written; }
        else if (written < 0 && errno == EINTR) continue;
        else return 0;
    }
    return 1;
}
static void delay_ms(size_t milliseconds) {
    struct timespec value = { .tv_sec = (time_t)(milliseconds / 1000), .tv_nsec = (long)(milliseconds % 1000) * 1000000 };
    while (nanosleep(&value, &value) != 0 && errno == EINTR) {}
}
static int record_pid(const char *path, pid_t pid, int append) {
    int file = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (append ? O_APPEND : O_EXCL), 0600);
    if (file < 0) return 0;
    char text[32]; int count = snprintf(text, sizeof(text), "%d\n", pid);
    int ok = send_bytes(file, text, (size_t)count); close(file); return ok;
}
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    signal(SIGPIPE, SIG_IGN);
    if (!strcmp(argv[1], "environment")) {
        const char *value = getenv("AUTOAPPROVE_PIPE_FIXTURE");
        return !value || send_bytes(STDOUT_FILENO, value, strlen(value)) ? 0 : 3;
    }
    if (!strcmp(argv[1], "once") && argc == 4) {
        if (!record_pid(argv[2], getpid(), 1)) return 6;
        size_t count = number(argv[3]); unsigned char bytes[16384]; memset(bytes, 'a', sizeof(bytes));
        while (count) { size_t n = count < sizeof(bytes) ? count : sizeof(bytes); if (!send_bytes(STDOUT_FILENO, bytes, n)) return 3; count -= n; }
        return 0;
    }
    if (!strcmp(argv[1], "empty")) return 0;
    if (!strcmp(argv[1], "bytes") && argc >= 4) {
        size_t out = number(argv[2]), err = number(argv[3]);
        unsigned char a[16384], e[16384]; memset(a, 'a', sizeof(a)); memset(e, 'e', sizeof(e));
        while (out || err) {
            size_t n = out < sizeof(a) ? out : sizeof(a);
            if (n && !send_bytes(STDOUT_FILENO, a, n)) return 3; out -= n;
            n = err < sizeof(e) ? err : sizeof(e);
            if (n && !send_bytes(STDERR_FILENO, e, n)) return 3; err -= n;
        }
        return argc > 4 ? (int)number(argv[4]) : 0;
    }
    if (!strcmp(argv[1], "echo") || !strcmp(argv[1], "echo-error")) {
        unsigned char buffer[16384];
        for (;;) {
            ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (count > 0) { if (!send_bytes(!strcmp(argv[1], "echo-error") ? STDERR_FILENO : STDOUT_FILENO, buffer, (size_t)count)) return 3; }
            else if (!count) return 0;
            else if (errno != EINTR) return 4;
        }
    }
    if (!strcmp(argv[1], "sleep") && argc >= 3) {
        if (argc > 3 && !strcmp(argv[3], "ignore-term")) signal(SIGTERM, SIG_IGN);
        if (argc > 4 && !record_pid(argv[4], getpid(), 0)) return 6;
        delay_ms(number(argv[2])); return 0;
    }
    if ((!strcmp(argv[1], "hold") || !strcmp(argv[1], "hold-input")) && argc == 3) {
        int hold_input = !strcmp(argv[1], "hold-input");
        pid_t child = fork(); if (child < 0) return 5;
        if (!child) {
            close(hold_input ? STDOUT_FILENO : STDIN_FILENO); close(STDERR_FILENO);
            delay_ms(2400);
            if (hold_input) { unsigned char byte; while (read(STDIN_FILENO, &byte, 1) < 0 && errno == EINTR) {} _exit(0); }
            int ok = send_bytes(STDOUT_FILENO, "child\n", 6); _exit(ok ? 0 : 3);
        }
        int file = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (file < 0) return 6;
        char pid[32]; int count = snprintf(pid, sizeof(pid), "%d\n", child);
        int ok = send_bytes(file, pid, (size_t)count); close(file);
        if (!ok) return 6;
        return hold_input || send_bytes(STDOUT_FILENO, "parent\n", 7) ? 0 : 3;
    }
    return 2;
}

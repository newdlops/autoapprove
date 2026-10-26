// Raw byte sink/echo for one private PTY. Never executes commands or uses LAN.
#include <stdio.h>
#include <unistd.h>
#include <termios.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *record = fopen(argv[1], "wb"); if (!record) return 3;
    struct termios options;
    if (tcgetattr(0, &options)) return 4;
    cfmakeraw(&options); if (tcsetattr(0, TCSANOW, &options)) return 5;
    printf("\r\nBYTE-ECHO-READY\r\n"); fflush(stdout);
    unsigned char bytes[4096]; ssize_t count;
    while ((count = read(0, bytes, sizeof bytes)) > 0) {
        if (fwrite(bytes, 1, count, record) != count || fflush(record)) return 6;
        if (fwrite(bytes, 1, count, stdout) != count || fflush(stdout)) return 7;
    }
    fclose(record); return 0;
}

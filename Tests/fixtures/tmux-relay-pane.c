#include <termios.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

// A private QA pane, never an existing user session. Records exact input bytes.
int main(int argc, char **argv) {
    struct termios mode;
    if (tcgetattr(STDIN_FILENO, &mode)) return 2;
    cfmakeraw(&mode);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &mode)) return 3;
    const char *initial = "\033[2J\033[H\033[38;2;70;160;220mTMUX QA\033[0m\r\n\033[3;6H\033[6 q";
    write(STDOUT_FILENO, initial, strlen(initial));
    FILE *record = argc > 1 ? fopen(argv[1], "ab") : NULL;
    unsigned char bytes[4096]; ssize_t size;
    while ((size = read(STDIN_FILENO, bytes, sizeof(bytes))) > 0) {
        if (record) { fwrite(bytes, 1, size, record); fflush(record); }
        write(STDOUT_FILENO, bytes, size);
    }
    if (record) fclose(record);
    return 0;
}

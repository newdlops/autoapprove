// Inert local CLI fixture. Never talks to a model or runs commands.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <string.h>
#include <signal.h>
int main(int argc, char **argv) {
    const char *rollout = getenv("AUTOAPPROVE_QA_ROLLOUT");
    if (rollout) open(rollout, O_RDONLY); // exact PID-to-conversation binding
    struct termios options; tcgetattr(0, &options); cfmakeraw(&options); tcsetattr(0, TCSANOW, &options);
    if(argc>1&&!strcmp(argv[1],"--ignore-hup")){signal(SIGHUP,SIG_IGN);printf("CHILD-PID:%d\r\n",getpid());fflush(stdout);while(1)pause();}
    printf("\033[2J\033[H\033[38;2;135;215;255mPTY QA CLI\033[0m\r\n");
    if (argc > 2 && !strcmp(argv[1], "fork")) printf("RESUMED-ID:%s\r\n", argv[2]);
    printf("READY> "); fflush(stdout);
    char line[4096]; size_t length = 0; int approval = 0;
    unsigned char c;
    while (read(0, &c, 1) == 1) {
        if (c == 4) return 0;
        if (c == 3) { printf("\r\nINTERRUPTED\r\nREADY> "); length=0; }
        else if (c == 13 || c == 10) {
            line[length]=0;
            if (!strcmp(line,"burst")) {
                for (int n=0;n<2500;n++) puts("BURST-OUTPUT-0123456789012345678901234567890123456789012345678901234567890123456789\r");
                printf("BURST-END\r\n"); fflush(stdout); return 7;
            }
            if (!strcmp(line,"ignore-hup")) { signal(SIGHUP,SIG_IGN); printf("\r\nIGNORING-HUP\r\n"); fflush(stdout); while(1)pause(); }
            else if (approval && !strcmp(line,"1")) { printf("\033[2J\033[HAUTO-APPROVED\r\nREADY> "); approval=0; }
            else if (!strcmp(line,"permission")) {
                approval=1;
                printf("\033[2J\033[HWould you like to run the following command?\r\n\r\n  $ echo inert-pty-test\r\n\r\n› 1. Yes, proceed\r\n  2. No, and tell Codex what to do differently\r\n\r\n  Press enter to confirm or esc to cancel\r\n");
            } else if (!strcmp(line,"tui")) printf("\033[?1049h\033[2J\033[H\033[?25l\033[38;2;12;234;56mORIGINAL-TUI\033[0m\033[5;9H");
            else if (!strcmp(line,"normal")) printf("\033[?1049l\033[?25h\r\nRETURNED-FROM-TUI\r\nREADY> ");
            else printf("\r\nRECEIVED:%s\r\nREADY> ",line);
            length=0;
        } else if (c==127) { if(length){length--;printf("\b \b");} }
        else if (length < sizeof(line)-1) { line[length++]=c; putchar(c); }
        fflush(stdout);
    }
    return 0;
}

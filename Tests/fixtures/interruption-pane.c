#include <termios.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "resume")) {
        FILE *f = argc > 4 ? fopen(argv[4], "w") : NULL;
        if (!f) return 4;
        fprintf(f, "%s\n%s", argv[2], argv[3]); fclose(f); return 0;
    }
    struct termios original, mode;
    if (argc < 2 || tcgetattr(0,&original)) return 2;
    mode=original; cfmakeraw(&mode); if(tcsetattr(0,TCSANOW,&mode))return 3;
    const char *frame="\033[2J\033[H■ stream disconnected before completion: network error\r\n\r\n› Ask Codex to do anything\r\n\r\n? for shortcuts";
    write(1,frame,strlen(frame));
    FILE *f=fopen(argv[1],"ab");if(!f)return 4;
    unsigned char bytes[4096];ssize_t count;
    while((count=read(0,bytes,sizeof(bytes)))>0){
        fwrite(bytes,1,count,f);fflush(f);
        if(memchr(bytes,'\r',count)){
            const char *working="\033[2J\033[H› 이어서 진행하자.\r\n\r\nWorking · esc to interrupt\r\n\r\n› Ask Codex to do anything\r\n\r\n? for shortcuts";write(1,working,strlen(working));break;
        }
        const char *draft="\033[2J\033[H■ stream disconnected before completion: network error\r\n\r\n› 이어서 진행하자.\r\n\r\n? for shortcuts";write(1,draft,strlen(draft));
    }
    fclose(f);tcsetattr(0,TCSANOW,&original);return 0;
}

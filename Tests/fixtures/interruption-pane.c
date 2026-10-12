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
    int numeric=argc>2 && !strcmp(argv[2],"request-choice");
    if(numeric || (argc>2 && !strcmp(argv[2],"choice"))){
        FILE *record=fopen(argv[1],"ab");if(!record)return 4;
        int selected=numeric?0:1,question=1,escape=0,done=0;unsigned char byte;char frame[4096];
        while(!done){
            if(numeric)snprintf(frame,sizeof(frame),"\033[2J\033[HQuestion %d/2 (%d unanswered)\r\n\r\n어떤 화면을 점검할까요?\r\n\r\n%s 1. 휴대폰 화면\r\n%s 2. 데스크톱 화면\r\n  3. None of the above\r\n\r\ntab to add notes | enter to submit %s | ←/→ to navigate questions | esc to interrupt",question,3-question,selected==0?"›":" ",selected==1?"›":" ",question==1?"answer":"all");
            else snprintf(frame,sizeof(frame),"\033[2J\033[H어떤 화면을 점검할까요?\r\n\r\n%s 1. 휴대폰 화면\r\n%s 2. 데스크톱 화면\r\n%s 3. 두 화면 모두\r\n\r\nPress enter to confirm or esc to cancel",selected==0?"›":" ",selected==1?"›":" ",selected==2?"›":" ");
            write(1,frame,strlen(frame));
            if(read(0,&byte,1)!=1)break;
            fwrite(&byte,1,1,record);fflush(record);
            if(numeric && byte>='1' && byte<='3'){
                selected=byte-'1';
                if(question==1){question=2;selected=0;}else done=1;
            }else if(byte==13)done=1;
            else if(byte==27)escape=1;
            else if(escape==1 && byte=='[')escape=2;
            else if(escape==2){if(byte=='A'&&selected>0)selected--;if(byte=='B'&&selected<2)selected++;escape=0;}
            else if(byte==14 && selected<2)selected++;
            else if(byte==16 && selected>0)selected--;
        }
        char result[4096];snprintf(result,sizeof(result),"%s.selection",argv[1]);FILE *selection=fopen(result,"w");if(selection){fprintf(selection,"%d",selected+1);fclose(selection);}
        const char *ready="\033[2J\033[HSelection received\r\n\r\n› Ask Codex to do anything";write(1,ready,strlen(ready));
        fclose(record);usleep(750000);tcsetattr(0,TCSANOW,&original);return 0;
    }
    int goal=argc>2 && !strcmp(argv[2],"goal");
    int blocked=argc>2 && !strcmp(argv[2],"blocked");
    int capacity=argc>2 && (!strcmp(argv[2],"capacity") || !strcmp(argv[2],"capacity-goal"));
    goal=goal||(argc>2 && !strcmp(argv[2],"capacity-goal"));
    goal=goal||blocked;
    const char *heading=capacity?"■ Selected model is at capacity. Please try a different model.":blocked?"• External dependency still unavailable":"■ stream disconnected before completion: network error";
    const char *text=goal?"/goal resume":"이어서 진행하자.";
    const char *status=goal?" · Goal stalled (/goal resume)":"";
    char frame[4096];
    snprintf(frame,sizeof(frame),"\033[2J\033[H%s\r\n\r\n› Ask Codex to do anything\r\n\r\n? for shortcuts%s",heading,status);
    write(1,frame,strlen(frame));
    FILE *f=fopen(argv[1],"ab");if(!f)return 4;
    unsigned char bytes[4096];ssize_t count;
    while((count=read(0,bytes,sizeof(bytes)))>0){
        fwrite(bytes,1,count,f);fflush(f);
        if(memchr(bytes,'\r',count)){
            const char *working=goal
                ? "\033[2J\033[H› Ask Codex to do anything\r\n\r\n? for shortcuts · Pursuing goal"
                : "\033[2J\033[H› 이어서 진행하자.\r\n\r\nWorking · esc to interrupt";
            write(1,working,strlen(working));usleep(750000);break;
        }
        snprintf(frame,sizeof(frame),"\033[2J\033[H%s\r\n\r\n› %s\r\n\r\n? for shortcuts%s",heading,text,status);
        write(1,frame,strlen(frame));
    }
    fclose(f);tcsetattr(0,TCSANOW,&original);return 0;
}

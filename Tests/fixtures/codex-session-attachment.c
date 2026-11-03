// Disposable CLI for an app-owned PTY; no user terminal or Codex credentials.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
int main(int argc,char **argv) {
    int fd=-1;
    if(argc>1) {
        if(argc!=5||strcmp(argv[1],"--remote")||strcmp(argv[2],"unix://")||strcmp(argv[3],"resume")||strcmp(argv[4],getenv("EXPECTED_THREAD")))return 12;
        struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;addr.sun_len=sizeof(addr);
        const char *path=getenv("FIXTURE_SOCKET");if(!path||strlen(path)>=sizeof(addr.sun_path))return 13;strcpy(addr.sun_path,path);
        fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0||connect(fd,(struct sockaddr*)&addr,sizeof(addr)))return 14;
    }
    FILE *out=fopen(getenv("READY_FILE"),"w");if(!out)return 15;fprintf(out,"%d %d\n",getpid(),argc);fclose(out);
    puts("\n› Ask Codex to do anything\n\n? for shortcuts");fflush(stdout);
    char line[4096];while(fgets(line,sizeof(line),stdin)){if(!strcmp(line,"/exit\n"))break;}
    if(fd>=0)close(fd);return 0;
}

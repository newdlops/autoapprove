// SQLite-only idle CLI fixture. All files and PTYs belong to the test.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
static void ready(void){puts("\n› Ask Codex to do anything\n\n? for shortcuts");fflush(stdout);}
int main(int argc,char **argv) {
    char db[4096],cwd[4096];getcwd(cwd,sizeof(cwd));snprintf(db,sizeof(db),"%s/logs_2.sqlite",getenv("CODEX_HOME"));
    int metadata=open(db,O_CREAT|O_RDWR,0600);if(metadata<0)return 10;
    int fd=-1;
    if(argc>1){
        if(argc!=5||strcmp(argv[1],"--remote")||strcmp(argv[2],"unix://")||strcmp(argv[3],"resume")||strcmp(argv[4],getenv("EXPECTED_THREAD")))return 12;
        struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;addr.sun_len=sizeof(addr);const char *path=getenv("FIXTURE_SOCKET");
        if(!path||strlen(path)>=sizeof(addr.sun_path))return 13;strcpy(addr.sun_path,path);
        fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0||connect(fd,(struct sockaddr*)&addr,sizeof(addr)))return 14;
    }
    FILE *out=fopen(getenv("READY_FILE"),"w");if(!out)return 15;fprintf(out,"%d %d\n",getpid(),argc);fclose(out);ready();
    char line[4096];while(fgets(line,sizeof(line),stdin)){
        if(!strcmp(line,"/exit\n"))break;
        if(!strcmp(line,"/fixture-progress\n")){puts("Goal completed");ready();}
        if(!strcmp(line,"/status\n")){
            printf("\n/status\n\n  >_ OpenAI Codex (v0.166.0)\n\n  Model: synthetic\n  Directory: %s\n  Permissions: Read Only\n  Agents.md: none\n  Session: %s\n  Token usage: 0\n",cwd,getenv("STATUS_THREAD") ? getenv("STATUS_THREAD"):getenv("EXPECTED_THREAD"));ready();
        }
    }
    if(fd>=0)close(fd);close(metadata);return 0;
}

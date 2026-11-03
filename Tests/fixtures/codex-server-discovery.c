// Owned synthetic process/PTY and Unix client only. Never controls a user TTY.
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc,char **argv) {
    if(argc==3 && strcmp(argv[2],"--client")==0) {
        int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un address={0};
        address.sun_family=AF_UNIX;address.sun_len=sizeof(address);
        if(strlen(argv[1])>=sizeof(address.sun_path))return 10;
        strcpy(address.sun_path,argv[1]);
        if(fd<0 || connect(fd,(struct sockaddr*)&address,sizeof(address)))return 11;
        if(write(fd,"ready",5)!=5)return 12;
        for(;;)pause();
    }
    if(argc!=4)return 20;
    int master=-1;pid_t child=forkpty(&master,NULL,NULL,NULL);
    if(child<0)return 21;
    if(child==0) {char *args[]={argv[3],argv[1],"--client",NULL};execv(argv[2],args);_exit(22);}
    printf("%d\n",child);fflush(stdout);
    char line[8];while(fgets(line,sizeof(line),stdin)){}
    if(waitpid(child,NULL,WNOHANG)==0){kill(child,SIGTERM);waitpid(child,NULL,0);}
    close(master);return 0;
}

// Inert connector: records only its own test arguments, never contacts a server.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
int main(int argc, char **argv) {
    const char *home=getenv("HOME");if(!home)return 2;
    char path[4096];snprintf(path,sizeof path,"%s/arguments.bin",home);
    FILE *file=fopen(path,"wb");if(!file)return 3;
    for(int i=0;i<argc;i++)fwrite(argv[i],1,strlen(argv[i])+1,file);fclose(file);
    snprintf(path,sizeof path,"%s/pid",home);file=fopen(path,"w");if(!file)return 4;fprintf(file,"%d",getpid());fclose(file);
    for(int i=1;i+1<argc;i++)if(!strcmp(argv[i],"--token-file")){
        file=fopen(argv[i+1],"r");if(file){char token[1024];size_t count=fread(token,1,sizeof token,file);fclose(file);fputs("simulated private token diagnostic: ",stderr);fwrite(token,1,count,stderr);fputc('\n',stderr);}
    }
    fputs("Registered tunnel connection\n",stderr);fflush(stderr);
    while(1)pause();
}

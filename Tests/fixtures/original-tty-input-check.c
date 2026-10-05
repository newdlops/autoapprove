// Only an owned, inert PTY is touched. No input goes to a user's terminal.
#include "CTTYInput.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static const unsigned char payload[]={0xed,0x95,0x9c,0xea,0xb8,0x80,0xf0,0x9f,0x99,0x82,0x1b,'[','D',0x7f,0x09,0x03,'\r'};
static void rejected(const APTTYIdentity *identity,uid_t uid,const char *tty,int expected){
    APTTYWriteResult result={0};
    assert(ap_tty_write(identity,uid,tty,payload,sizeof(payload),ap_tty_uptime()+2,&result)==expected);
    assert(result.written==0);
}
int main(void){
    int master,slave;char tty[128];
    assert(openpty(&master,&slave,tty,NULL,NULL)==0);
    pid_t child=fork();assert(child>=0);
    if(child==0){
        close(master);alarm(10);
        assert(setsid()>0);assert(ioctl(slave,TIOCSCTTY,0)==0);assert(tcsetpgrp(slave,getpgrp())==0);
        struct termios mode;assert(tcgetattr(slave,&mode)==0);cfmakeraw(&mode);assert(tcsetattr(slave,TCSANOW,&mode)==0);
        APTTYIdentity identity;assert(ap_tty_identity(getpid(),&identity)==0);
        assert(identity.pid==getpid()&&identity.uid==getuid()&&identity.euid==geteuid());
        APTTYIdentity changed=identity;changed.start_microseconds++;
        rejected(&changed,getuid(),tty,ESTALE);
        changed=identity;changed.device++;
        rejected(&changed,getuid(),tty,ESTALE);
        changed=identity;changed.process_group++;
        rejected(&changed,getuid(),tty,ESTALE);
        rejected(&identity,getuid()+1,tty,EACCES);
        rejected(&identity,getuid(),"/dev/ttys001/../ttys002",EINVAL);
        rejected(&identity,getuid(),"/dev/tty",EINVAL);
        rejected(&identity,getuid(),"/dev/ttys99999",ENOENT);
        APTTYWriteResult result={0};
        assert(ap_tty_write(&identity,getuid(),tty,payload,sizeof(payload),ap_tty_uptime()-1,&result)==ETIMEDOUT);
        assert(result.written==0);
        assert(ap_tty_write(&identity,getuid(),tty,payload,sizeof(payload),ap_tty_uptime()+60,&result)==EINVAL);
        assert(result.written==0);
        int pending=-1;assert(ioctl(slave,FIONREAD,&pending)==0&&pending==0);
        int delivered=ap_tty_write(&identity,getuid(),tty,payload,sizeof(payload),ap_tty_uptime()+2,&result);
        if(delivered)fprintf(stderr,"Owned fixture delivery: errno=%d (%s), written=%zu\n",delivered,strerror(delivered),result.written);
        assert(delivered==0);
        assert(result.written==sizeof(payload));
        unsigned char received[sizeof(payload)];size_t count=0;
        while(count<sizeof(received)){ssize_t n=read(slave,received+count,sizeof(received)-count);assert(n>0);count+=(size_t)n;}
        assert(!memcmp(payload,received,sizeof(payload)));
        // An ioctl can succeed even when macOS drops a full input queue. A
        // delayed reader must receive every byte beyond MAX_INPUT (1,024).
        unsigned char large[8000];for(size_t i=0;i<sizeof(large);i++)large[i]=(unsigned char)(32+i%91);
        pid_t reader=fork();assert(reader>=0);
        if(reader==0){
            usleep(120000);unsigned char buffer[sizeof(large)];size_t size=0;
            while(size<sizeof(buffer)){ssize_t n=read(slave,buffer+size,sizeof(buffer)-size);assert(n>0);size+=(size_t)n;}
            _exit(memcmp(large,buffer,sizeof(large))?1:0);
        }
        assert(ap_tty_write(&identity,getuid(),tty,large,sizeof(large),ap_tty_uptime()+2,&result)==0);
        assert(result.written==sizeof(large));int reader_status;
        assert(waitpid(reader,&reader_status,0)==reader&&WIFEXITED(reader_status)&&WEXITSTATUS(reader_status)==0);
        // When nobody reads, stop before overflow and report partial submission.
        assert(ap_tty_write(&identity,getuid(),tty,large,1025,ap_tty_uptime()+0.08,&result)==ETIMEDOUT);
        assert(result.written>0&&result.written<=513&&result.written<1025);
        unsigned char partial[513];count=0;
        while(count<result.written){ssize_t n=read(slave,partial+count,result.written-count);assert(n>0);count+=(size_t)n;}
        assert(!memcmp(large,partial,count));
        mode.c_lflag|=ICANON;assert(tcsetattr(slave,TCSANOW,&mode)==0);
        rejected(&identity,getuid(),tty,EOPNOTSUPP);
        puts("PASS: original TTY exact UTF-8/cursor/control bytes and delayed-reader 8,000 bytes; stopped reader reports partial timeout without overflow; changed identity/device/job, foreign UID, invalid paths, deadline and canonical mode reject before input");
        return 0;
    }
    close(slave);int status=0;assert(waitpid(child,&status,0)==child);close(master);
    return !WIFEXITED(status)||WEXITSTATUS(status)!=0;
}

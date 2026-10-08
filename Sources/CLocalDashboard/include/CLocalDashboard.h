#ifndef AUTOAPPROVE_LOCAL_DASHBOARD_H
#define AUTOAPPROVE_LOCAL_DASHBOARD_H
/* Fixed /private/etc/hosts only; 0 reads, 1 opens append/read-write after OS authorization. */
int aa_open_dashboard_hosts(int writable);
#endif

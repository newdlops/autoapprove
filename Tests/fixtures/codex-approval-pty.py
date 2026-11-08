import os,sys,pty,fcntl,termios,struct,select,json,base64,signal,time
pid,fd=pty.fork()
if pid==0:
 os.execv(sys.argv[1],sys.argv[1:])
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
pending=b''
try:
 while True:
  ready,_,_=select.select([fd,sys.stdin.buffer],[],[],1)
  if fd in ready:
   try:data=os.read(fd,65536)
   except OSError:break
   if not data:break
   if b'\x1b[6n' in data:os.write(fd,b'\x1b[1;1R')
   if b'\x1b[c' in data:os.write(fd,b'\x1b[?1;2c')
   print(json.dumps({'bytes':base64.b64encode(data).decode()}),flush=True)
  if sys.stdin.buffer in ready:
   chunk=os.read(sys.stdin.fileno(),4096)
   if not chunk:break
   pending+=chunk
   while b'\n' in pending:
    line,pending=pending.split(b'\n',1)
    msg=json.loads(line)
    if 'keys' in msg:os.write(fd,msg['keys'].encode())
finally:
 try:os.kill(pid,signal.SIGTERM)
 except ProcessLookupError:pass
 for _ in range(30):
  found,status=os.waitpid(pid,os.WNOHANG)
  if found:break
  time.sleep(.1)
 else:
  os.kill(pid,signal.SIGKILL)
  found,status=os.waitpid(pid,0)
 print('TUI process status '+str(status),file=sys.stderr)
 os.close(fd)

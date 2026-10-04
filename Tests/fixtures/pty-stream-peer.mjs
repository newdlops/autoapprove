// Inert loopback-only peer for streaming framing, bounds and cancellation QA.
// It never creates a PTY, accepts input, or invokes a user's CLI.
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';

export async function startPTYStreamPeer(template) {
  const nodeID=randomUUID(), pty={ptyID:randomUUID(),streamID:randomUUID()};
  let mode='fragmented', lastStreamClosed;
  const sockets=new Set();
  const state={...template,id:nodeID,name:'Inert SSE transport peer',sessions:[]};
  function json(socket,status,body){const text=JSON.stringify(body);socket.end(`HTTP/1.1 ${status} Response\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(text)}\r\nConnection: close\r\n\r\n${text}`);}
  const server=createServer(socket=>{
    sockets.add(socket);socket.on('error',()=>{});socket.on('close',()=>sockets.delete(socket));
    let request='';
    function receive(chunk){
      request+=chunk.toString();
      if(request.length>16384){socket.destroy();return;}
      if(!request.includes('\r\n\r\n'))return;
      socket.removeListener('data',receive);
      const target=new URL(request.split('\r\n')[0].split(' ')[1],'http://127.0.0.1');
      if(target.pathname==='/api/state'){json(socket,200,state);return;}
      if(target.pathname==='/api/discovery'){json(socket,200,{service:'autoapprove',version:1,id:nodeID,name:state.name,urls:[url],port:server.address().port,portal:false,release:state.release});return;}
      if(target.pathname!=='/api/pty/stream'){json(socket,404,{error:'Inert fixture supports output only'});return;}
      lastStreamClosed=new Promise(resolve=>socket.once('close',resolve));
      const identity=mode==='mismatch'?randomUUID():nodeID;
      const headers=`HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nX-AutoApprove-Node: ${identity}\r\nConnection: close\r\n\r\n`;
      if(mode==='incomplete'){socket.end(headers+'event: output\nid: 1\ndata: {"ptyID":"truncated');return;}
      if(mode==='oversized'){socket.end(headers+'event: output\ndata: "'+'x'.repeat(2_000_128)+'"\n\n');return;}
      const output={...pty,offset:1,data:Buffer.from('FRAGMENTED-PEER\r\n').toString('base64'),reset:true,columns:80,rows:24,canInput:false,...(mode==='cancel'?{}:{exitCode:0})};
      const frame='event: output\nid: 1\ndata: '+JSON.stringify(output)+'\n\n';
      if(mode==='cancel'){socket.write(headers+frame);return;}
      socket.write(headers+frame.slice(0,40));
      setTimeout(()=>socket.end(frame.slice(40)),20);
    }
    socket.on('data',receive);
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  const url='http://127.0.0.1:'+server.address().port;
  return {
    nodeID,pty,url,setMode(value){mode=value;},
    async waitForStreamClose(){
      assertStreamStarted();let timeout;
      try{await Promise.race([lastStreamClosed,new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('Disconnected browser retained its peer socket')),2000);})]);}
      finally{clearTimeout(timeout);}
    },
    async stop(){sockets.forEach(socket=>socket.destroy());await new Promise(resolve=>server.close(resolve));}
  };
  function assertStreamStarted(){if(!lastStreamClosed)throw new Error('No inert peer stream has started');}
}

'use strict';
// The shared viewer owns this writer. Sent input is never put back in its queue.
window.AutoApproveScreenControl = class {
  constructor(options) {
    Object.assign(this,options);this.state='idle';this.queue=[];this.queueBytes=0;this.sequence=0;this.listeners=[];
    this.pressed=new Set();this.touches=new Map();this.captures=new Set();this.encoder=new TextEncoder();this.composing=false;this.samples=[];
  }
  get active(){return this.state==='ready';}
  frame(value){if(value?.shareID===this.share.id&&value.controlVersion===1)this.frameAt=performance.now();}
  async open(){
    this.state='opening';this.onState?.();
    try{
      const grant=await this.post('/api/screen/control',{action:'begin',shareID:this.share.id});
      this.grant=grant;
      if(this.state==='closed'){this.end();return null;}
      if(grant.shareID!==this.share.id||typeof grant.controlID!=='string'||typeof grant.token!=='string'||grant.token.length!==44||!grant.keyCodes)throw Error('Mac의 화면 조작 연결을 확인하지 못했습니다.');
      this.heartbeatTimer=setInterval(()=>this.heartbeat(),1000);this.heartbeat();
      if(window.AutoApproveInputChannel){
        const channel=new window.AutoApproveInputChannel(this.node.id,{mode:'screen',shareID:this.share.id,controlID:grant.controlID,streamID:grant.controlID,token:grant.token},{
          onChange:()=>this.drain(),onQuality:value=>this.onQuality?.(value),onFailure:error=>this.stop(error)
        });
        this.channel=channel;const opened=await channel.open();if(this.state==='closed'){channel.close();return null;}if(!opened)this.channel=null;
      }
      this.state='ready';this.install();
      if(this.channel){clearInterval(this.heartbeatTimer);this.heartbeatTimer=null;}
      this.staleTimer=setInterval(()=>{if(this.active&&performance.now()-(this.frameAt||0)>3000)this.stop(Error('공유 화면이 오래되어 조작을 멈췄습니다. 화면이 연결되면 다시 조작해주세요.'));},500);
      this.onState?.();return this;
    }catch(error){this.stop(error);throw error;}
  }
  credentials(){return {shareID:this.share.id,controlID:this.grant.controlID,token:this.grant.token};}
  async heartbeat(){
    if(!['opening','ready'].includes(this.state)||!this.grant||this.heartbeatPending)return;this.heartbeatPending=true;
    try{await this.post('/api/screen/control',{...this.credentials(),action:'heartbeat'});}catch(error){this.stop(error);}finally{this.heartbeatPending=false;}
  }
  end(){if(this.grant)this.post('/api/screen/control',{...this.credentials(),action:'end'},{keepalive:true}).catch(()=>{});}
  stop(error){
    if(this.state==='closed')return;
    this.state='closed';clearInterval(this.heartbeatTimer);clearInterval(this.staleTimer);clearTimeout(this.moveTimer);clearTimeout(this.touchTimer);
    this.channel?.close();this.end();
    const draft=this.queue.filter(item=>item.text).map(item=>item.text).join('');this.queue=[];this.queueBytes=0;
    for(const [target,type,listener,options] of this.listeners)target.removeEventListener(type,listener,options);this.listeners=[];
    for(const id of this.captures)try{if(this.surface.hasPointerCapture(id))this.surface.releasePointerCapture(id);}catch(_){}this.captures.clear();
    this.surface.removeAttribute('data-controlling');this.image.removeAttribute('data-controlling');this.pressed.clear();this.touches.clear();
    if(draft)this.onDraft?.(draft);this.onState?.();if(error)this.onError?.(error);
  }
  listen(target,type,listener,options){target.addEventListener(type,listener,options);this.listeners.push([target,type,listener,options]);}
  enqueue(payload,text){
    if(!this.active)return false;
    if(performance.now()-(this.frameAt||0)>3000){this.stop(Error('최신 공유 화면을 받은 뒤 다시 조작해주세요.'));return false;}
    if(this.queue.length>=64||this.queueBytes+payload.length>64000){this.stop(Error('아직 보내지 못한 입력이 쌓여 조작을 멈췄습니다. 남은 텍스트를 확인해주세요.'));return false;}
    const last=this.queue.at(-1);
    if(payload[0]===0&&last?.payload[0]===0){this.queueBytes-=last.payload.length;this.queue.pop();}
    this.queue.push({payload,text});this.queueBytes+=payload.length;
    if(payload[0]===0){if(!this.moveTimer)this.moveTimer=setTimeout(()=>{this.moveTimer=null;this.drain();},16);}else{clearTimeout(this.moveTimer);this.moveTimer=null;this.drain();}
    return true;
  }
  async drain(){
    if(!this.active||this.sending)return;
    if(this.channel){
      while(this.active&&this.queue.length&&this.channel.canSend(this.queue[0].payload.length)){
        const item=this.queue.shift();this.queueBytes-=item.payload.length;
        if(!this.channel.send(8,item.payload)){if(item.text)this.onDraft?.(item.text);break;}
      }
      return;
    }
    const item=this.queue.shift();if(!item)return;this.queueBytes-=item.payload.length;this.sending=true;
    const sequence=++this.sequence,began=performance.now();
    try{
      let raw='';for(const byte of item.payload)raw+=String.fromCharCode(byte);
      const reply=await this.post('/api/screen/input',{...this.credentials(),sequence,payload:btoa(raw)});
      if(reply.accepted!==true||reply.sequence!==sequence)throw Error('화면 입력의 확인 순서가 바뀌었습니다. 원본 화면을 확인해주세요.');
      const elapsed=performance.now()-began;this.samples.push(elapsed);if(this.samples.length>64)this.samples.shift();const sorted=[...this.samples].sort((a,b)=>a-b);
      this.onQuality?.({transport:'HTTP',medianMS:sorted[Math.ceil(sorted.length*.5)-1],samples:sorted.length});
    }catch(error){this.stop(error);}finally{this.sending=false;if(this.active)queueMicrotask(()=>this.drain());}
  }
  static word(bytes,offset,value){new DataView(bytes.buffer).setUint16(offset,value);}
  static modifiers(event){return (event.shiftKey?1:0)|(event.ctrlKey?2:0)|(event.altKey?4:0)|(event.metaKey?8:0);}
  point(event,clamp=false){
    const rect=this.image.getBoundingClientRect(),width=this.image.naturalWidth,height=this.image.naturalHeight;
    if(!width||!height||!rect.width||!rect.height)return null;
    const scale=Math.min(rect.width/width,rect.height/height),w=width*scale,h=height*scale;
    let x=(event.clientX-rect.left-(rect.width-w)/2)/w,y=(event.clientY-rect.top-(rect.height-h)/2)/h;
    if(!clamp&&(x<0||y<0||x>1||y>1))return null;
    x=Math.max(0,Math.min(1,x));y=Math.max(0,Math.min(1,y));return {x:Math.round(x*65535),y:Math.round(y*65535)};
  }
  move(point,flags=0){const bytes=new Uint8Array(6);bytes[0]=0;this.constructor.word(bytes,1,point.x);this.constructor.word(bytes,3,point.y);bytes[5]=flags;return this.enqueue(bytes);}
  button(down,button,point,flags=0){
    const bytes=new Uint8Array(7);bytes.set([down?1:2,button]);this.constructor.word(bytes,2,point.x);this.constructor.word(bytes,4,point.y);bytes[6]=flags;
    const accepted=this.enqueue(bytes);if(accepted){if(down)this.pressed.add(button);else this.pressed.delete(button);}return accepted;
  }
  wheel(point,dx,dy,flags=0){
    dx=Math.round(Math.max(-2000,Math.min(2000,dx)));dy=Math.round(Math.max(-2000,Math.min(2000,dy)));if(!dx&&!dy)return true;
    const bytes=new Uint8Array(10),view=new DataView(bytes.buffer);bytes[0]=3;this.constructor.word(bytes,1,point.x);this.constructor.word(bytes,3,point.y);view.setInt16(5,dx);view.setInt16(7,dy);bytes[9]=flags;return this.enqueue(bytes);
  }
  text(value){
    if(!value)return true;
    const chunks=[];let chunk='',size=0;
    for(const scalar of value){const length=this.encoder.encode(scalar).length;if(size+length>8000){chunks.push(chunk);chunk='';size=0;}chunk+=scalar;size+=length;}if(chunk)chunks.push(chunk);
    const bytes=chunks.reduce((sum,text)=>sum+this.encoder.encode(text).length+1,0);
    if(this.queue.length+chunks.length>64||this.queueBytes+bytes>64000){this.stop(Error('보낼 텍스트가 너무 길어 조작을 멈췄습니다. 나눠서 입력해주세요.'));return false;}
    if(!this.active)return false;
    if(performance.now()-(this.frameAt||0)>3000){this.stop(Error('최신 공유 화면을 받은 뒤 다시 조작해주세요.'));return false;}
    for(const text of chunks){const value=this.encoder.encode(text),payload=new Uint8Array(value.length+1);payload[0]=4;payload.set(value,1);this.queue.push({payload,text});this.queueBytes+=payload.length;}
    clearTimeout(this.moveTimer);this.moveTimer=null;this.drain();
    return true;
  }
  commit(){if(this.composing||!this.active)return;const value=this.keyboard.value;this.keyboard.value='';if(!this.text(value))this.keyboard.value+=value;this.onDraftChanged?.();}
  key(name,flags=0){
    if(!this.active||this.composing)return false;this.commit();const code=this.grant.keyCodes[name];if(!Number.isInteger(code))return false;
    const bytes=new Uint8Array(4);bytes[0]=5;bytes[1]=flags;this.constructor.word(bytes,2,code);return this.enqueue(bytes);
  }
  focusKeyboard(){if(this.active)this.keyboard.focus({preventScroll:true});}
  release(){clearTimeout(this.touchTimer);this.touchTimer=null;this.touchDragging=false;if(this.pressed.size)this.enqueue(new Uint8Array([6]));this.pressed.clear();}
  pointerDown(event){
    if(!this.active||event.button>2)return;const point=this.point(event);if(!point)return;event.preventDefault();try{this.surface.setPointerCapture(event.pointerId);this.captures.add(event.pointerId);}catch(_){}
    if(event.pointerType==='touch'){
      this.touches.set(event.pointerId,{x:event.clientX,y:event.clientY,point});
      if(this.touches.size>1){clearTimeout(this.touchTimer);this.release();this.touchMulti=true;this.touchCenter=this.center();return;}
      this.touchOrigin={x:event.clientX,y:event.clientY,point};this.touchTimer=setTimeout(()=>{this.touchTimer=null;if(this.active&&this.touches.size===1&&!this.touchMulti){this.button(true,0,point);this.touchDragging=true;}},350);return;
    }
    this.button(true,event.button,point,this.constructor.modifiers(event));
    if(!matchMedia('(pointer:coarse)').matches)this.focusKeyboard();
  }
  pointerMove(event){
    if(!this.active)return;
    if(event.pointerType==='touch'){
      if(!this.touches.has(event.pointerId))return;event.preventDefault();this.touches.set(event.pointerId,{x:event.clientX,y:event.clientY,point:this.point(event,true)});
      if(this.touchMulti){const center=this.center();if(center&&this.touchCenter&&this.touches.size>1)this.wheel(this.point({clientX:center.x,clientY:center.y},true),this.touchCenter.x-center.x,this.touchCenter.y-center.y);this.touchCenter=center;return;}
      const origin=this.touchOrigin;if(!origin)return;
      if(!this.touchDragging&&Math.hypot(event.clientX-origin.x,event.clientY-origin.y)>6){clearTimeout(this.touchTimer);this.touchTimer=null;this.button(true,0,origin.point);this.touchDragging=true;}
      if(this.touchDragging)this.move(this.point(event,true));return;
    }
    const point=this.point(event,this.pressed.size>0);if(point)this.move(point,this.constructor.modifiers(event));
  }
  pointerUp(event){
    if(!this.active)return;
    this.captures.delete(event.pointerId);
    if(event.pointerType==='touch'){
      if(!this.touches.has(event.pointerId))return;event.preventDefault();clearTimeout(this.touchTimer);this.touchTimer=null;
      const point=this.point(event,true),multi=this.touchMulti;this.touches.delete(event.pointerId);
      if(!multi){if(this.touchDragging){this.button(false,0,point);this.touchDragging=false;}else{const button=this.rightClick?2:0;this.move(point);this.button(true,button,point);this.button(false,button,point);}}
      if(!this.touches.size){this.touchOrigin=null;this.touchCenter=null;this.touchMulti=false;}return;
    }
    if(this.pressed.has(event.button)){event.preventDefault();this.button(false,event.button,this.point(event,true),this.constructor.modifiers(event));}
  }
  center(){const values=[...this.touches.values()];return values.length?{x:values.reduce((n,p)=>n+p.x,0)/values.length,y:values.reduce((n,p)=>n+p.y,0)/values.length}:null;}
  keyboardEvent(event){
    if(!this.active||event.isComposing||this.composing||event.keyCode===229)return;
    if(event.key==='Escape'){event.preventDefault();event.stopPropagation();this.stop();this.onExit?.();return;}
    const flags=this.constructor.modifiers(event),plain=(event.key?.length===1||event.key==='Dead')&&!event.ctrlKey&&!event.metaKey;
    if((event.metaKey||event.ctrlKey)&&event.code==='KeyV'&&event.target===this.keyboard)return;
    if(plain&&event.target===this.keyboard)return;
    if(plain){event.preventDefault();this.text(event.key);return;}
    if(Number.isInteger(this.grant.keyCodes[event.code])){event.preventDefault();event.stopPropagation();this.key(event.code,flags);}
  }
  install(){
    this.surface.dataset.controlling='true';this.image.dataset.controlling='true';
    this.listen(this.surface,'pointerdown',event=>this.pointerDown(event));this.listen(this.surface,'pointermove',event=>this.pointerMove(event));this.listen(this.surface,'pointerup',event=>this.pointerUp(event));
    this.listen(this.surface,'pointercancel',()=>{this.release();this.touches.clear();this.touchOrigin=null;this.touchMulti=false;});
    this.listen(this.surface,'lostpointercapture',event=>{if(this.pressed.size&&!this.touches.has(event.pointerId))this.release();});
    this.listen(window,'pointerup',event=>{if(!this.surface.contains(event.target))this.pointerUp(event);});
    this.listen(this.surface,'contextmenu',event=>event.preventDefault());
    this.listen(this.surface,'wheel',event=>{const point=this.point(event);if(point){event.preventDefault();const unit=event.deltaMode===1?16:event.deltaMode===2?this.image.clientHeight:1;this.wheel(point,event.deltaX*unit,event.deltaY*unit,this.constructor.modifiers(event));}},{passive:false});
    this.listen(this.keyboard,'compositionstart',()=>{this.composing=true;});this.listen(this.keyboard,'compositionend',()=>{this.composing=false;queueMicrotask(()=>this.commit());});
    this.listen(this.keyboard,'input',event=>{if(!event.isComposing)this.commit();});this.listen(this.keyboard,'keydown',event=>this.keyboardEvent(event));this.listen(this.surface,'keydown',event=>this.keyboardEvent(event));
    this.listen(window,'blur',()=>this.stop());this.listen(window,'pagehide',()=>this.stop());
  }
};

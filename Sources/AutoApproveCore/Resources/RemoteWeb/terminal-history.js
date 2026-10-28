'use strict';
// Cold, read-only history. At most three small pages are present in the DOM.
window.AutoApproveTerminalHistory=class {
  constructor({api,endpoint}) {
    this.api=api;this.endpoint=endpoint;this.epoch=0;this.pages=[];this.busy=false;
    this.dialog=document.getElementById('terminal-history-dialog');
    this.output=document.getElementById('terminal-history-output');
    this.el=id=>document.getElementById('terminal-history-'+id);
    this.el('close').onclick=()=>this.dialog.close();
    this.el('refresh').onclick=()=>void this.read(null,{refresh:true});
    this.el('first').onclick=()=>void this.read(0);
    this.el('last').onclick=()=>void this.read(this.info.pageCount-1);
    this.el('previous').onclick=()=>void this.edge(-1,true);
    this.el('next').onclick=()=>void this.edge(1,true);
    this.dialog.addEventListener('close',()=>{++this.epoch;this.controller?.abort();this.busy=false;this.pages=[];this.output.replaceChildren();this.info=null;this.item=null;});
    this.output.addEventListener('scroll',()=>{
      if(this.busy||!this.info||this.selectedText())return;
      if(this.output.scrollTop<64&&this.pages[0]?.page>0)void this.edge(-1);
      else if(this.output.scrollHeight-this.output.clientHeight-this.output.scrollTop<64&&this.pages.at(-1)?.page<this.info.pageCount-1)void this.edge(1);
    },{passive:true});
  }
  selectedText() {const selection=window.getSelection();return selection&&!selection.isCollapsed&&(this.output.contains(selection.anchorNode)||this.output.contains(selection.focusNode));}
  async open(item) {
    ++this.epoch;this.controller?.abort();this.item={node:item.node.id,session:item.session.id};this.pages=[];this.info=null;this.busy=false;
    this.el('source').textContent=item.title||item.session.displayName||item.session.cwd||item.session.agent;
    this.output.replaceChildren();this.error('');this.controls();
    if(!this.dialog.open)this.dialog.showModal();this.el('close').focus();
    await this.read(null);
  }
  close(){if(this.dialog.open)this.dialog.close();}
  error(message){this.el('error').hidden=!message;this.el('error').textContent=message;}
  controls(){
    const first=this.pages[0]?.page,last=this.pages.at(-1)?.page,info=this.info;
    for(const name of ['first','previous'])this.el(name).disabled=this.busy||!info||first===0;
    for(const name of ['next','last'])this.el(name).disabled=this.busy||!info||last===info.pageCount-1;
    this.el('refresh').disabled=this.busy;this.output.setAttribute('aria-busy',String(this.busy));
    this.el('range').textContent=info?`${first+1}${first!==last?'–'+(last+1):''} / ${info.pageCount}쪽`:'';
    this.el('status').textContent=this.busy?'Terminal 기록을 불러오는 중…':info?`${new Intl.NumberFormat('ko-KR').format(info.totalLines)}줄 · ${new Date(info.capturedAt).toLocaleTimeString('ko-KR')} 기준`:'';
  }
  validate(value,page,snapshot){
    if(!value||value.sessionID!==this.item.session||typeof value.snapshot!=='string'||!/^[0-9a-f-]{36}$/i.test(value.snapshot)||snapshot&&value.snapshot!==snapshot||
       !Number.isSafeInteger(value.page)||!Number.isSafeInteger(value.pageCount)||value.pageCount<1||value.page<0||value.page>=value.pageCount||page!==null&&value.page!==page||
       !Number.isSafeInteger(value.totalBytes)||value.totalBytes<0||!Number.isSafeInteger(value.totalLines)||value.totalLines<0||typeof value.text!=='string'||value.text.length>16384||
       typeof value.capturedAt!=='string'||!Number.isFinite(Date.parse(value.capturedAt)))throw Error('원래 터미널의 기록을 확인하지 못했습니다. 새로고침해주세요.');
    if(snapshot&&(value.pageCount!==this.info.pageCount||value.totalBytes!==this.info.totalBytes||value.capturedAt!==this.info.capturedAt))throw Error('기록 구성이 바뀌었습니다. 새로고침해주세요.');
    return value;
  }
  async read(page,{refresh=false,edge=0,reveal=false}={}) {
    if(this.busy||!this.item||!this.dialog.open)return;
    const epoch=this.epoch,item=this.item,snapshot=refresh?null:this.info?.snapshot;
    this.busy=true;this.error('');this.controls();this.controller=new AbortController();
    const query=new URLSearchParams({session:item.session});
    if(snapshot)query.set('snapshot',snapshot);
    if(page!==null)query.set('page',String(page));
    if(refresh)query.set('refresh','1');
    try{
      const raw=await this.api(this.endpoint('/api/terminal/history?'+query,item.node),undefined,this.controller.signal,20000);
      if(epoch!==this.epoch||!this.dialog.open||this.item!==item)return;
      const value=this.validate(raw,page,snapshot);
      const node=document.createElement('span');node.className='terminal-history-page';node.textContent=value.text;
      const entry={page:value.page,node};
      if(!edge){this.pages=[entry];this.output.replaceChildren(node);this.output.scrollTop=page===0?0:this.output.scrollHeight;}
      else{
        const anchor=edge<0?this.pages[0]?.node:this.pages.at(-1)?.node,before=anchor?.getBoundingClientRect().top;
        if(edge<0){this.pages.unshift(entry);this.output.prepend(node);if(this.pages.length>3)this.pages.pop().node.remove();}
        else{this.pages.push(entry);this.output.append(node);if(this.pages.length>3)this.pages.shift().node.remove();}
        if(reveal)this.output.scrollTop=edge<0?0:this.output.scrollHeight;
        else if(anchor&&before!==undefined)this.output.scrollTop+=anchor.getBoundingClientRect().top-before;
      }
      this.info=value;
      if(value.totalBytes===0){node.textContent='Terminal에 보관된 출력이 없습니다.';}
    }catch(error){
      if(epoch===this.epoch&&this.dialog.open&&error.name!=='AbortError')this.error(error.message||'기록을 읽지 못했습니다. 새로고침해 다시 시도해주세요.');
    }finally{if(epoch===this.epoch){this.busy=false;this.controls();}}
  }
  async edge(direction,reveal=false){
    if(this.busy||!this.info||this.selectedText()&&!reveal)return;
    const page=direction<0?this.pages[0].page-1:this.pages.at(-1).page+1;
    if(page<0||page>=this.info.pageCount)return;
    await this.read(page,{edge:direction,reveal});
  }
};

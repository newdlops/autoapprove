'use strict';
// Cold, read-only history. At most three small pages are present in the DOM.
window.AutoApproveTerminalHistory=class {
  constructor({api,endpoint}) {
    this.api=api;this.endpoint=endpoint;this.epoch=0;this.pages=[];this.busy=false;
    this.dialog=document.getElementById('terminal-history-dialog');
    this.output=document.getElementById('terminal-history-output');
    this.el=id=>document.getElementById('terminal-history-'+id);
    this.el('close').onclick=()=>this.dialog.close();
    this.el('first').onclick=()=>void this.read(0);
    this.el('last').onclick=()=>void this.read(this.info.pageCount-1);
    this.el('previous').onclick=()=>void this.edge(-1,true);
    this.el('next').onclick=()=>void this.edge(1,true);
    this.el('older').onclick=()=>void this.readConversation(true);
    this.el('conversation').onchange=()=>{this.el('use').disabled=!this.el('conversation').value||this.busy;};
    this.el('use').onclick=()=>{this.threadID=this.el('conversation').value;void this.readConversation();};
    this.el('refresh').onclick=()=>void (this.conversation?this.readConversation():this.read(null,{refresh:true}));
    this.dialog.addEventListener('close',()=>{++this.epoch;this.controller?.abort();this.busy=false;this.pages=[];this.output.replaceChildren();this.info=null;this.item=null;});
    this.output.addEventListener('scroll',()=>{
      if(this.conversation||this.busy||!this.info||this.selectedText())return;
      if(this.output.scrollTop<64&&this.pages[0]?.page>0)void this.edge(-1);
      else if(this.output.scrollHeight-this.output.clientHeight-this.output.scrollTop<64&&this.pages.at(-1)?.page<this.info.pageCount-1)void this.edge(1);
    },{passive:true});
  }
  selectedText() {const selection=window.getSelection();return selection&&!selection.isCollapsed&&(this.output.contains(selection.anchorNode)||this.output.contains(selection.focusNode));}
  async open(item,{conversation=false}={}) {
    ++this.epoch;this.controller?.abort();this.item={node:item.node.id,session:item.session.id};this.pages=[];this.info=null;this.busy=false;
    this.el('source').textContent=item.view?.title||item.title||item.session.displayName||item.session.cwd||item.session.agent;
    this.conversation=conversation;this.threadID=null;this.cursors=new Set();
    this.el('title').textContent=conversation?'Codex 대화 기록':'터미널 전체 기록';
    this.el('help').textContent=conversation?'Codex에 저장된 사용자 메시지와 답변을 읽기 전용으로 봅니다. 원본 터미널의 스크롤 위치와 관계없이 표시합니다. 도구 실행 출력은 포함하지 않습니다.':'Mac의 Terminal이 보관한 출력을 읽기 전용으로 봅니다. 위아래로 스크롤하면 앞뒤 기록을 불러옵니다. 원본에서 삭제된 기록은 포함되지 않습니다.';
    this.output.classList.toggle('conversation-output',conversation);this.output.setAttribute('aria-label',conversation?'읽기 전용 Codex 대화 기록':'읽기 전용 전체 터미널 기록');
    this.el('picker').hidden=true;this.el('conversation').replaceChildren(new Option('대화를 선택해주세요.',''));
    for(const name of ['first','previous','next','last'])this.el(name).hidden=conversation;
    this.el('older').hidden=!conversation;
    this.el('refresh').textContent=conversation?'최신 기록':'새로고침';
    this.output.replaceChildren();this.error('');this.controls();
    if(!this.dialog.open)this.dialog.showModal();this.el('close').focus();
    if(conversation)await this.readConversation();else await this.read(null);
  }
  close(){if(this.dialog.open)this.dialog.close();}
  error(message){this.el('error').hidden=!message;this.el('error').textContent=message;}
  controls(){
    if(this.conversation){
      this.el('refresh').disabled=this.busy;this.el('older').disabled=this.busy||!this.info?.nextCursor;
      this.el('use').disabled=this.busy||!this.el('conversation').value;this.el('conversation').disabled=this.busy;
      this.output.setAttribute('aria-busy',String(this.busy));
      const count=this.pages.reduce((total,page)=>total+page.count,0);
      this.el('range').textContent=count?`${new Intl.NumberFormat('ko-KR').format(count)}개 메시지 표시`:'';
      this.el('status').textContent=this.busy?'Codex 대화 기록을 불러오는 중…':this.info?this.info.nextCursor?'이전 대화를 더 불러올 수 있습니다.':'저장된 대화의 처음입니다.':'';
      return;
    }
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
  async readConversation(older=false){
    if(this.busy||!this.item||!this.dialog.open||older&&!this.info?.nextCursor)return;
    const epoch=this.epoch,item=this.item,thread=this.threadID,cursor=older?this.info.nextCursor:null;
    this.busy=true;this.error('');this.controls();this.controller=new AbortController();
    const query=new URLSearchParams({session:item.session});
    if(thread)query.set('thread',thread);if(cursor)query.set('cursor',cursor);
    try{
      const value=await this.api(this.endpoint('/api/codex/history?'+query,item.node),undefined,this.controller.signal,20000);
      if(epoch!==this.epoch||!this.dialog.open||this.item!==item)return;
      if(!value||value.sessionID!==item.session||typeof value.threadID!=='string'||!/^[0-9a-f-]{36}$/i.test(value.threadID)||thread&&value.threadID!==thread||
         !Array.isArray(value.messages)||value.messages.length>32||value.nextCursor!=null&&(typeof value.nextCursor!=='string'||!value.nextCursor||value.nextCursor.length>8192)||
         value.messages.some(message=>!message||typeof message.id!=='string'||!['user','assistant'].includes(message.role)||typeof message.text!=='string'||message.text.length>262144||typeof message.truncated!=='boolean'))throw Error('Codex 대화 기록의 형식을 확인하지 못했습니다.');
      if(cursor&&(value.nextCursor===cursor||value.nextCursor&&this.cursors.has(value.nextCursor)))throw Error('기록 조회 위치가 반복됐습니다. 최신 기록을 다시 불러와주세요.');
      const page=document.createElement('div');page.className='conversation-page';
      const existing=new Set(older?this.pages.flatMap(page=>page.ids):[]),ids=[];
      for(const message of value.messages){
        if(existing.has(message.id))continue;existing.add(message.id);ids.push(message.id);
        const article=document.createElement('article');article.className='conversation-message';article.dataset.role=message.role;
        const author=document.createElement('strong');author.textContent=message.role==='user'?'사용자':message.phase==='commentary'?'Codex · 진행':'Codex · 답변';
        const body=document.createElement('div');body.className='conversation-text';body.textContent=message.text||'(텍스트 없는 메시지)';article.append(author,body);
        if(message.truncated){const note=document.createElement('p');note.className='muted small';note.textContent='긴 메시지의 앞부분만 표시합니다. 전체 내용은 Codex에서 확인해주세요.';article.append(note);}
        page.append(article);
      }
      if(!ids.length){const empty=document.createElement('p');empty.className='muted';empty.textContent=value.nextCursor?'이 구간에는 사용자 메시지나 답변이 없습니다. 이전 대화를 더 불러와주세요.':'저장된 사용자 메시지와 답변이 없습니다.';page.append(empty);}
      const entry={node:page,count:ids.length,ids};
      if(older){this.pages.unshift(entry);this.output.prepend(page);if(this.pages.length>3)this.pages.pop().node.remove();this.output.scrollTop=0;}
      else{this.pages=[entry];this.output.replaceChildren(page);this.output.scrollTop=this.output.scrollHeight;this.cursors.clear();}
      this.threadID=value.threadID;this.info=value;if(value.nextCursor)this.cursors.add(value.nextCursor);
      this.el('picker').hidden=true;
    }catch(error){
      if(epoch===this.epoch&&this.dialog.open&&error.name!=='AbortError'){
        this.error(error.message||'Codex 대화 기록을 읽지 못했습니다.');
        if(!this.info&&!thread)await this.chooseConversation(epoch,item);
      }
    }finally{if(epoch===this.epoch){this.busy=false;this.controls();}}
  }
  async chooseConversation(epoch,item){
    try{
      const value=await this.api(this.endpoint('/api/codex/conversations?'+new URLSearchParams({session:item.session}),item.node),undefined,this.controller.signal,12000);
      if(epoch!==this.epoch||this.item!==item||!this.dialog.open)return;
      if(value?.sessionID!==item.session||!Array.isArray(value.items)||value.items.length>1000)return;
      const select=this.el('conversation');select.replaceChildren(new Option('대화를 선택해주세요.',''));
      for(const row of value.items)if(typeof row.id==='string'&&/^[0-9a-f-]{36}$/i.test(row.id)&&typeof row.title==='string')select.add(new Option(row.title.slice(0,180),row.id));
      this.el('picker').hidden=select.options.length<2;
    }catch{}
  }
  async edge(direction,reveal=false){
    if(this.busy||!this.info||this.selectedText()&&!reveal)return;
    const page=direction<0?this.pages[0].page-1:this.pages.at(-1).page+1;
    if(page<0||page>=this.info.pageCount)return;
    await this.read(page,{edge:direction,reveal});
  }
};

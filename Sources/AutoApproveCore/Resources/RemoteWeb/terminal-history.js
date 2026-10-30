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
    this.el('jump').onchange=()=>{const message=this.messages?.[Number(this.el('jump').value)];if(message){this.scrollToMessage(message);this.position();}};
    this.el('jump').onblur=()=>this.schedulePosition();
    this.el('seek').oninput=()=>{this.output.scrollTop=Number(this.el('seek').value);this.schedulePosition();};
    this.el('conversation').onchange=()=>{this.el('use').disabled=!this.el('conversation').value||this.busy;};
    this.el('use').onclick=()=>{this.threadID=this.el('conversation').value;void this.readConversation();};
    this.el('refresh').onclick=()=>void (this.conversation?this.readConversation():this.read(null,{refresh:true}));
    this.dialog.addEventListener('close',()=>{++this.epoch;this.controller?.abort();cancelAnimationFrame(this.positionFrame);this.busy=false;this.pages=[];this.messages=[];this.boundaries?.clear();this.output.replaceChildren();this.el('jump').replaceChildren();this.info=null;this.item=null;});
    this.output.addEventListener('scroll',()=>{
      if(this.conversation){this.schedulePosition();if(Date.now()-this.gestureAt<300)this.conversationGesture(this.gestureDirection,false);return;}
      if(this.busy||!this.info||this.selectedText())return;
      if(this.output.scrollTop<64&&this.pages[0]?.page>0)void this.edge(-1);
      else if(this.output.scrollHeight-this.output.clientHeight-this.output.scrollTop<64&&this.pages.at(-1)?.page<this.info.pageCount-1)void this.edge(1);
    },{passive:true});
    // A real scroll gesture, rather than a DOM insertion, loads one adjacent page.
    this.output.addEventListener('wheel',event=>{if(!event.ctrlKey)this.conversationGesture(event.deltaY);},{passive:true});
    this.output.addEventListener('touchstart',event=>{this.touchY=event.touches[0]?.clientY;},{passive:true});
    this.output.addEventListener('touchmove',event=>{const y=event.touches[0]?.clientY;if(y!=null&&this.touchY!=null)this.conversationGesture(this.touchY-y);this.touchY=y;},{passive:true});
    this.output.addEventListener('keydown',event=>{if(['ArrowUp','PageUp','Home'].includes(event.key))this.conversationGesture(-1);else if(['ArrowDown','PageDown','End',' '].includes(event.key))this.conversationGesture(1);});
    this.resizeObserver=new ResizeObserver(()=>this.schedulePosition());this.resizeObserver.observe(this.output);
  }
  selectedText() {const selection=window.getSelection();return selection&&!selection.isCollapsed&&(this.output.contains(selection.anchorNode)||this.output.contains(selection.focusNode));}
  schedulePosition(){cancelAnimationFrame(this.positionFrame);this.positionFrame=requestAnimationFrame(()=>{if(this.dialog.open&&this.conversation)this.position();});}
  scrollToMessage(message){this.output.scrollTop+=message.getBoundingClientRect().top-this.output.getBoundingClientRect().top-16;}
  position(){
    const count=this.messages.length,top=this.output.getBoundingClientRect().top+24,distance=Math.max(0,this.output.scrollHeight-this.output.clientHeight);
    const fallbackSpace=this.el('older').hidden?0:this.el('older').getBoundingClientRect().height+12;
    const index=Math.max(0,this.messages.findIndex(message=>message.getBoundingClientRect().bottom>top));
    this.el('jump').value=count?String(index):'';
    this.el('position').textContent=count?`${index+1} / ${count}개 메시지`:(this.busy?'불러오는 중…':'표시할 메시지 없음');
    const scroll=Math.max(0,Math.min(distance,this.output.scrollTop)),value=distance?Math.round(scroll/distance*1000):0;
    this.el('seek').max=String(Math.max(1,Math.ceil(distance)));this.el('seek').value=String(Math.round(scroll));
    this.el('seek').disabled=!count||!distance;this.el('seek').setAttribute('aria-valuetext',count?`불러온 ${count}개 중 ${index+1}번째 메시지, 현재 범위 ${Math.round(value/10)}%`:'표시할 메시지 없음');
    const first=this.pages[0],last=this.pages.at(-1);
    this.el('start').textContent=this.busy&&this.loadingDirection==='older'?'이전 대화 불러오는 중…':!first?'이전 대화':first.nextCursor?'위로 스크롤 · 이전 대화':'대화의 처음';
    this.el('end').textContent=this.busy&&this.loadingDirection==='newer'?'이후 대화 불러오는 중…':!last?'최근 대화':last.index===0?'최신 기록':this.boundaries.has(last.index-1)?'아래로 스크롤 · 이후 대화':'최근 구간은 ‘최신으로’';
    this.el('older').hidden=!first?.nextCursor||!(this.failedDirection==='older'||distance<=fallbackSpace+2);
  }
  conversationGesture(direction,fresh=true){
    if(!this.conversation||!this.dialog.open||!direction)return;
    if(fresh){this.gestureID=(this.gestureID||0)+1;this.gestureAt=Date.now();this.gestureDirection=direction;}
    if(this.busy||this.failedDirection||!this.info||this.selectedText()||this.gestureID===this.lastLoadGesture)return;
    const older=direction<0&&this.output.scrollTop<96&&this.pages[0]?.nextCursor;
    const newer=direction>0&&this.output.scrollHeight-this.output.clientHeight-this.output.scrollTop<96&&this.pages.at(-1)?.index>0&&this.boundaries.has(this.pages.at(-1).index-1);
    if(older||newer){this.lastLoadGesture=this.gestureID;void this.readConversation(older?true:'newer');}
  }
  conversationBody(body,text){
    // Render paragraphs and fenced code using text nodes only, with bounded DOM.
    const lines=text.split('\n'),blocks=[];let prose=[];
    const flush=()=>{if(prose.length){blocks.push({text:prose.join('\n')});prose=[];}};
    for(let index=0;index<lines.length;index++){
      const fence=lines[index].match(/^ {0,3}(```|~~~)([a-z0-9_.+-]{0,32})\s*$/i);
      if(fence){let end=index+1;while(end<lines.length&&lines[end].trim()!==fence[1])end++;
        if(end<lines.length){flush();blocks.push({code:true,text:lines.slice(index+1,end).join('\n')});index=end;continue;}
        prose.push(lines.slice(index).join('\n'));break;}
      if(!lines[index].trim()){flush();}else prose.push(lines[index]);
      if(blocks.length>128){body.textContent=text;return;}
    }
    flush();if(blocks.length>128){body.textContent=text;return;}
    for(const block of blocks){const node=document.createElement(block.code?'pre':'p');if(block.code){const code=document.createElement('code');code.textContent=block.text;node.append(code);}else node.textContent=block.text;body.append(node);}
  }
  async open(item,{conversation=false}={}) {
    ++this.epoch;this.controller?.abort();this.item={node:item.node.id,session:item.session.id};this.pages=[];this.info=null;this.busy=false;
    this.el('source').textContent=item.view?.title||item.title||item.session.displayName||item.session.cwd||item.session.agent;
    this.conversation=conversation;this.threadID=null;this.boundaries=new Map();this.messages=[];this.failedDirection=null;
    this.dialog.dataset.conversation=String(conversation);
    this.el('title').textContent=conversation?'Codex 대화 기록':'터미널 전체 기록';
    this.el('close').setAttribute('aria-label',conversation?'대화 기록 닫기':'전체 기록 닫기');
    this.el('help').textContent=conversation?'읽기 전용 대화입니다. 위아래로 스크롤하면 앞뒤 대화를 연결합니다. 읽는 메시지 선택기와 불러온 범위의 위치 막대로 이동할 수 있습니다. 도구 실행 출력은 포함하지 않습니다.':'Mac의 Terminal이 보관한 출력을 읽기 전용으로 봅니다. 위아래로 스크롤하면 앞뒤 기록을 불러옵니다. 원본에서 삭제된 기록은 포함되지 않습니다.';
    this.el('help').className=conversation?'sr-only':'muted small';
    this.el('status').className=conversation?'sr-only':'muted small';
    this.el('location').hidden=!conversation;this.el('wayfinding').hidden=!conversation;this.el('navigation').hidden=conversation;
    this.el('jump').replaceChildren(new Option('대화를 불러오는 중…',''));
    this.output.classList.toggle('conversation-output',conversation);this.output.setAttribute('aria-label',conversation?'읽기 전용 Codex 대화 기록':'읽기 전용 전체 터미널 기록');
    this.el('picker').hidden=true;this.el('conversation').replaceChildren(new Option('대화를 선택해주세요.',''));
    for(const name of ['first','previous','next','last'])this.el(name).hidden=conversation;
    this.el('older').hidden=!conversation;
    this.el('refresh').textContent=conversation?'최신으로':'새로고침';
    this.output.replaceChildren();this.error('');this.controls();
    if(!this.dialog.open)this.dialog.showModal();this.el('close').focus();
    if(conversation)await this.readConversation();else await this.read(null);
  }
  close(){if(this.dialog.open)this.dialog.close();}
  error(message){this.el('error').hidden=!message;this.el('error').textContent=message;}
  controls(){
    if(this.conversation){
      this.el('refresh').disabled=this.busy;this.el('older').disabled=this.busy||!this.pages[0]?.nextCursor;
      this.el('older').textContent=this.failedDirection==='older'?'이전 대화 다시 불러오기':'이전 대화 불러오기';
      this.el('use').disabled=this.busy||!this.el('conversation').value;this.el('conversation').disabled=this.busy;
      this.output.setAttribute('aria-busy',String(this.busy));
      this.el('status').textContent=this.busy?'대화 기록을 불러오는 중…':this.info?'대화 기록을 불러왔습니다. 위아래로 스크롤해 읽을 수 있습니다.':'';
      this.el('jump').disabled=this.busy||!this.messages.length;this.position();
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
  async readConversation(direction=false){
    const older=direction===true,newer=direction==='newer',first=this.pages[0],last=this.pages.at(-1);
    if(this.busy||!this.item||!this.dialog.open||older&&!first?.nextCursor||newer&&(!last?.index||!this.boundaries.has(last.index-1)))return;
    const index=older?first.index+1:newer?last.index-1:0;
    const epoch=this.epoch,item=this.item,thread=this.threadID,cursor=older?first.nextCursor:newer?this.boundaries.get(index).cursor:null;
    this.loadingDirection=older?'older':newer?'newer':'latest';this.failedDirection=null;
    this.busy=true;this.error('');this.controls();this.controller=new AbortController();
    const query=new URLSearchParams({session:item.session});
    if(thread)query.set('thread',thread);if(cursor)query.set('cursor',cursor);
    try{
      const value=await this.api(this.endpoint('/api/codex/history?'+query,item.node),undefined,this.controller.signal,20000);
      if(epoch!==this.epoch||!this.dialog.open||this.item!==item)return;
      if(!value||value.sessionID!==item.session||typeof value.threadID!=='string'||!/^[0-9a-f-]{36}$/i.test(value.threadID)||thread&&value.threadID!==thread||
         !Array.isArray(value.messages)||value.messages.length>32||value.nextCursor!=null&&(typeof value.nextCursor!=='string'||!value.nextCursor||value.nextCursor.length>8192)||
         value.messages.some(message=>!message||typeof message.id!=='string'||!['user','assistant'].includes(message.role)||typeof message.text!=='string'||message.text.length>262144||typeof message.truncated!=='boolean'))throw Error('Codex 대화 기록의 형식을 확인하지 못했습니다.');
      if(cursor&&value.nextCursor===cursor||older&&value.nextCursor&&[...this.boundaries].some(([key,boundary])=>key<=index&&boundary.cursor===value.nextCursor))throw Error('기록 조회 위치가 반복됐습니다. 최신으로에서 다시 불러와주세요.');
      if(newer&&this.boundaries.has(index+1)&&this.boundaries.get(index+1).cursor!==value.nextCursor)throw Error('새 대화로 기록 위치가 바뀌었습니다. 최신으로에서 다시 불러와주세요.');
      const page=document.createElement('div');page.className='conversation-page';
      const existing=new Set(older||newer?this.pages.flatMap(page=>page.ids):[]),ids=[];
      for(const message of value.messages){
        if(existing.has(message.id))continue;existing.add(message.id);ids.push(message.id);
        const article=document.createElement('article');article.className='conversation-message';article.dataset.role=message.role;article.dataset.messageId=message.id;
        const author=document.createElement('strong');author.textContent=message.role==='user'?'사용자':message.phase==='commentary'?'Codex · 진행':'Codex · 답변';
        article.dataset.preview=author.textContent+' · '+(message.text.replace(/\s+/g,' ').trim().slice(0,90)||'텍스트 없는 메시지');
        const body=document.createElement('div');body.className='conversation-text';this.conversationBody(body,message.text||'(텍스트 없는 메시지)');article.append(author,body);
        if(message.truncated){const note=document.createElement('p');note.className='muted small';note.textContent='긴 메시지의 앞부분만 표시합니다. 전체 내용은 Codex에서 확인해주세요.';article.append(note);}
        page.append(article);
      }
      if(!ids.length){const empty=document.createElement('p');empty.className='muted';empty.textContent=value.nextCursor?'이 구간에는 사용자 메시지나 답변이 없습니다. 이전 대화를 더 불러와주세요.':'저장된 사용자 메시지와 답변이 없습니다.';page.append(empty);}
      const entry={node:page,count:ids.length,ids,index,cursor,nextCursor:value.nextCursor};
      const top=this.output.getBoundingClientRect().top,anchor=this.messages.find(message=>message.getBoundingClientRect().bottom>top),before=anchor?.getBoundingClientRect().top;
      this.lastLoadGesture=this.gestureID;
      if(older||newer){
        // If the reader moved into the page that would be evicted while waiting,
        // keep the existing screen; another deliberate gesture can try again.
        const evicted=this.pages.length===3?(older?this.pages.at(-1):this.pages[0]):null;
        if(anchor&&evicted?.node.contains(anchor))return;
        if(older){this.pages.unshift(entry);this.output.prepend(page);if(this.pages.length>3)this.pages.pop().node.remove();}
        else{this.pages.push(entry);this.output.append(page);if(this.pages.length>3)this.pages.shift().node.remove();}
        if(anchor&&before!=null)this.output.scrollTop+=anchor.getBoundingClientRect().top-before;
      }else{this.pages=[entry];this.output.replaceChildren(page);this.boundaries.clear();this.scrollToMessage([...page.querySelectorAll('[data-role="user"]')].at(-1)||page);}
      this.boundaries.set(index,{cursor,nextCursor:value.nextCursor});
      // Keep cursor metadata, never old message bodies, within a bounded window.
      while(this.boundaries.size>128){const farthest=[...this.boundaries.keys()].sort((a,b)=>Math.abs(b-index)-Math.abs(a-index))[0];this.boundaries.delete(farthest);}
      this.messages=[...this.output.querySelectorAll('.conversation-message')];
      this.el('jump').replaceChildren(...this.messages.map((message,index)=>new Option(message.dataset.preview,String(index))));
      if(!this.messages.length)this.el('jump').add(new Option('표시할 메시지가 없습니다.',''));
      this.threadID=value.threadID;this.info=value;
      this.el('picker').hidden=true;
    }catch(error){
      if(epoch===this.epoch&&this.dialog.open&&error.name!=='AbortError'){
        this.failedDirection=this.loadingDirection;this.error(error.message||'Codex 대화 기록을 읽지 못했습니다.');
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

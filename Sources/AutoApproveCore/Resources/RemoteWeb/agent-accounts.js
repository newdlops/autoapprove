'use strict';
// Loaded only after an explicit AI-account action. No credentials in storage,
// page URLs, inventory polling, terminal history or diagnostic output.
window.AutoApproveAgentAccounts=class {
  constructor(options){
    Object.assign(this,options);this.connections=new Map();this.jobs=[];this.states=[];this.busy=[];this.epoch=0;
    this.dialog=document.getElementById('account-dialog');
    this.el=id=>document.getElementById('account-'+id);
    this.el('close').onclick=()=>this.dialog.close();
    this.dialog.addEventListener('close',()=>{++this.epoch;clearTimeout(this.timer);this.el('pin').value='';this.el('code').value='';this.activeJob=null;});
    this.el('unlock').onsubmit=event=>{event.preventDefault();void this.unlock();};
    this.el('submit-code').onsubmit=event=>{event.preventDefault();void this.submit();};
    this.el('refresh').onclick=()=>void this.read(true);
    this.el('copy').onclick=()=>void this.copy();
    for(const button of this.dialog.querySelectorAll('[data-account-agent]'))button.onclick=()=>void this.act(button.dataset.accountAgent,button.dataset.accountAction);
    document.addEventListener('visibilitychange',()=>{clearTimeout(this.timer);if(!document.hidden&&this.dialog.open&&this.connection?.token)void this.read();});
  }
  message(value='',error=false){this.el('message').textContent=value;this.el('message').className=error?'error-text':'muted small';this.el('message').setAttribute('role',error?'alert':'status');}
  text(id,value){const element=this.el(id);if(element.textContent!==value)element.textContent=value;}
  async crypto(){
    if(window.AutoApproveAccountCrypto)return;
    if(!this.cryptoLoading)this.cryptoLoading=new Promise((resolve,reject)=>{
      const script=document.createElement('script');script.src='/vendor/account-crypto.js';
      const timer=setTimeout(()=>{script.remove();this.cryptoLoading=null;reject(Error('로그인 보호 기능을 받지 못했습니다. 창을 다시 열어주세요.'));},8000);
      script.onload=()=>{clearTimeout(timer);resolve();};script.onerror=()=>{clearTimeout(timer);script.remove();this.cryptoLoading=null;reject(Error('로그인 보호 기능을 불러오지 못했습니다. 다시 열어주세요.'));};document.head.append(script);
    });
    await this.cryptoLoading;
  }
  async open(node){
    clearTimeout(this.timer);this.epoch++;this.node=node;this.jobs=[];this.states=[];this.busy=[];this.connection=this.connections.get(node.id);
    this.el('mac').textContent=node.name;this.el('pin').value='';this.el('code').value='';this.message('Mac에 연결하는 중…');
    this.el('unlock').hidden=true;this.el('body').hidden=true;
    if(!this.dialog.open)this.dialog.showModal();this.el('close').focus();
    const epoch=this.epoch;
    try{
      const [hello]=await Promise.all([this.api(this.endpoint('/api/agent-account/key',node.id)),this.crypto()]);
      if(epoch!==this.epoch)return;
      if(hello.version!==1||hello.node!==node.id)throw Error('선택한 Mac을 확인하지 못했습니다. 목록을 새로고침해주세요.');
      if(!hello.pinConfigured){this.connection=null;throw Error('이 Mac의 연결 설정에서 접속 PIN을 먼저 지정하세요. LAN에서도 사용할 수 있으며 Cloudflare 연결은 필요하지 않습니다.');}
      if(!this.connection||this.connection.hello.keyID!==hello.keyID)this.connection={hello,token:null};
      this.connection.hello=hello;this.connection.offset=hello.time-Date.now();this.connections.set(node.id,this.connection);
      if(this.connection.token){this.el('body').hidden=false;await this.read();}
      else{this.el('unlock').hidden=false;this.message('선택한 Mac의 접속 PIN을 입력하세요. 이 창에서 15분 동안 계정을 관리합니다.');this.el('pin').focus();}
    }catch(error){if(epoch===this.epoch)this.message(error.status===404?'이 Mac을 AutoApprove 0.2.196 이상으로 업데이트해주세요.':error.message,true);}
  }
  async request(object){
    const {x25519,hkdf,sha256,chacha20poly1305}=window.AutoApproveAccountCrypto;
    const connection=this.connection,node=this.node.id,hello=connection.hello;
    const random=n=>crypto.getRandomValues(new Uint8Array(n));
    const b64=bytes=>btoa(String.fromCharCode(...bytes)),bytes=value=>Uint8Array.from(atob(value),char=>char.charCodeAt(0));
    const privateKey=random(32),publicKey=x25519.getPublicKey(privateKey),request=crypto.randomUUID?.()||this.uuid();
    const encoder=new TextEncoder(),aad=encoder.encode(`AutoApprove accounts v1:${node}:${hello.keyID}:${request}`);
    const shared=x25519.getSharedSecret(privateKey,bytes(hello.publicKey)),key=hkdf(sha256,shared,new Uint8Array(),aad,32);privateKey.fill(0);shared.fill(0);
    try{
      const plain=encoder.encode(JSON.stringify({...object,token:connection.token,time:Date.now()+connection.offset})),nonce=random(12),encrypted=chacha20poly1305(key,nonce,aad).encrypt(plain);plain.fill(0);
      const payload=new Uint8Array(12+encrypted.length);payload.set(nonce);payload.set(encrypted,12);
      const reply=await this.api(this.endpoint('/api/agent-account',node),{version:1,keyID:hello.keyID,request,publicKey:b64(publicKey),payload:b64(payload)},undefined,20000);
      const sealed=bytes(reply.payload),decoded=chacha20poly1305(key,sealed.slice(0,12),encoder.encode(new TextDecoder().decode(aad)+'.reply')).decrypt(sealed.slice(12));
      let result;try{result=JSON.parse(new TextDecoder().decode(decoded));}finally{decoded.fill(0);}
      if(result.error){const error=Error(result.error);error.status=result.status;throw error;}return result;
    }finally{key.fill(0);}
  }
  async unlock(){
    const button=this.el('unlock-button'),pin=this.el('pin').value;if(button.disabled)return;
    button.disabled=true;button.textContent='확인 중…';this.el('pin').value='';const epoch=this.epoch;
    try{const result=await this.request({action:'unlock',pin});if(epoch!==this.epoch)return;this.connection.token=result.token;this.connection.home=result.home;this.el('unlock').hidden=true;this.el('body').hidden=false;await this.read();}
    catch(error){if(epoch===this.epoch){this.message(error.message,true);this.el('pin').focus();}}
    finally{button.disabled=false;button.textContent='PIN 확인';}
  }
  async read(refresh=false){
    const epoch=this.epoch;clearTimeout(this.timer);if(!this.dialog.open||document.hidden||!this.connection?.token||this.readingEpoch===epoch)return;
    this.readingEpoch=epoch;if(refresh)this.el('refresh').disabled=true;
    try{
      const value=await this.request({action:'status',refresh});if(epoch!==this.epoch)return;
      this.states=value.states;this.jobs=value.jobs;this.busy=value.busy;this.message();this.render();
    }catch(error){if(epoch===this.epoch){this.message(error.message+' 연결이 돌아오면 상태를 다시 확인할 수 있습니다.',true);if(error.status===401){this.connection.token=null;this.el('unlock').hidden=false;this.el('body').hidden=true;}}}
    finally{
      if(this.readingEpoch===epoch)this.readingEpoch=null;if(epoch===this.epoch)this.el('refresh').disabled=false;
      if(epoch===this.epoch&&this.dialog.open&&this.connection?.token&&this.jobs.some(job=>['starting','waiting','verifying'].includes(job.phase)))this.timer=setTimeout(()=>void this.read(),1200);
    }
  }
  render(){
    const labels={authenticated:'로그인됨',signedOut:'로그인 필요',missing:'설치되지 않음',unknown:'상태 확인 필요'};
    const anyActive=this.jobs.some(job=>['starting','waiting','verifying'].includes(job.phase));
    const phases={starting:'인증 링크 준비 중…',waiting:'현재 기기에서 인증을 기다립니다.',verifying:'Mac에서 로그인 확인 중…',succeeded:'이 Mac에서 로그인했습니다.',cancelled:'로그인을 취소했습니다.',expired:'인증 시간이 만료됐습니다.',failed:'로그인을 완료하지 못했습니다.',uncertain:'코드 전달 결과 확인 필요'};
    for(const agent of ['codex','claude']){
      const state=this.states.find(item=>item.agent===agent),job=this.jobs.filter(item=>item.agent===agent).at(-1),active=job&&['starting','waiting','verifying'].includes(job.phase),other=this.busy.includes(agent);
      const status=this.el(agent+'-status');this.text(agent+'-status',active?phases[job.phase]:other?'다른 창에서 로그인 중':(labels[state?.phase]||'확인 중…')+(state?.method?.startsWith('api_key')?' · API 설정 사용 중':''));status.className='small '+(state?.phase==='authenticated'?'online':'muted');
      const login=this.el(agent+'-login'),launch=this.el(agent+'-launch'),cancel=this.el(agent+'-cancel');
      login.hidden=state?.phase==='authenticated'||active||other;login.disabled=!state||state.phase==='missing'||anyActive;
      launch.hidden=state?.phase!=='authenticated'||active||other;cancel.hidden=!active&&!other;
      const detail=this.el(agent+'-detail');detail.textContent=job&&!active?(job.message||phases[job.phase]||''):state?.phase==='missing'?`먼저 대상 Mac에 ${agent==='codex'?'Codex':'Claude Code'} CLI를 설치하세요.`:'';detail.hidden=!detail.textContent;
    }
    const active=this.jobs.find(job=>['starting','waiting','verifying'].includes(job.phase));
    if(active?.id!==this.activeJob?.id||active?.phase!=='waiting'||active?.submitted)this.el('code').value='';
    this.activeJob=active;this.el('challenge').hidden=!active;
    this.el('submit-code').hidden=!(active?.agent==='claude'&&active.phase==='waiting'&&!active.submitted);
    this.el('device').hidden=!(active?.agent==='codex'&&active.code);
    this.text('device-code',active?.code||'');
    const link=this.el('link');link.hidden=!active?.url||active.agent==='codex'&&!active.code;if(active?.url)link.href=active.url;else link.removeAttribute('href');
    this.text('instructions',active?.agent==='codex'?'인증 코드를 복사하고 공식 페이지에서 입력하세요. 완료하면 이 화면이 자동으로 바뀝니다.':'공식 페이지에서 승인한 뒤 표시된 일회용 코드를 아래에 붙여넣으세요.');
    this.text('challenge-title',active?(active.agent==='codex'?'Codex':'Claude Code')+' 로그인':'');
    this.text('progress',active?phases[active.phase]+` · 남은 시간 ${Math.ceil(active.remaining/60)}분`:'');
  }
  async act(agent,action){
    const epoch=this.epoch;if(this.actingEpoch===epoch)return;this.actingEpoch=epoch;
    const buttons=[...this.dialog.querySelectorAll('[data-account-agent]')];buttons.forEach(button=>button.disabled=true);
    try{
      if(action==='launch'){await this.launch(this.node.id,agent,this.connection.home);if(epoch===this.epoch)this.dialog.close();return;}
      if(action==='begin'){
        // Keep the chosen attempt ID when a POST result is lost; status owns
        // recovery. Never synthesize another login or code submission.
        const job=await this.request({action:'begin',agent,id:this.uuid()});if(epoch!==this.epoch)return;
        this.jobs=this.jobs.filter(item=>item.agent!==agent);this.jobs.push(job);this.message();this.render();
      }else if(action==='cancel'){await this.request({action:'cancel',agent});if(epoch!==this.epoch)return;}
      await this.read();
    }catch(error){if(epoch===this.epoch){this.message(error.message,true);if(action==='begin')this.timer=setTimeout(()=>void this.read(),1200);}}
    finally{if(this.actingEpoch===epoch)this.actingEpoch=null;if(epoch===this.epoch){buttons.forEach(button=>button.disabled=false);this.render();}}
  }
  async submit(){
    const job=this.activeJob,button=this.el('code-button');if(!job||button.disabled)return;
    const code=this.el('code').value;this.el('code').value='';button.disabled=true;const epoch=this.epoch;
    try{const result=await this.request({action:'submit',id:job.id,code});if(epoch!==this.epoch)return;Object.assign(job,result);this.render();}
    catch(error){if(epoch===this.epoch)this.message(error.message+' 제출 결과는 상태 확인으로 확인하세요.',true);}
    finally{button.disabled=false;if(epoch===this.epoch)await this.read();}
  }
  async copy(){
    const value=this.el('device-code').textContent;
    try{if(navigator.clipboard?.writeText)await navigator.clipboard.writeText(value);else{const field=document.createElement('textarea');field.value=value;field.setAttribute('readonly','');this.dialog.append(field);field.select();const copied=document.execCommand('copy');field.remove();if(!copied)throw Error();}this.message('인증 코드를 복사했습니다. 공식 인증 페이지에서 붙여넣으세요.');}
    catch{this.message('표시된 인증 코드를 선택해 복사해주세요.');}
  }
};

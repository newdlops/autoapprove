'use strict';
const form=document.getElementById('tunnel-login-form'),key=document.getElementById('tunnel-key');
const button=document.getElementById('tunnel-login-submit'),message=document.getElementById('tunnel-login-error');
const pinEnabled=document.documentElement.dataset.pin==='true';
if(pinEnabled){
  document.getElementById('tunnel-key-label').textContent='접속 PIN';
  document.getElementById('tunnel-login-help').textContent='Mac의 AutoApprove에서 직접 지정한 숫자 PIN을 입력하세요. 긴 접속 키는 붙이지 않아도 됩니다.';
  key.setAttribute('inputmode','numeric');key.setAttribute('autocomplete','current-password');key.setAttribute('minlength','6');key.setAttribute('maxlength','12');key.setAttribute('pattern','[0-9]{6,12}');
}
// Fragment credentials never enter a request URL, referrer or browser storage.
let destination='/'+location.search;
let busy=false;
async function login(){
  if(busy||!key.value.trim())return;
  busy=true;button.disabled=true;form.setAttribute('aria-busy','true');button.textContent='연결 중…';message.hidden=true;key.removeAttribute('aria-invalid');
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000);
  try{
    const response=await fetch('/auth/login',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:key.value.trim()}),signal:controller.signal});
    const value=await response.json().catch(error=>{
      if(!response.ok)return {error:'Mac과 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해주세요.'};throw error;
    });
    if(!response.ok||value.authenticated!==true)throw Error(value.error||(pinEnabled?'접속하지 못했습니다. PIN을 확인해주세요.':'접속하지 못했습니다. 키를 확인해주세요.'));
    key.value='';location.replace(destination);
  }catch(error){message.textContent=error.name==='AbortError'?'연결 확인 시간이 초과됐습니다. 다시 시도해주세요.':error.message;message.hidden=false;key.setAttribute('aria-invalid','true');key.focus();key.select();}
  finally{clearTimeout(timeout);busy=false;button.disabled=false;button.textContent='Mac에 연결';form.setAttribute('aria-busy','false');}
}
form.addEventListener('submit',event=>{event.preventDefault();void login();});
function readSharedKey(){
  const fragment=new URLSearchParams(location.hash.slice(1)),sharedKey=fragment.get('access');fragment.delete('access');
  destination='/'+location.search+(fragment.size?'#'+fragment.toString():'');
  history.replaceState(null,'',location.pathname+location.search+(fragment.size?'#'+fragment.toString():''));
  if(sharedKey){key.value=sharedKey;void login();}else if(matchMedia('(pointer: fine)').matches)key.focus();
}
window.addEventListener('hashchange',readSharedKey);readSharedKey();

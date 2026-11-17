import SwiftUI
import WebKit
import AVFoundation
import Photos

// MARK: - Early JS (document start): only dark-mode + ad-hide CSS, so first paint is already right
private let nsEarlyJS = """
(function(){
  try{
    var d='0'; try{ d=localStorage.getItem('ns_dark')||'0'; }catch(e){}
    if(d==='1'){
      var el=document.createElement('style'); el.id='ns-dark-style';
      el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
      document.documentElement.appendChild(el);
    }
    var h='1'; try{ h=localStorage.getItem('ns_hideAds')||'1'; }catch(e){}
    if(h==='1'){
      var st=document.createElement('style'); st.id='ns-ad-style';
      st.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
      document.documentElement.appendChild(st);
    }
  }catch(e){}
})();
"""

// MARK: - Main JS (document end, main frame only)
// Safe features only: auto sign-in, dark mode, hide ads, keyword filter/highlight,
// read markers, user notes/blacklist, infinite scroll, only-OP, fold, preview,
// code copy/highlight, reputation badges, translation, search, trade/lottery.
// Read-only or user-triggered only. No auto-reply, no auto-comment, no auto lottery entry.
private let nsJS = """
(function(){
  function store(k,v){ try{ localStorage.setItem('ns_'+k, v); }catch(e){} }
  function read(k,d){ try{ var v=localStorage.getItem('ns_'+k); return v===null?d:v; }catch(e){ return d; } }
  function readJSON(k,d){ try{ var v=JSON.parse(read(k,'')); return (v===null||v===undefined)?d:v; }catch(e){ return d; } }
  function trimList(csv){ return csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; }); }

  function showToast(msg){
    var t=document.createElement('div');
    t.textContent=msg;
    t.style.cssText='position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,0.82);color:#fff;padding:10px 16px;border-radius:20px;font-size:14px;z-index:999999;pointer-events:none;';
    document.body.appendChild(t);
    setTimeout(function(){ t.remove(); }, 2600);
  }
  window.__nsToast = showToast;

  // Bridge to Swift (async results: trade/lottery fetch)
  function nsBridgePost(kind, payload){ try{ window.webkit.messageHandlers.nsBridge.postMessage({kind:kind, data:payload}); }catch(e){} }

  // ---------- 1. Auto sign-in (once per day; skip while the Cloudflare challenge is showing) ----------
  (function autoSignIn(){
    if (document.title.indexOf('Just a moment') !== -1) return;
    var today = new Date().toISOString().slice(0,10);
    if (read('signDate','') === today) return;
    fetch('/api/attendance?random=true', {method:'POST', credentials:'include',
      headers:{'Content-Type':'application/json'}, body:'{}'})
      .then(function(r){ store('signDate', today); return r.text(); })
      .then(function(t){
        try{ var j=JSON.parse(t); if(j && j.message){ showToast(j.message); } }catch(e){}
      })
      .catch(function(){});
  })();

  // ---------- 2. Dark mode (toggle; the early script already painted the CSS) ----------
  window.__nsSetDark = function(on){
    store('dark', on?'1':'0');
    var id='ns-dark-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('dark','0')==='1') { window.__nsSetDark(true); }

  // ---------- 3. Hide ads / promo blocks ----------
  window.__nsSetHideAds = function(on){
    store('hideAds', on?'1':'0');
    var id='ns-ad-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('hideAds','1')==='1') { window.__nsSetHideAds(true); }

  // ---------- Shared helpers: post links, rows, authors ----------
  function postLinks(){ return Array.prototype.slice.call(document.querySelectorAll('a[href*="/post-"], a[href*="/post/"]')); }
  function rowOf(a){ return a.closest ? a.closest('li, article, div') : null; }
  function postIdOf(a){ var h=a.getAttribute('href')||''; var m=h.match(/post-([0-9]+)/); return m?m[1]:''; }
  function authorOf(el){
    if(!el || !el.querySelector) return '';
    var a=el.querySelector('a[href*="/member/"], a[href*="/user/"]');
    return a ? (a.textContent||'').trim() : '';
  }
  function isPostPage(){ return location.pathname.indexOf('/post-')!==-1; }

  // ---------- 4. List page: keyword filter + read marks + highlight + blacklist + user notes ----------
  function readSet(){ var v=readJSON('read', []); return Array.isArray(v)?v:[]; }
  function applyNoteToAuthorLink(a, au, notes){
    if(!a || !a.parentElement) return;
    var ex=a.parentElement.querySelector('.ns-usernote');
    if(au && notes[au]){
      if(ex){ ex.textContent='（'+notes[au]+'）'; }
      else{
        var s=document.createElement('span'); s.className='ns-usernote';
        s.style.cssText='font-size:11px;color:#b45309;margin-left:4px;';
        s.textContent='（'+notes[au]+'）';
        a.parentElement.insertBefore(s, a.nextSibling);
      }
    } else if(ex){ ex.remove(); }
  }
  function applyListPage(){
    var kws=trimList(read('keywords',''));
    var hl=trimList(read('hlKeywords',''));
    var bl=trimList(read('blacklist',''));
    var notes=readJSON('userNotes', {});
    var readIds=readSet();
    postLinks().forEach(function(a){
      var row=rowOf(a); if(!row) return;
      var title=a.textContent||'';
      var au=authorOf(row);
      var hitFilter=kws.some(function(k){ return title.indexOf(k)!==-1; });
      var hitBL=au && bl.indexOf(au)!==-1;
      row.style.display=(hitFilter||hitBL)?'none':'';
      if(row.style.display==='none') return;
      var id=postIdOf(a);
      row.style.opacity=(id && readIds.indexOf(id)!==-1)?'0.45':'';
      var hitHL=hl.some(function(k){ return title.indexOf(k)!==-1; });
      a.style.background=hitHL?'#ffe58f':'';
      a.style.borderRadius=hitHL?'4px':'';
      var al=row.querySelector ? row.querySelector('a[href*="/member/"], a[href*="/user/"]') : null;
      if(al) applyNoteToAuthorLink(al, authorOf(row), notes);
    });
  }
  window.__nsSetKeywords = function(csv){ store('keywords', csv||''); applyListPage(); };
  window.__nsApplyKeywords = applyListPage;
  window.__nsSetHLKeywords = function(csv){ store('hlKeywords', csv||''); applyListPage(); };
  window.__nsSetBlacklist = function(csv){ store('blacklist', csv||''); applyListPage(); applyPostNotes(); };
  window.__nsSetUserNotes = function(json){ store('userNotes', json||'{}'); applyListPage(); applyPostNotes(); };
  window.__nsClearRead = function(){ store('read', '[]'); applyListPage(); showToast('已读记录已清空'); };

  // Record a post as read when its link is tapped; record lottery posts the user opens
  document.addEventListener('click', function(e){
    var a=e.target.closest ? e.target.closest('a[href*="/post-"]') : null;
    if(!a) return;
    var id=postIdOf(a);
    if(id){
      var s=readSet();
      if(s.indexOf(id)===-1){ s.push(id); if(s.length>500) s=s.slice(-500); store('read', JSON.stringify(s)); }
    }
    var t=(a.textContent||'');
    if(t.indexOf('抽奖')!==-1){
      var list=readJSON('myLotteries', []);
      if(!list.some(function(x){ return x.href===a.href; })){
        list.unshift({title:t.trim(), href:a.href, at:Date.now()});
        if(list.length>10) list=list.slice(0,10);
        store('myLotteries', JSON.stringify(list));
      }
    }
  }, true);

  // ---------- 5. Fullscreen image viewer ----------
  document.addEventListener('click', function(e){
    var img = e.target.closest ? e.target.closest('img') : null;
    if(!img || !img.src) return;
    if(img.closest('a')) return;
    var ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.92);z-index:999999;display:flex;align-items:center;justify-content:center;';
    var im=document.createElement('img');
    im.src=img.src; im.style.cssText='max-width:96vw;max-height:92vh;object-fit:contain;';
    ov.appendChild(im);
    ov.addEventListener('click', function(){ ov.remove(); });
    document.body.appendChild(ov);
  }, true);

  // ---------- 6. Remember scroll position (per URL) ----------
  var saveTimer=null;
  function savePos(){
    try{ sessionStorage.setItem('ns_pos_'+location.pathname, String(window.scrollY)); }catch(e){}
  }
  window.addEventListener('scroll', function(){
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(savePos, 400);
  }, {passive:true});
  window.addEventListener('pagehide', savePos);
  (function restorePos(){
    try{
      var y=parseInt(sessionStorage.getItem('ns_pos_'+location.pathname)||'0',10);
      if(y>200){ setTimeout(function(){ window.scrollTo(0,y); }, 350); }
    }catch(e){}
  })();

  // ---------- 7. Section navigation ----------
  window.__nsGoSection = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      return t===name && a.getAttribute('href') && a.getAttribute('href').indexOf('/')===0;
    });
    if(hit){ hit.click(); return true; }
    return false;
  };
  window.__nsFindSectionHref = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      return t===name && a.getAttribute('href') && a.getAttribute('href').indexOf('/')===0;
    });
    return hit ? hit.href : '';
  };

  // ---------- 8. Back to top ----------
  window.__nsTop = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // ---------- 9. Infinite scroll (list pages only; next-page link -> fetch -> append) ----------
  var nsNextUrl='', nsLoadingMore=false, nsNoMore=false;
  function findNextUrl(doc){
    var links=Array.prototype.slice.call((doc||document).querySelectorAll('a'));
    var hit=links.find(function(a){ return a.getAttribute('rel')==='next'; });
    if(hit) return hit.href;
    hit=links.find(function(a){
      var t=(a.textContent||'').trim();
      return t==='下一页' || t==='>' || t==='»' || t==='›' || t==='下一頁';
    });
    return hit ? hit.href : '';
  }
  function setupInfiniteScroll(){
    if(isPostPage()) return;
    nsNextUrl=findNextUrl(document);
    if(!nsNextUrl) return;
    var rows=postLinks(); if(!rows.length) return;
    var container=rows[0].parentElement; if(!container) return;
    var sentinel=document.createElement('div');
    sentinel.id='ns-more-sentinel';
    sentinel.textContent='下拉加载更多…';
    sentinel.style.cssText='text-align:center;color:#888;padding:16px 0;font-size:14px;';
    container.appendChild(sentinel);
    var obs=new IntersectionObserver(function(entries){
      if(!entries[0].isIntersecting) return;
      if(nsLoadingMore || nsNoMore || !nsNextUrl) return;
      nsLoadingMore=true;
      sentinel.textContent='加载中…';
      fetch(nsNextUrl, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
        var doc=new DOMParser().parseFromString(html, 'text/html');
        var newLinks=Array.prototype.slice.call(doc.querySelectorAll('a[href*="/post-"], a[href*="/post/"]'));
        var added=0;
        newLinks.forEach(function(a){
          var row=a.closest ? a.closest('li, article, div') : null;
          if(!row) return;
          container.insertBefore(document.importNode(row, true), sentinel);
          added++;
        });
        nsNextUrl=findNextUrl(doc);
        if(!nsNextUrl || added===0){ nsNoMore=true; sentinel.textContent='没有更多了'; }
        else sentinel.textContent='下拉加载更多…';
        applyListPage();
        nsLoadingMore=false;
      }).catch(function(){ nsLoadingMore=false; sentinel.textContent='加载失败，下拉重试'; });
    }, {rootMargin:'800px'});
    obs.observe(sentinel);
  }

  // ---------- 10. Post blocks (best-effort; every consumer checks overlap first) ----------
  function nsPostBlocks(){
    var authors=Array.prototype.slice.call(document.querySelectorAll('a[href*="/member/"], a[href*="/user/"]'));
    var blocks=[];
    var bodyText=(document.body.innerText||'').length;
    authors.forEach(function(a){
      var b=a.closest ? a.closest('article, li') : null;
      if(!b){
        b=a.closest ? a.closest('div') : null;
        var guard=0;
        while(b && ((b.innerText||'').length<120) && b.parentElement && guard<5){ b=b.parentElement; guard++; }
      }
      if(!b) return;
      var len=(b.innerText||'').length;
      if(len<120 || len>bodyText*0.8) return;
      if(blocks.indexOf(b)===-1) blocks.push(b);
    });
    return blocks;
  }
  function nsBlocksNonOverlapping(blocks){
    for(var i=0;i<blocks.length;i++) for(var j=0;j<blocks.length;j++){
      if(i!==j && blocks[i].contains(blocks[j])) return false;
    }
    return true;
  }

  // ---------- 11a. Only OP ----------
  function applyOnlyOP(allowToast){
    if(!isPostPage()) return;
    if(read('onlyOP','0')!=='1'){ nsPostBlocks().forEach(function(b){ b.style.display=''; }); return; }
    var blocks=nsPostBlocks();
    if(blocks.length<2 || !nsBlocksNonOverlapping(blocks)){
      store('onlyOP','0');
      if(allowToast) showToast('当前页面结构不支持只看楼主');
      return;
    }
    var op=authorOf(blocks[0]);
    if(!op) return;
    blocks.forEach(function(b, idx){
      if(idx===0) return;
      b.style.display=(authorOf(b)===op)?'':'none';
    });
  }
  window.__nsSetOnlyOP=function(on){ store('onlyOP', on?'1':'0'); applyOnlyOP(true); };

  // ---------- 11b. Fold long posts ----------
  function applyFold(){
    if(!isPostPage()) return;
    var blocks=nsPostBlocks();
    if(!nsBlocksNonOverlapping(blocks)) return;
    blocks.forEach(function(b){
      if(b.dataset.nsFolded) return;
      var len=(b.innerText||'').length;
      if(len>1200){
        b.dataset.nsFolded='1';
        b.style.maxHeight='420px'; b.style.overflow='hidden';
        var btn=document.createElement('button');
        btn.textContent='展开全文';
        btn.style.cssText='display:block;margin:10px auto;padding:6px 18px;border-radius:16px;border:1px solid #ccc;background:#fff;color:#333;font-size:14px;';
        btn.addEventListener('click', function(ev){ ev.stopPropagation(); b.style.maxHeight=''; b.style.overflow=''; btn.remove(); });
        if(b.parentElement) b.parentElement.insertBefore(btn, b.nextSibling);
      }
    });
  }

  // ---------- 11c. Post preview on long-press (list pages) ----------
  var lpTimer=null, lpTarget=null, lpFired=false;
  function showPreview(a){
    var url=a.href;
    var title=(a.textContent||'').trim();
    fetch(url, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
      var doc=new DOMParser().parseFromString(html, 'text/html');
      var txt='';
      var cands=Array.prototype.slice.call(doc.querySelectorAll('article, [class*="post"], [class*="content"]'));
      for(var i=0;i<cands.length;i++){ var t=(cands[i].innerText||'').trim(); if(t.length>80){ txt=t; break; } }
      if(!txt) txt=(doc.body.innerText||'').trim();
      txt=txt.slice(0, 300);
      var old=document.getElementById('ns-preview-card'); if(old) old.remove();
      var card=document.createElement('div');
      card.id='ns-preview-card';
      card.style.cssText='position:fixed;left:12px;right:12px;bottom:110px;z-index:999999;background:#fff;color:#111;border-radius:16px;padding:16px;box-shadow:0 8px 30px rgba(0,0,0,0.35);max-height:45vh;overflow:auto;';
      var h=document.createElement('div'); h.textContent=title; h.style.cssText='font-weight:700;font-size:16px;margin-bottom:8px;';
      var p=document.createElement('p'); p.textContent=txt; p.style.cssText='font-size:14px;line-height:1.6;margin:0 0 12px 0;white-space:pre-wrap;';
      var row=document.createElement('div'); row.style.cssText='display:flex;gap:10px;';
      var openBtn=document.createElement('button'); openBtn.textContent='打开帖子';
      openBtn.style.cssText='flex:1;padding:10px;border-radius:10px;border:none;background:#2563eb;color:#fff;font-size:15px;';
      openBtn.addEventListener('click', function(){ card.remove(); location.href=url; });
      var closeBtn=document.createElement('button'); closeBtn.textContent='关闭';
      closeBtn.style.cssText='flex:1;padding:10px;border-radius:10px;border:1px solid #ccc;background:#fff;font-size:15px;';
      closeBtn.addEventListener('click', function(){ card.remove(); });
      row.appendChild(openBtn); row.appendChild(closeBtn);
      card.appendChild(h); card.appendChild(p); card.appendChild(row);
      document.body.appendChild(card);
    }).catch(function(){ showToast('预览加载失败'); });
  }
  document.addEventListener('touchstart', function(e){
    if(isPostPage()) return;
    var a=e.target.closest ? e.target.closest('a[href*="/post-"]') : null;
    if(!a) return;
    lpTarget=a; lpFired=false;
    lpTimer=setTimeout(function(){ lpFired=true; showPreview(a); }, 550);
  }, {passive:true});
  document.addEventListener('touchend', function(){ if(lpTimer) clearTimeout(lpTimer); }, {passive:true});
  document.addEventListener('touchmove', function(){ if(lpTimer) clearTimeout(lpTimer); }, {passive:true});
  document.addEventListener('click', function(e){
    if(lpFired){ e.preventDefault(); e.stopPropagation(); lpFired=false; }
  }, true);

  // ---------- 12. Code blocks: copy button + basic highlight ----------
  var nsCodeStyleAdded=false;
  function highlightCode(code){
    var esc=code.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;');
    var kwSet={};
    'function return const let var if else for while do class import from export new try catch finally switch case break continue async await throw typeof in of this super extends static get set void delete yield def print elif except pass lambda with as assert global nonlocal raise True False None public private protected struct enum impl fn mut pub use mod match where loop bool int string func package go chan defer interface select range map nil true false float double char long short unsigned signed namespace using template typename virtual override final abstract sealed val fun object when is by lazy data suspend inline reified out vararg crossinline noinline tailrec operator infix internal open companion init constructor delegate dynamic field'.split(' ').forEach(function(w){ kwSet[w]=1; });
    var out=''; var i=0, n=esc.length;
    while(i<n){
      var two=esc.substr(i,2);
      if(two==='//'){
        var eol=esc.indexOf(String.fromCharCode(10), i); if(eol===-1) eol=n;
        out+='<span class="ns-cm">'+esc.slice(i,eol)+'</span>'; i=eol;
      } else if(two==='/*'){
        var end=esc.indexOf('*/', i+2); if(end===-1) end=n-2;
        out+='<span class="ns-cm">'+esc.slice(i,end+2)+'</span>'; i=end+2;
      } else if(esc[i]==='"' || esc[i]==="'"){
        var q=esc[i], j=i+1;
        while(j<n && esc[j]!==q){ if(esc.charCodeAt(j)===92) j++; j++; }
        if(j<n) j++;
        out+='<span class="ns-st">'+esc.slice(i,j)+'</span>'; i=j;
      } else if(/[A-Za-z_]/.test(esc[i])){
        var k=i;
        while(k<n && /[A-Za-z0-9_]/.test(esc[k])) k++;
        var w=esc.slice(i,k);
        out+=kwSet[w]?'<span class="ns-kw">'+w+'</span>':w; i=k;
      } else { out+=esc[i]; i++; }
    }
    return out;
  }
  function fallbackCopy(txt){
    var ta=document.createElement('textarea'); ta.value=txt; ta.style.cssText='position:fixed;opacity:0;';
    document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); }catch(e){}
    ta.remove();
  }
  function applyCodeBlocks(){
    if(!nsCodeStyleAdded){
      nsCodeStyleAdded=true;
      var st=document.createElement('style'); st.id='ns-code-style';
      st.textContent='.ns-kw{color:#d73a49;font-weight:600;} .ns-st{color:#032f62;} .ns-cm{color:#6a737d;font-style:italic;} pre{position:relative;} .ns-copybtn{position:absolute;top:6px;right:6px;padding:3px 10px;font-size:12px;border-radius:10px;border:1px solid #ccc;background:rgba(255,255,255,0.9);color:#333;z-index:5;}';
      document.documentElement.appendChild(st);
    }
    var pres=document.querySelectorAll('pre');
    pres.forEach(function(pre){
      if(pre.dataset.nsCode) return;
      pre.dataset.nsCode='1';
      var codeEl=pre.querySelector('code') || pre;
      var raw=codeEl.innerText || '';
      if(raw.length>20 && raw.length<20000){
        try{ codeEl.innerHTML=highlightCode(raw); }catch(e){}
      }
      var btn=document.createElement('button');
      btn.className='ns-copybtn'; btn.textContent='复制';
      btn.addEventListener('click', function(ev){
        ev.stopPropagation();
        function done(){ btn.textContent='已复制'; setTimeout(function(){ btn.textContent='复制'; }, 1200); }
        if(navigator.clipboard && navigator.clipboard.writeText){ navigator.clipboard.writeText(raw).then(done).catch(function(){ fallbackCopy(raw); done(); }); }
        else { fallbackCopy(raw); done(); }
      });
      pre.appendChild(btn);
    });
  }

  // ---------- 13. Reputation badge (Lv + join days, read from the author block; best-effort) ----------
  function applyRep(){
    if(!isPostPage()) return;
    var blocks=nsPostBlocks();
    if(!nsBlocksNonOverlapping(blocks)) return;
    blocks.forEach(function(b){
      var a=b.querySelector ? b.querySelector('a[href*="/member/"], a[href*="/user/"]') : null;
      if(!a || a.dataset.nsRep) return;
      a.dataset.nsRep='1';
      var txt=(b.innerText||'');
      var lvTxt='';
      var li=txt.indexOf('Lv');
      if(li!==-1){
        var j=li+2;
        while(j<txt.length && (txt[j]===' '||txt[j]==='.')) j++;
        var k=j;
        while(k<txt.length && txt[k]>='0' && txt[k]<='9') k++;
        if(k>j) lvTxt='Lv'+txt.slice(j,k);
      }
      var daysTxt='';
      var ri=txt.indexOf('注册');
      if(ri!==-1){
        var seg=txt.slice(ri, ri+60);
        var di=seg.indexOf('天');
        if(di>0){
          var m=di-1;
          while(m>=0 && seg[m]>='0' && seg[m]<='9') m--;
          if(di-1>m) daysTxt=seg.slice(m+1,di)+'天';
        }
      }
      if(!lvTxt && !daysTxt) return;
      var badge=document.createElement('span');
      badge.style.cssText='font-size:11px;color:#888;margin-left:6px;';
      badge.textContent=(lvTxt||'')+((lvTxt&&daysTxt)?' · ':'')+(daysTxt||'');
      if(a.parentElement) a.parentElement.insertBefore(badge, a.nextSibling);
    });
  }

  // ---------- 14. Post page: user notes + blacklist fold ----------
  function applyPostNotes(){
    if(!isPostPage()) return;
    var notes=readJSON('userNotes', {});
    var bl=trimList(read('blacklist',''));
    var blocks=nsPostBlocks();
    blocks.forEach(function(b){
      var au=authorOf(b);
      if(!au) return;
      var a=b.querySelector ? b.querySelector('a[href*="/member/"], a[href*="/user/"]') : null;
      if(a) applyNoteToAuthorLink(a, au, notes);
      if(bl.indexOf(au)!==-1 && !b.dataset.nsBl){
        b.dataset.nsBl='1';
        var ph=document.createElement('div');
        ph.textContent='已屏蔽用户 '+au+' 的回复（点击展开）';
        ph.style.cssText='padding:10px 14px;margin:8px 0;background:#f3f4f6;color:#666;border-radius:10px;font-size:14px;';
        ph.addEventListener('click', function(){ b.style.display=''; ph.remove(); });
        b.style.display='none';
        if(b.parentElement) b.parentElement.insertBefore(ph, b);
      }
    });
  }

  // ---------- 15. In-page bilingual translation (MyMemory by default; BYOK when configured) ----------
  window.__nsTranslator={provider:'mymemory'};
  window.__nsSetTranslator=function(cfg){ window.__nsTranslator=cfg||{provider:'mymemory'}; };
  function nsDetectLang(text){
    var total=0, cn=0;
    for(var i=0;i<text.length;i++){ var c=text.charCodeAt(i); total++; if(c>=0x4E00 && c<=0x9FA5) cn++; }
    return cn*3>total?'zh':'en';
  }
  function nsMyMemory(text, pair){
    var url='https://api.mymemory.translated.net/get?q='+encodeURIComponent(text)+'&langpair='+pair;
    return fetch(url).then(function(r){ return r.json(); }).then(function(j){ return (j.responseData && j.responseData.translatedText)||''; }).catch(function(){ return ''; });
  }
  function nsTranslateText(text){
    var lang=nsDetectLang(text);
    var pair=lang==='zh'?'zh-CN|en':'en|zh-CN';
    var cfg=window.__nsTranslator||{provider:'mymemory'};
    if(cfg.provider==='byok' && cfg.key){
      var target=lang==='zh'?'English':'Chinese';
      return fetch((cfg.base||'https://openrouter.ai/api/v1')+'/chat/completions', {
        method:'POST',
        headers:{'Content-Type':'application/json','Authorization':'Bearer '+cfg.key},
        body:JSON.stringify({model:cfg.model||'deepseek/deepseek-chat', messages:[{role:'user', content:'Translate the following text to '+target+'. Output only the translation, no explanations:'+String.fromCharCode(10)+String.fromCharCode(10)+text}]})
      }).then(function(r){ return r.json(); })
        .then(function(j){ return (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content)||''; })
        .catch(function(){ return nsMyMemory(text, pair); });
    }
    return nsMyMemory(text, pair);
  }
  function nsShowTransCard(bodyText){
    var old=document.getElementById('ns-trans-card'); if(old) old.remove();
    var card=document.createElement('div');
    card.id='ns-trans-card';
    card.style.cssText='position:fixed;left:12px;right:12px;bottom:110px;z-index:999999;background:#fff;color:#111;border-radius:16px;padding:16px;box-shadow:0 8px 30px rgba(0,0,0,0.35);max-height:45vh;overflow:auto;';
    var h=document.createElement('div'); h.textContent='翻译'; h.style.cssText='font-weight:700;font-size:16px;margin-bottom:8px;';
    var p=document.createElement('p'); p.textContent=bodyText; p.style.cssText='font-size:14px;line-height:1.6;margin:0 0 12px 0;white-space:pre-wrap;';
    var row=document.createElement('div'); row.style.cssText='display:flex;gap:10px;';
    var copyBtn=document.createElement('button'); copyBtn.textContent='复制译文';
    copyBtn.style.cssText='flex:1;padding:10px;border-radius:10px;border:none;background:#2563eb;color:#fff;font-size:15px;';
    copyBtn.addEventListener('click', function(){
      if(navigator.clipboard && navigator.clipboard.writeText){ navigator.clipboard.writeText(bodyText); }
      else fallbackCopy(bodyText);
      showToast('已复制');
    });
    var closeBtn=document.createElement('button'); closeBtn.textContent='关闭';
    closeBtn.style.cssText='flex:1;padding:10px;border-radius:10px;border:1px solid #ccc;background:#fff;font-size:15px;';
    closeBtn.addEventListener('click', function(){ card.remove(); });
    row.appendChild(copyBtn); row.appendChild(closeBtn);
    card.appendChild(h); card.appendChild(p); card.appendChild(row);
    document.body.appendChild(card);
  }
  window.__nsTranslateSelection=function(){
    var sel=window.getSelection ? window.getSelection().toString() : '';
    sel=(sel||'').trim();
    if(!sel){ showToast('请先选中要翻译的文字'); return; }
    showToast('翻译中…');
    nsTranslateText(sel).then(function(t){
      if(!t){ showToast('翻译失败，请重试'); return; }
      nsShowTransCard(t);
    });
  };
  window.__nsTranslatePage=function(){
    var blocks=nsPostBlocks();
    if(!blocks.length){ showToast('当前页面没有可翻译的帖子内容'); return; }
    var targets=[];
    blocks.forEach(function(b){
      var els=b.querySelectorAll('p, div');
      els.forEach(function(el){
        if(el.querySelector('p, div')) return;
        if(el.closest('pre')!==null) return;
        if(el.classList.contains('ns-trans')) return;
        var t=(el.innerText||'').trim();
        if(t.length>=20 && t.length<=400) targets.push(el);
      });
    });
    if(targets.length>10) targets=targets.slice(0,10);
    if(!targets.length){
      var first=(blocks[0].innerText||'').trim().slice(0,1200);
      if(!first){ showToast('没有找到可翻译的段落'); return; }
      showToast('翻译中…');
      nsTranslateText(first).then(function(t){
        if(!t){ showToast('翻译失败，请重试'); return; }
        nsShowTransCard(t);
      });
      return;
    }
    showToast('正在翻译 '+targets.length+' 段…');
    var i=0;
    function next(){
      if(i>=targets.length){ showToast('翻译完成'); return; }
      var el=targets[i++];
      var txt=(el.innerText||'').trim();
      nsTranslateText(txt).then(function(tr){
        if(tr){
          var d=document.createElement('div');
          d.className='ns-trans';
          d.style.cssText='color:#2563eb;font-size:14px;line-height:1.6;margin:6px 0;padding:8px 10px;background:rgba(37,99,235,0.07);border-radius:8px;';
          d.textContent=tr;
          if(el.parentElement) el.parentElement.insertBefore(d, el.nextSibling);
        }
        next();
      });
    }
    next();
  };
  window.__nsClearTranslation=function(){
    document.querySelectorAll('.ns-trans').forEach(function(el){ el.remove(); });
    showToast('已清除翻译');
  };

  // ---------- 16. In-site search (site search box; history in localStorage) ----------
  window.__nsDoSearch=function(q){
    q=(q||'').trim(); if(!q) return false;
    var h=readJSON('searchHist', []);
    h=h.filter(function(x){ return x!==q; }); h.unshift(q); if(h.length>10) h=h.slice(0,10);
    store('searchHist', JSON.stringify(h));
    var sels=['input[type="search"]', 'input[placeholder*="搜索"]', 'form[action*="search"] input', 'input[name="q"]', 'input[name="keyword"]'];
    var input=null;
    for(var i=0;i<sels.length;i++){ input=document.querySelector(sels[i]); if(input) break; }
    if(input){
      var form=input.closest ? input.closest('form') : null;
      var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(input, q);
      input.dispatchEvent(new Event('input', {bubbles:true}));
      if(form){ form.submit(); }
      else { input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true})); }
      return true;
    }
    return false;
  };
  window.__nsSearchHist=function(){ return read('searchHist','[]'); };

  // ---------- 17. Trade / lottery sidebar data (read-only fetch; results go back via the bridge) ----------
  function nsExtractLinks(doc, count){
    var out=[]; var seen={};
    var links=Array.prototype.slice.call(doc.querySelectorAll('a[href*="/post-"], a[href*="/post/"]'));
    links.forEach(function(a){
      var href=a.href;
      if(seen[href]) return; seen[href]=1;
      var title=(a.textContent||'').trim();
      if(!title || title.length<3) return;
      var row=a.closest ? a.closest('li, article, div') : null;
      var time='';
      if(row){
        var tm=row.querySelector('time');
        if(tm) time=(tm.textContent||'').trim();
        if(!time){
          var m=(row.innerText||'').match(/[0-9]+分钟前|[0-9]+小时前|昨天|前天|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}-[0-9]{2}/);
          if(m) time=m[0];
        }
      }
      out.push({title:title, href:href, time:time});
    });
    return out.slice(0,count);
  }
  window.__nsFetchTradeLottery=function(){
    var tradeUrl=window.__nsFindSectionHref ? window.__nsFindSectionHref('交易') : '';
    var promoUrl=window.__nsFindSectionHref ? window.__nsFindSectionHref('推广') : '';
    var homeUrl=location.origin+'/';
    var tradesP=tradeUrl
      ? fetch(tradeUrl, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){ return nsExtractLinks(new DOMParser().parseFromString(html,'text/html'), 5); }).catch(function(){ return []; })
      : Promise.resolve([]);
    var lotP=Promise.all([
      fetch(homeUrl, {credentials:'include'}).then(function(r){ return r.text(); }).catch(function(){ return ''; }),
      promoUrl ? fetch(promoUrl, {credentials:'include'}).then(function(r){ return r.text(); }).catch(function(){ return ''; }) : Promise.resolve('')
    ]).then(function(htmls){
      var seen={}; var out=[];
      htmls.forEach(function(html){
        if(!html) return;
        var doc=new DOMParser().parseFromString(html,'text/html');
        nsExtractLinks(doc, 20).forEach(function(it){
          if(it.title.indexOf('抽奖')!==-1 && !seen[it.href]){ seen[it.href]=1; out.push(it); }
        });
      });
      return out.slice(0,5);
    });
    var mine=readJSON('myLotteries', []);
    var drawnP=Promise.all(mine.slice(0,5).map(function(it){
      return fetch(it.href, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
        var drawn=html.indexOf('已开奖')!==-1 || html.indexOf('中奖名单')!==-1 || html.indexOf('开奖结果')!==-1;
        return {title:it.title, href:it.href, time:'', drawn:drawn};
      }).catch(function(){ return {title:it.title, href:it.href, time:'', drawn:false}; });
    }));
    Promise.all([tradesP, lotP, drawnP]).then(function(res){
      nsBridgePost('tradeLottery', JSON.stringify({trades:res[0], lotteries:res[1], mine:res[2]}));
    });
  };

  // ---------- 18. Values Swift asks for: Markdown export, page images, page text, template insert ----------
  window.__nsExportMarkdown=function(){
    var title=(document.title||'').trim();
    var lines=['# '+title, '', location.href, ''];
    var blocks=nsPostBlocks();
    if(!blocks.length) return '';
    blocks.forEach(function(b){
      var au=authorOf(b)||'楼主';
      lines.push('## '+au); lines.push('');
      lines.push((b.innerText||'').trim()); lines.push('');
      var imgs=b.querySelectorAll ? b.querySelectorAll('img') : [];
      var hasImg=false;
      imgs.forEach(function(im){ if(im.src && im.src.indexOf('http')===0){ lines.push('![]('+im.src+')'); hasImg=true; } });
      if(hasImg) lines.push('');
      lines.push('---'); lines.push('');
    });
    return lines.join(String.fromCharCode(10));
  };
  window.__nsPageImages=function(){
    var out=[]; var seen={};
    document.querySelectorAll('img').forEach(function(im){
      var s=im.getAttribute('src')||'';
      if(s.indexOf('http')!==0) return;
      if(s.indexOf('avatar')!==-1) return;
      if(seen[s]) return; seen[s]=1;
      if(im.naturalWidth && im.naturalWidth<200) return;
      out.push(s);
    });
    return JSON.stringify(out);
  };
  window.__nsPageText=function(){
    var blocks=nsPostBlocks();
    var txt='';
    if(blocks.length){ txt=blocks.map(function(b){ return (b.innerText||'').trim(); }).join(String.fromCharCode(10)+String.fromCharCode(10)); }
    else txt=(document.body.innerText||'');
    return txt.slice(0, 20000);
  };
  window.__nsInsertTemplate=function(text){
    var ta=document.querySelector('textarea[name*="content"], textarea[name*="comment"], textarea');
    if(ta){
      var setter=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      var cur=ta.value||'';
      setter.call(ta, cur+(cur?' ':'')+text);
      ta.dispatchEvent(new Event('input', {bubbles:true}));
      ta.focus();
      return true;
    }
    var ed=document.querySelector('[contenteditable="true"]');
    if(ed){ ed.focus(); document.execCommand('insertText', false, text); return true; }
    return false;
  };

  // ---------- Init: apply everything; re-apply on DOM changes (debounced) ----------
  applyListPage();
  setupInfiniteScroll();
  applyFold();
  applyCodeBlocks();
  applyRep();
  applyPostNotes();
  applyOnlyOP(false);
  var nsObsT=null;
  var nsObs=new MutationObserver(function(){
    if(nsObsT) clearTimeout(nsObsT);
    nsObsT=setTimeout(function(){ applyListPage(); applyCodeBlocks(); applyPostNotes(); }, 200);
  });
  nsObs.observe(document.documentElement, {childList:true, subtree:true});
})();
"""

// MARK: - Model
struct ReplyTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var group: String
    var text: String
}

struct LinkItem: Identifiable {
    let id = UUID()
    let title: String
    let href: String
    let time: String
    let drawn: Bool
}

final class BrowserModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    weak var webView: WKWebView?
    @Published var isDark = false
    @Published var fontScale: CGFloat = 1.0
    @Published var hideAds = true
    @Published var keywords = ""
    @Published var canGoBack = false
    // v2 additions
    @Published var highlightKeywords = ""
    @Published var blacklist = ""
    @Published var userNotes = ""
    @Published var onlyOP = false
    @Published var isSpeaking = false
    @Published var templates: [ReplyTemplate] = []
    @Published var translatorProvider = "mymemory"
    @Published var translatorKey = ""
    @Published var translatorBase = "https://openrouter.ai/api/v1"
    @Published var translatorModel = "deepseek/deepseek-chat"
    @Published var searchHistory: [String] = []
    @Published var tradeItems: [LinkItem] = []
    @Published var lotteryItems: [LinkItem] = []
    @Published var myLotteries: [LinkItem] = []
    @Published var isLoadingTrade = false
    @Published var showLotteryAlert = false

    private let synthesizer = AVSpeechSynthesizer()

    let homeURL = URL(string: "https://www.nodeseek.com/")!
    let sections = ["日常","技术","情报","测评","交易","拼车","推广","生活","Dev","贴图","曝光","沙盒"]

    override init() {
        super.init()
        synthesizer.delegate = self
        isDark = UserDefaults.standard.bool(forKey: "ns_dark")
        hideAds = UserDefaults.standard.object(forKey: "ns_hideAds") as? Bool ?? true
        keywords = UserDefaults.standard.string(forKey: "ns_keywords") ?? ""
        let fs = UserDefaults.standard.double(forKey: "ns_fontScale")
        if fs > 0 { fontScale = CGFloat(fs) }
        highlightKeywords = UserDefaults.standard.string(forKey: "ns_hlKeywords") ?? ""
        blacklist = UserDefaults.standard.string(forKey: "ns_blacklist") ?? ""
        userNotes = UserDefaults.standard.string(forKey: "ns_userNotes") ?? ""
        onlyOP = UserDefaults.standard.bool(forKey: "ns_onlyOP")
        translatorProvider = UserDefaults.standard.string(forKey: "ns_translatorProvider") ?? "mymemory"
        translatorKey = UserDefaults.standard.string(forKey: "ns_translatorKey") ?? ""
        translatorBase = UserDefaults.standard.string(forKey: "ns_translatorBase") ?? "https://openrouter.ai/api/v1"
        translatorModel = UserDefaults.standard.string(forKey: "ns_translatorModel") ?? "deepseek/deepseek-chat"
        if let data = UserDefaults.standard.data(forKey: "ns_templates"),
           let arr = try? JSONDecoder().decode([ReplyTemplate].self, from: data) {
            templates = arr
        }
    }

    // MARK: - Existing navigation / display
    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__nsTop && window.__nsTop();", completionHandler: nil)
    }
    func goSection(_ name: String) {
        webView?.evaluateJavaScript("window.__nsGoSection && window.__nsGoSection('\(name)');") { _, _ in }
    }
    func setDark(_ on: Bool) {
        isDark = on
        UserDefaults.standard.set(on, forKey: "ns_dark")
        webView?.evaluateJavaScript("window.__nsSetDark && window.__nsSetDark(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setFontScale(_ s: CGFloat) {
        fontScale = s
        UserDefaults.standard.set(Double(s), forKey: "ns_fontScale")
        webView?.pageZoom = s
    }
    func setHideAds(_ on: Bool) {
        hideAds = on
        UserDefaults.standard.set(on, forKey: "ns_hideAds")
        webView?.evaluateJavaScript("window.__nsSetHideAds && window.__nsSetHideAds(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setKeywords(_ s: String) {
        keywords = s
        UserDefaults.standard.set(s, forKey: "ns_keywords")
        let esc = s.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__nsSetKeywords && window.__nsSetKeywords('\(esc)');", completionHandler: nil)
    }
    func manualSignIn() {
        webView?.evaluateJavaScript("""
          fetch('/api/attendance?random=true',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:'{}'})
            .then(r=>r.text()).then(t=>{ try{var j=JSON.parse(t); window.__nsToast && window.__nsToast(j.message||'已签到');}catch(e){ window.__nsToast && window.__nsToast('已签到'); } })
            .catch(()=>{ window.__nsToast && window.__nsToast('签到失败，请检查登录'); });
        """, completionHandler: nil)
    }

    // MARK: - Helpers
    func jsEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
    func toast(_ msg: String) {
        webView?.evaluateJavaScript("window.__nsToast && window.__nsToast('\(jsEsc(msg))');", completionHandler: nil)
    }
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var root = scenes.first?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = root?.presentedViewController { root = presented }
        return root
    }
    func presentActivity(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let top = Self.topViewController() else { return }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }

    // MARK: - v2: list enhancements
    func setHLKeywords(_ s: String) {
        highlightKeywords = s
        UserDefaults.standard.set(s, forKey: "ns_hlKeywords")
        webView?.evaluateJavaScript("window.__nsSetHLKeywords && window.__nsSetHLKeywords('\(jsEsc(s))');", completionHandler: nil)
    }
    func setBlacklist(_ s: String) {
        blacklist = s
        UserDefaults.standard.set(s, forKey: "ns_blacklist")
        webView?.evaluateJavaScript("window.__nsSetBlacklist && window.__nsSetBlacklist('\(jsEsc(s))');", completionHandler: nil)
    }
    func setUserNotes(_ s: String) {
        userNotes = s
        UserDefaults.standard.set(s, forKey: "ns_userNotes")
        var dict: [String: String] = [:]
        s.components(separatedBy: .newlines).forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && !parts[0].isEmpty { dict[parts[0]] = parts[1] }
        }
        let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        webView?.evaluateJavaScript("window.__nsSetUserNotes && window.__nsSetUserNotes('\(jsEsc(json))');", completionHandler: nil)
    }
    func clearReadHistory() {
        webView?.evaluateJavaScript("window.__nsClearRead && window.__nsClearRead();", completionHandler: nil)
    }
    func setOnlyOP(_ on: Bool) {
        onlyOP = on
        UserDefaults.standard.set(on, forKey: "ns_onlyOP")
        webView?.evaluateJavaScript("window.__nsSetOnlyOP && window.__nsSetOnlyOP(\(on ? "true" : "false"));", completionHandler: nil)
    }

    // MARK: - v2: reply templates (insert only; the user taps submit themselves)
    func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: "ns_templates")
        }
    }
    func addTemplate(group: String, text: String) {
        let g = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        templates.append(ReplyTemplate(group: g.isEmpty ? "常用" : g, text: t))
        saveTemplates()
    }
    func removeTemplates(at offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        saveTemplates()
    }
    func insertTemplate(_ t: ReplyTemplate) {
        webView?.evaluateJavaScript("window.__nsInsertTemplate && window.__nsInsertTemplate('\(jsEsc(t.text))');") { [weak self] result, _ in
            if result as? Bool == true { self?.toast("已插入模板，请检查后手动提交") }
            else { self?.toast("未找到回复框，请先打开回帖") }
        }
    }

    // MARK: - v2: export / PDF / images / share
    func exportMarkdown() {
        webView?.evaluateJavaScript("window.__nsExportMarkdown && window.__nsExportMarkdown();") { [weak self] result, _ in
            guard let self = self else { return }
            guard let md = result as? String, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.toast("当前页面没有可导出的帖子内容"); return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NodeSeek-帖子.md")
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                self.presentActivity(items: [url])
            } catch { self.toast("导出失败") }
        }
    }
    func exportPDF() {
        guard let wv = webView else { return }
        wv.createPDF { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("NodeSeek-帖子.pdf")
                do {
                    try data.write(to: url)
                    self.presentActivity(items: [url])
                } catch { self.toast("PDF 保存失败") }
            case .failure:
                self.toast("PDF 生成失败")
            }
        }
    }
    func savePageImages() {
        webView?.evaluateJavaScript("window.__nsPageImages && window.__nsPageImages();") { [weak self] result, _ in
            guard let self = self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let urls = try? JSONSerialization.jsonObject(with: data) as? [String],
                  !urls.isEmpty else {
                self.toast("本页没有可保存的图片"); return
            }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .denied || status == .restricted {
                self.toast("请在系统设置里允许 App 访问相册"); return
            }
            let saveAll: () -> Void = {
                let group = DispatchGroup()
                let lock = NSLock()
                var saved = 0
                for u in urls {
                    guard let url = URL(string: u) else { continue }
                    group.enter()
                    URLSession.shared.dataTask(with: url) { data, _, _ in
                        guard let data = data, !data.isEmpty else { group.leave(); return }
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                        }) { ok, _ in
                            if ok { lock.lock(); saved += 1; lock.unlock() }
                            group.leave()
                        }
                    }.resume()
                }
                group.notify(queue: .main) { self.toast("已保存 \(saved) 张图片（共 \(urls.count) 张）") }
            }
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    DispatchQueue.main.async { saveAll() }
                }
            } else {
                saveAll()
            }
        }
    }
    func shareCurrent() {
        guard let url = webView?.url else { return }
        let title = webView?.title ?? "NodeSeek"
        presentActivity(items: [title, url])
    }

    // MARK: - v2: read aloud
    func speakToggle() {
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        webView?.evaluateJavaScript("window.__nsPageText && window.__nsPageText();") { [weak self] result, _ in
            guard let self = self else { return }
            guard let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.toast("当前页面没有可朗读的正文"); return
            }
            let utterance = AVSpeechUtterance(string: text)
            let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FA5).contains($0.value) }
            utterance.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
            utterance.rate = 0.5
            self.synthesizer.speak(utterance)
            self.isSpeaking = true
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    // MARK: - v2: search (site search box first; Google site search fallback — NodeSeek has no open search API)
    func doSearch(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        webView?.evaluateJavaScript("window.__nsDoSearch && window.__nsDoSearch('\(jsEsc(query))');") { [weak self] result, _ in
            guard let self = self else { return }
            self.loadSearchHistory()
            if result as? Bool == true { return }
            var comps = URLComponents(string: "https://www.google.com/search")
            comps?.queryItems = [URLQueryItem(name: "q", value: "site:nodeseek.com " + query)]
            if let url = comps?.url { self.load(url) }
        }
    }
    func loadSearchHistory() {
        webView?.evaluateJavaScript("window.__nsSearchHist && window.__nsSearchHist();") { [weak self] result, _ in
            guard let self = self else { return }
            if let json = result as? String, let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                self.searchHistory = arr
            }
        }
    }

    // MARK: - v2: trade / lottery (read-only; results arrive via the nsBridge message handler)
    func fetchTradeLottery() {
        isLoadingTrade = true
        tradeItems = []
        lotteryItems = []
        myLotteries = []
        webView?.evaluateJavaScript("window.__nsFetchTradeLottery && window.__nsFetchTradeLottery();", completionHandler: nil)
    }
    func handleTradeLottery(_ json: String) {
        isLoadingTrade = false
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func items(_ key: String) -> [LinkItem] {
            guard let arr = obj[key] as? [[String: Any]] else { return [] }
            return arr.compactMap { d in
                guard let title = d["title"] as? String, let href = d["href"] as? String else { return nil }
                return LinkItem(title: title, href: href, time: d["time"] as? String ?? "", drawn: d["drawn"] as? Bool ?? false)
            }
        }
        tradeItems = items("trades")
        lotteryItems = items("lotteries")
        myLotteries = items("mine")
        if myLotteries.contains(where: { $0.drawn }) { showLotteryAlert = true }
    }

    // MARK: - v2: translation (key lives in UserDefaults only, never in the page's localStorage)
    func applyTranslatorConfig() {
        if translatorProvider == "byok" && !translatorKey.isEmpty {
            let js = "window.__nsSetTranslator && window.__nsSetTranslator({provider:'byok', key:'\(jsEsc(translatorKey))', base:'\(jsEsc(translatorBase))', model:'\(jsEsc(translatorModel))'});"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        } else {
            webView?.evaluateJavaScript("window.__nsSetTranslator && window.__nsSetTranslator({provider:'mymemory'});", completionHandler: nil)
        }
    }
    func setTranslatorProvider(_ p: String) {
        translatorProvider = p
        UserDefaults.standard.set(p, forKey: "ns_translatorProvider")
        applyTranslatorConfig()
    }
    func setTranslatorKey(_ k: String) {
        translatorKey = k
        UserDefaults.standard.set(k, forKey: "ns_translatorKey")
        applyTranslatorConfig()
    }
    func setTranslatorBase(_ b: String) {
        translatorBase = b
        UserDefaults.standard.set(b, forKey: "ns_translatorBase")
        applyTranslatorConfig()
    }
    func setTranslatorModel(_ m: String) {
        translatorModel = m
        UserDefaults.standard.set(m, forKey: "ns_translatorModel")
        applyTranslatorConfig()
    }
    func translateSelection() {
        webView?.evaluateJavaScript("window.__nsTranslateSelection && window.__nsTranslateSelection();", completionHandler: nil)
    }
    func translatePage() {
        webView?.evaluateJavaScript("window.__nsTranslatePage && window.__nsTranslatePage();", completionHandler: nil)
    }
    func clearTranslation() {
        webView?.evaluateJavaScript("window.__nsClearTranslation && window.__nsClearTranslation();", completionHandler: nil)
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false
    @State private var showSettings = false
    @State private var showMore = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showSections: $showSections, showSettings: $showSettings, showMore: $showMore)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $showMore) { MoreSheet(model: model, dismissAll: { showMore = false }) }
    }
}

// MARK: - WebView
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent store: repeat opens reuse the HTTP cache and the Cloudflare
        // clearance cookie, so the challenge is skipped. Never clear it.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let early = WKUserScript(source: nsEarlyJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let main = WKUserScript(source: nsJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(early)
        config.userContentController.addUserScript(main)
        config.userContentController.add(context.coordinator, name: "nsBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
            model.applyTranslatorConfig()
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "nsBridge",
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let data = body["data"] as? String else { return }
            if kind == "tradeLottery" { model.handleTradeLottery(data) }
        }
    }
}

// MARK: - Bottom bar (comfortable proportions, smooth)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool
    @Binding var showSettings: Bool
    @Binding var showMore: Bool

    var body: some View {
        HStack(spacing: 4) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn() }
            BarButton(icon: model.isDark ? "moon.fill" : "moon", label: "深色") {
                model.setDark(!model.isDark)
            }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "ellipsis.circle", label: "更多") { showMore = true }
            BarButton(icon: "gearshape", label: "设置") { showSettings = true }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Section picker sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.sections, id: \.self) { name in
                        Button {
                            model.goSection(name)
                            dismiss()
                        } label: {
                            Text(name)
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("分区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - More sheet (post-page actions; new features live here, not in the bottom bar)
struct MoreSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showTrade = false
    let dismissAll: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("搜索") {
                    HStack {
                        TextField("搜帖子、用户…", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }
                    }
                    if !model.searchHistory.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(model.searchHistory, id: \.self) { q in
                                    Button(q) { searchText = q; model.doSearch(q); dismiss() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Text("先走站内搜索框；站内没有搜索框时用 Google 站内搜索兜底。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("帖子") {
                    Toggle("只看楼主", isOn: Binding(
                        get: { model.onlyOP },
                        set: { model.setOnlyOP($0) }
                    ))
                    Button("导出 Markdown") { dismiss(); afterDismiss { model.exportMarkdown() } }
                    Button("转 PDF") { dismiss(); afterDismiss { model.exportPDF() } }
                    Button("保存本页图片到相册") { dismiss(); afterDismiss { model.savePageImages() } }
                    Button(model.isSpeaking ? "停止朗读" : "朗读本页") { model.speakToggle(); dismiss() }
                    Button("分享帖子") { dismiss(); afterDismiss { model.shareCurrent() } }
                    Button("翻译选中的文字") { model.translateSelection(); dismiss() }
                    Button("翻译整页（双语对照）") { model.translatePage(); dismiss() }
                    Button("清除页内翻译") { model.clearTranslation() }
                }
                Section("快捷回复模板") {
                    if model.templates.isEmpty {
                        Text("还没有模板，去设置里添加。").foregroundStyle(.secondary)
                    }
                    ForEach(model.templates) { t in
                        Button {
                            model.insertTemplate(t)
                            dismiss()
                        } label: {
                            HStack {
                                Text(t.group).bold()
                                Text(t.text).lineLimit(2)
                            }
                        }
                    }
                    Text("点一下只插入文字，提交需你自己点发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("交易 / 抽奖") {
                    Button("最新交易与抽奖") { showTrade = true }
                    Text("只看最新动态和开奖提醒，不会自动参加抽奖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { model.loadSearchHistory() }
            .sheet(isPresented: $showTrade) {
                TradeSheet(model: model, onOpen: { url in
                    model.load(url)
                    dismissAll()
                })
            }
        }
        .presentationDetents([.medium, .large])
    }

    func doSearch() {
        model.doSearch(searchText)
        dismiss()
    }
    func afterDismiss(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

// MARK: - Trade / lottery sheet (read-only lists + draw reminders; never auto-enters)
struct TradeSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    let onOpen: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.isLoadingTrade {
                    Section { Text("加载中…").foregroundStyle(.secondary) }
                }
                Section("最新交易") {
                    if model.tradeItems.isEmpty && !model.isLoadingTrade {
                        Text("暂无数据").foregroundStyle(.secondary)
                    }
                    ForEach(model.tradeItems) { it in
                        Button {
                            if let u = URL(string: it.href) { onOpen(u) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(it.title).lineLimit(2)
                                if !it.time.isEmpty {
                                    Text(it.time).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("最新抽奖") {
                    if model.lotteryItems.isEmpty && !model.isLoadingTrade {
                        Text("暂未找到抽奖帖").foregroundStyle(.secondary)
                    }
                    ForEach(model.lotteryItems) { it in
                        Button {
                            if let u = URL(string: it.href) { onOpen(u) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(it.title).lineLimit(2)
                                if !it.time.isEmpty {
                                    Text(it.time).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("我参加的抽奖") {
                    if model.myLotteries.isEmpty {
                        Text("点开抽奖帖即记为参加，在这里看开奖提醒。").foregroundStyle(.secondary)
                    }
                    ForEach(model.myLotteries) { it in
                        Button {
                            if let u = URL(string: it.href) { onOpen(u) }
                        } label: {
                            HStack {
                                Text(it.title).lineLimit(2)
                                Spacer()
                                if it.drawn {
                                    Text("已开奖").font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("交易 / 抽奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { model.fetchTradeLottery() }
            .alert("抽奖开奖提醒", isPresented: $model.showLotteryAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("你参加的抽奖已有开奖结果，去帖子里看看吧。")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsText = ""
    @State private var notesText = ""
    @State private var newTemplateGroup = ""
    @State private var newTemplateText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Stepper("", value: Binding(
                            get: { model.fontScale },
                            set: { model.setFontScale($0) }
                        ), in: 0.85...1.35, step: 0.05)
                        Text(String(format: "%.0f%%", model.fontScale * 100))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle("深色模式", isOn: Binding(
                        get: { model.isDark },
                        set: { model.setDark($0) }
                    ))
                    Toggle("隐藏广告与推广位", isOn: Binding(
                        get: { model.hideAds },
                        set: { model.setHideAds($0) }
                    ))
                }
                Section("屏蔽关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $keywordsText)
                        .onChange(of: keywordsText) { model.setKeywords($0) }
                    Text("包含这些词的帖子标题会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关键词高亮") {
                    TextField("多个关键词用英文逗号隔开", text: $model.highlightKeywords)
                        .onChange(of: model.highlightKeywords) { model.setHLKeywords($0) }
                    Button("复制高亮词（导出）") {
                        UIPasteboard.general.string = model.highlightKeywords
                    }
                    Text("命中这些词的标题会标黄。和屏蔽词分开管理；把文本粘贴进输入框即可导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("用户备注") {
                    TextEditor(text: $notesText)
                        .frame(minHeight: 80)
                        .onChange(of: notesText) { model.setUserNotes($0) }
                    Text("每行一个，格式：用户名=备注。备注会显示在用户名旁边。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("黑名单") {
                    TextField("多个用户名用英文逗号隔开", text: $model.blacklist)
                        .onChange(of: model.blacklist) { model.setBlacklist($0) }
                    Text("黑名单用户的帖子在列表页隐藏，在帖子页折叠（可点开展开）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("已读记录") {
                    Button("清空已读记录") { model.clearReadHistory() }
                    Text("点过的帖子会在列表里变暗，存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("快捷回复模板") {
                    ForEach(model.templates) { t in
                        HStack {
                            Text(t.group).bold()
                            Text(t.text).lineLimit(2)
                        }
                    }
                    .onDelete { model.removeTemplates(at: $0) }
                    HStack {
                        TextField("分组", text: $newTemplateGroup)
                        TextField("内容", text: $newTemplateText)
                        Button("添加") {
                            model.addTemplate(group: newTemplateGroup, text: newTemplateText)
                            newTemplateGroup = ""
                            newTemplateText = ""
                        }
                        .disabled(newTemplateText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("在帖子页点“更多”可插入模板，提交需你自己点发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("翻译") {
                    Picker("翻译方式", selection: $model.translatorProvider) {
                        Text("免费 MyMemory").tag("mymemory")
                        Text("自带 Key（OpenAI 兼容）").tag("byok")
                    }
                    .onChange(of: model.translatorProvider) { model.setTranslatorProvider($0) }
                    if model.translatorProvider == "byok" {
                        SecureField("API Key", text: $model.translatorKey)
                            .onChange(of: model.translatorKey) { model.setTranslatorKey($0) }
                        TextField("Base URL", text: $model.translatorBase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: model.translatorBase) { model.setTranslatorBase($0) }
                        TextField("模型", text: $model.translatorModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: model.translatorModel) { model.setTranslatorModel($0) }
                    }
                    Text("默认用免费 MyMemory，无需 Key；自带 Key 走你填的 OpenAI 兼容接口。Key 只存在本机，不会进网页存储。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("刷新页面") { model.reload(); dismiss() }
                    Button("回到首页") { model.goHome(); dismiss() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                keywordsText = model.keywords
                notesText = model.userNotes
            }
        }
        .presentationDetents([.medium, .large])
    }
}

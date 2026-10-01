
(function(){
  const navBtn=document.querySelector('.nav-toggle');
  const nav=document.querySelector('header nav');
  if(navBtn&&nav){navBtn.addEventListener('click',()=>nav.classList.toggle('open'));}

  const searchForm=document.querySelector('#tl-search-form');
  if(searchForm){
    const preparedFrames=new WeakSet();
    const prepareFrame=(frame)=>{
      if(preparedFrames.has(frame))return;
      preparedFrames.add(frame);
      let attempts=0;
      const timer=setInterval(()=>{
        attempts+=1;
        try{
          const subtitle=frame.contentDocument?.querySelector('.sf-top-block-2');
          if(subtitle){
            subtitle.style.setProperty('display','none','important');
            frame.contentWindow?.dispatchEvent(new Event('resize'));
            clearInterval(timer);
          }
        }catch(_){}
        if(attempts>=40)clearInterval(timer);
      },250);
    };
    const scanFrames=()=>searchForm.querySelectorAll('iframe').forEach(prepareFrame);
    new MutationObserver(scanFrames).observe(searchForm,{childList:true,subtree:true});
    scanFrames();
  }

  document.querySelectorAll('[data-contact-toggle]').forEach(btn=>{
    btn.addEventListener('click',()=>document.querySelector('.contact-pop')?.classList.toggle('open'));
  });

  const links=[...document.querySelectorAll('[data-lightbox]')];
  if(links.length){
    const lb=document.createElement('div');
    lb.className='lightbox';
    lb.innerHTML='<button class="lightbox-btn lightbox-close" aria-label="Закрыть">×</button><button class="lightbox-btn lightbox-prev" aria-label="Предыдущее">‹</button><img alt=""><button class="lightbox-btn lightbox-next" aria-label="Следующее">›</button><div class="lightbox-count"></div>';
    document.body.appendChild(lb);
    const img=lb.querySelector('img'), count=lb.querySelector('.lightbox-count');
    let i=0,startX=0;
    const show=(n)=>{i=(n+links.length)%links.length;img.src=links[i].href;count.textContent=(i+1)+' / '+links.length;lb.classList.add('open');};
    links.forEach((a,n)=>a.addEventListener('click',e=>{e.preventDefault();show(n)}));
    lb.querySelector('.lightbox-close').onclick=()=>lb.classList.remove('open');
    lb.querySelector('.lightbox-prev').onclick=()=>show(i-1);
    lb.querySelector('.lightbox-next').onclick=()=>show(i+1);
    lb.addEventListener('click',e=>{if(e.target===lb)lb.classList.remove('open')});
    document.addEventListener('keydown',e=>{if(!lb.classList.contains('open'))return;if(e.key==='Escape')lb.classList.remove('open');if(e.key==='ArrowLeft')show(i-1);if(e.key==='ArrowRight')show(i+1)});
    lb.addEventListener('touchstart',e=>startX=e.changedTouches[0].clientX,{passive:true});
    lb.addEventListener('touchend',e=>{const dx=e.changedTouches[0].clientX-startX;if(Math.abs(dx)>50)show(i+(dx<0?1:-1))},{passive:true});
  }
})();

const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {pathToFileURL}=require('url');
const {chromium}=require('C:/Users/Xuhaowei/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const base=__dirname,assertions=[];
function check(ok,message){if(!ok)throw Error(message);assertions.push(message);}
(async()=>{
  const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,args:['--disable-gpu']});
  try{
    const page=await browser.newPage({viewport:{width:820,height:1100}}),errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto(pathToFileURL(path.join(base,'lunaria-inspection.html')).href);
    await page.locator('iframe').waitFor();
    const frame=page.frames().find(f=>f!==page.mainFrame());
    await frame.waitForFunction(()=>!!document.getElementById('lunaria-dream-barrage')?.lunariaPreview);
    const run=(fn,arg)=>frame.evaluate(({fn,arg})=>{const api=document.getElementById('lunaria-dream-barrage').lunariaPreview;return eval('('+fn+')')(api,arg);},{fn:fn.toString(),arg});
    const seek=t=>run((a,t)=>a.seek(t),t),state=()=>run(a=>a.state()),bullets=()=>run(a=>a.bullets());
    const root=frame.locator('#lunaria-dream-barrage'),profiles=[],petalChecks=[],rotationChecks=[],layouts=[],limitChecks=[];
    if(process.argv.includes('--assets-only')){
      const assets=await run(a=>a.assets());
      const name='star-bullet-atlas-32px.png';
      fs.writeFileSync(path.join(base,'assets',name),Buffer.from(assets[name].png.split(',')[1],'base64'));
      console.log('Exported generated star artwork');return;
    }
    for(const density of ['board','reference']){
      await frame.locator('#ln-dream-density').selectOption(density);
      let peak=0,visible=0,deferrals=0;
      for(let p=0;p<16;p++){
        await seek(p*8);
        const born=await bullets();
        check(born.length>0&&born.every(b=>b.birth===p*8&&b.age===0),'Phase-local initial burst '+density+'/'+p);
        check(born.every(b=>Math.hypot(b.birthX-b.bossBirthX,b.birthY-b.bossBirthY)<=32),'Real Boss muzzle '+density+'/'+p);
        for(let local=0;local<8;local+=.1){
          await seek(p*8+local);
          const s=await state();
          check(s.generatedBullets<=s.limit&&s.dropped===0,'Bounded complete bursts '+density+'/'+p+'/'+local.toFixed(1));
          check(s.visibleBullets<=s.generatedBullets&&s.visibleElements>=s.visibleBullets+2,'Consistent visible counters '+density+'/'+p+'/'+local.toFixed(1));
          check(s.peakElements>=s.visibleElements&&s.peakVisible>=s.visibleBullets,'Monotonic peaks '+density+'/'+p+'/'+local.toFixed(1));
          peak=Math.max(peak,s.generatedBullets);visible=Math.max(visible,s.visibleBullets);deferrals=Math.max(deferrals,s.deferred);
        }
      }
      profiles.push({density,peakGenerated:peak,peakVisible:visible,maxDeferrals:deferrals});
    }
    for(const p of [3,4,5]){
      await seek(p*8+.4);const old=(await bullets()).find(b=>b.event===0&&b.lane===0);
      await seek(p*8+.85);const later=(await bullets()).find(b=>b.event===0&&b.lane===0);
      check(old.vx===later.vx&&old.vy===later.vy&&old.originX===later.originX&&old.originY===later.originY,'Fixed birth ray '+p);
      const ax=old.x-old.originX,ay=old.y-old.originY,bx=later.x-later.originX,by=later.y-later.originY;
      check(Math.abs(ax*by-ay*bx)<1e-6&&Math.hypot(bx,by)>Math.hypot(ax,ay),'No in-flight Boss rotation '+p);
      await seek(p*8+1.2);const next=(await bullets()).find(b=>b.event===1&&b.lane===0);
      check(next&&next.launchAngle>old.launchAngle,'New burst rotates '+p);
      rotationChecks.push({phase:p,birthAngle:old.launchAngle,laterBirthAngle:next.launchAngle});
    }
    for(const petals of [3,4,5,6]){
      await seek(24);await frame.locator('#ln-dream-petals').selectOption(String(petals));
      const born=await bullets();
      const r=born.map(b=>({a:Math.atan2(b.vy,b.vx),r:Math.hypot(b.vx,b.vy)})).sort((a,b)=>a.a-b.a);
      const maxima=r.filter((b,i)=>b.r>r[(i+r.length-1)%r.length].r+1e-7&&b.r>=r[(i+1)%r.length].r-1e-7).length;
      check(maxima===petals,'Exact rose tips '+petals);
      await seek(25.6);await root.screenshot({path:path.join(base,'lunaria-rose'+petals+'-preview.png')});
      petalChecks.push({petals,bullets:born.length,maxima});
    }
    await frame.locator('#ln-dream-petals').selectOption('7/3');await seek(29.5);
    check((await bullets()).every(b=>Number.isFinite(b.x)&&Number.isFinite(b.y)),'Fractional rose remains finite');
    await root.screenshot({path:path.join(base,'lunaria-fractional-rose-preview.png')});
    await frame.locator('#ln-dream-petals').selectOption('auto');
    await seek(27.5);
    check((await bullets()).some(b=>b.event===0&&b.age>3.25),'Mid-screen slow petals survive old TTL');
    await seek(88.95);const stopped=(await bullets()).find(b=>b.event===0&&b.lane===0);
    await seek(89.18);const held=(await bullets()).find(b=>b.event===0&&b.lane===0);
    check(stopped.x===held.x&&stopped.y===held.y,'Retarget shots have a real stationary hold');
    await seek(89.7);check((await bullets()).some(b=>b.event===0&&b.retargeted&&Math.hypot(b.vx,b.vy)>99),'Held shots re-aim and relaunch');
    await seek(96.2);const arc=(await bullets()).find(b=>b.event===0&&b.lane===0);
    await seek(96.6);const turned=(await bullets()).find(b=>b.event===0&&b.lane===0);
    check(turned.angle>arc.angle,'Independent arc shots turn after birth');
    await seek(104.4);check((await state()).lasers.length===3&&(await state()).lasers.every(l=>!l.active),'Laser prewarning before damage window');
    await seek(105);check((await state()).lasers.length===3&&(await state()).lasers.every(l=>l.active),'Laser active after prewarning');
    await seek(114);const gap=(await bullets()).filter(b=>b.event===0);
    check(gap.every(b=>Math.abs(Math.atan2(Math.sin(b.angle-Math.PI/2),Math.cos(b.angle-Math.PI/2)))>=.249),'Ring keeps a safe emission sector');
    await seek(125.3);const a=await bullets();await seek(120);await seek(125.3);
    check(JSON.stringify(a)===JSON.stringify(await bullets()),'Combination replay is deterministic');
    for(const density of ['board','reference']){
      await frame.locator('#ln-dream-density').selectOption(density);
      for(const limit of density==='board'?[64,65,128,256,384,512]:[64,512,1024,2048,4096]){
        await frame.locator('#ln-dream-limit').fill(String(limit));
        await frame.locator('[data-ln-apply]').click();
        check((await state()).limit===limit,'Quantity control applies '+density+'/'+limit);
        let peak=0;
        for(let p=0;p<16;p++){
          await seek(p*8);check((await bullets()).length>0,'No empty pattern at '+density+'/'+limit+'/'+p);
          for(let local=0;local<8;local+=.5){
            await seek(p*8+local);const s=await state();
            check(s.generatedBullets<=limit&&s.dropped===0,'Custom limit bounds '+density+'/'+limit+'/'+p);
            peak=Math.max(peak,s.generatedBullets);
          }
        }
        limitChecks.push({density,limit,peakGenerated:peak});
      }
      const before=(await state()).limit;
      for(const invalid of ['', '63','64.5',density==='board'?'513':'4097']){
        await frame.locator('#ln-dream-limit').fill(invalid);
        await frame.locator('[data-ln-apply]').click();
        check((await state()).limit===before,'Reject invalid limit '+density+'/'+invalid);
      }
    }
    await frame.locator('#ln-dream-limit').fill('4096');await frame.locator('[data-ln-apply]').click();
    await frame.locator('#ln-dream-spin').check();
    for(const p of [3,4,5]){
      await seek(p*8+.2);const born=(await bullets()).find(b=>b.event===0&&b.lane===0);
      await seek(p*8+1.2);const later=(await bullets()).find(b=>b.event===0&&b.lane===0);
      const a0=Math.atan2(born.y-born.originY,born.x-born.originX),a1=Math.atan2(later.y-later.originY,later.x-later.originX);
      check(later.spin&&Math.abs(Math.atan2(Math.sin(a1-a0),Math.cos(a1-a0)))>.4,'Optional pattern rotation '+p);
      const png=await run(a=>a.pixels());fs.writeFileSync(path.join(base,'lunaria-spin-'+p+'-640x480.png'),Buffer.from(png.split(',')[1],'base64'));
    }
    await frame.evaluate(()=>window.dispatchEvent(new CustomEvent('openai:set_globals',{detail:{globals:{widgetState:{privateContent:{density:'board',limit:128,spin:false}}}}})));
    check((await state()).density==='board'&&(await state()).limit===128&&!(await state()).spin,'Restore saved custom settings');
    await frame.locator('#ln-dream-density').selectOption('reference');
    const samples={ring:5.5,spiral:13.5,sunflower:21.5,rose:29.5,pentagram:37.5,hexagram:45.5,curtain:53.5,homing:61.5,aimed:69.5,counter:77.5,polygon:85.5,retarget:93.5,arc:101.5,laser:109.5,gap:117.5,finale:125.5};
    for(const [name,t] of Object.entries(samples)){
      await seek(t);await root.screenshot({path:path.join(base,'lunaria-'+name+'-preview.png')});
      const png=await run(a=>a.pixels());fs.writeFileSync(path.join(base,'lunaria-'+name+'-640x480.png'),Buffer.from(png.split(',')[1],'base64'));
    }
    for(let p=0;p<16;p++){
      await frame.locator('[data-ln-phase="'+p+'"]').click();
      check((await state()).phase===p,'Scene button '+p);
    }
    await seek(121);await frame.locator('[data-ln-play]').click();
    await frame.waitForFunction(()=>document.getElementById('lunaria-dream-barrage').lunariaPreview.state().fps>0,null,{timeout:6000});
    const fps=(await state()).fps;check(Number.isFinite(fps)&&fps>0,'FPS is sampled from real animation frames');
    await frame.locator('[data-ln-play]').click();check(!(await state()).playing&&(await state()).fps===null,'Pause does not advertise a synthetic FPS');
    await frame.locator('#ln-dream-time').fill('108');check((await state()).phase===13,'Timeline selects extended scene');
    const box=await frame.locator('canvas').boundingBox();
    await page.mouse.move(box.x+box.width*.3,box.y+box.height*.85);await page.mouse.down();await page.mouse.up();
    check(Math.abs((await state()).player.x-192)<3,'Pointer moves player');
    await seek(127.98);await frame.locator('[data-ln-play]').click();
    await frame.waitForFunction(()=>document.getElementById('lunaria-dream-barrage').lunariaPreview.state().time===128);
    check(!(await state()).playing,'Preview stops at its end');
    await frame.locator('[data-ln-play]').click();
    await frame.waitForFunction(()=>document.getElementById('lunaria-dream-barrage').lunariaPreview.state().time>.05);
    check((await state()).playing,'Replay advances');
    await page.emulateMedia({reducedMotion:'reduce'});
    await frame.waitForFunction(()=>!document.getElementById('lunaria-dream-barrage').lunariaPreview.state().playing);
    await seek(125.5);
    for(const width of [820,480,360,320]){
      await page.setViewportSize({width,height:1100});await page.waitForTimeout(60);
      const layout=await frame.evaluate(()=>{
        const r=document.getElementById('lunaria-dream-barrage'),b=r.querySelector('canvas').getBoundingClientRect();
        return {width:innerWidth,scroll:document.documentElement.scrollWidth,ratio:b.width/b.height,controls:[...r.querySelectorAll('button,select,input')].filter(e=>e.getBoundingClientRect().width).map(e=>({x:e.getBoundingClientRect().x,right:e.getBoundingClientRect().right}))};
      });
      check(layout.scroll<=layout.width+1&&layout.controls.every(b=>b.x>=0&&b.right<=layout.width+1),'Responsive controls '+width);
      check(Math.abs(layout.ratio-4/3)<.02,'Aspect ratio '+width);layouts.push(layout);
      if(width===320)await root.screenshot({path:path.join(base,'lunaria-mobile-preview.png')});
    }
    const assets=await run(a=>a.assets());
    for(const [name,asset] of Object.entries(assets)){
      const target=path.join(base,'assets',name),data=Buffer.from(asset.png.split(',')[1],'base64');
      if(name==='star-bullet-atlas-32px.png'&&process.argv.includes('--export-new-art'))fs.writeFileSync(target,data);
      check(fs.readFileSync(target).equals(data),'Source art matches '+name);
    }
    check(errors.length===0,'No JavaScript errors');
    const sourceSha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(base,'lunaria-dream-barrage.html'))).digest('hex');
    const report={status:'passed',duration:128,sceneCount:16,assertionCount:assertions.length,profiles,limitChecks,rotationChecks,petalChecks,sampledBrowserFPS:fps,sourceSha256,layouts,runtimeErrors:errors,boardTested:false};
    fs.writeFileSync(path.join(base,'preview-checks.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify({...report,layouts:undefined},null,2));
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});

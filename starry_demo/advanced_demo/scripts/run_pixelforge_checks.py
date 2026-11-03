"""Native differential game simulation, PixelForge assets/ELF/UI checks."""
from pathlib import Path
import hashlib,json,math,re,struct,subprocess,sys,tempfile,tkinter as tk
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_debug_bridge import LunariaBridge,read_assets
from lunaria_debug_window import LunariaWindow
from run_game_debug_checks import FakeBridge
from unittest.mock import patch
from game_debug_bridge import APB,DebugBridge
source=r'''#include "lunaria_render.h"
#include <stdio.h>
#include <stdlib.h>
static lunaria_t g;
static unsigned h=2166136261u;
static void add(unsigned v){h=(h^v)*16777619u;}
static unsigned emit(void *context,const ln_command_t *c){fwrite(c,sizeof(*c),1,(FILE*)context);return 0;}
static void picture(FILE *f,const char *name){
 char label[32]={0};unsigned zero=0;long pos=ftell(f);ln_render_stats_t stats;
 snprintf(label,32,"%s",name);fwrite(label,32,1,f);fwrite(&zero,4,1,f);
 ln_render(&g,255,emit,f,&stats);fseek(f,pos+32,SEEK_SET);fwrite(&stats.commands,4,1,f);fseek(f,0,SEEK_END);
}
#if PIXELFORGE
static unsigned discard(void *context,const ln_command_t *c){(void)context;(void)c;return 0;}
static unsigned health_bar;
static unsigned inspect_health(void *context,const ln_command_t *c){
 (void)context;
 if(c->op==0 && c->color==0x00edbadf && c->x==LN_VIEW_X+420 && c->y==LN_VIEW_Y+52)health_bar=c->w;
 return 0;
}
static unsigned bar_width(void){ln_render_stats_t stats;health_bar=0;ln_render(&g,255,inspect_health,0,&stats);return health_bar;}
static int check_health_transitions(void){
 unsigned phase,tick;
 for(phase=0;phase<7;phase++){
  unsigned expected=(7-phase)*LN_PHASE_HP,width=196*expected/(8*LN_PHASE_HP);
  ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=(unsigned char)phase;g.hp=1;g.invincible=1;
  ln_hit(&g,g.boss_x,g.boss_y);
  if(g.state!=LN_WARNING || g.phase!=phase+1)return 14;
  if(ln_boss_hp(&g)!=expected || bar_width()!=width){
   fprintf(stderr,"FAIL HP transition %u: expected %u/%u pixels, got %u/%u\n",phase,expected,width,ln_boss_hp(&g),bar_width());return 15;
  }
  for(tick=0;tick<63;tick++){
   if(g.state!=LN_WARNING || ln_boss_hp(&g)!=expected || bar_width()!=width)return 16;
   ln_hit(&g,g.boss_x,g.boss_y); /* Warning must not take damage. */
   if(g.hp!=0)return 17;
   ln_step(&g,0,g.last_ms+16);
  }
  if(g.state!=LN_FIGHT || g.hp!=LN_PHASE_HP || ln_boss_hp(&g)!=expected || bar_width()!=width)return 18;
  ln_hit(&g,g.boss_x,g.boss_y);
  if(g.hp!=LN_PHASE_HP-1 || ln_boss_hp(&g)!=expected-1)return 19;
  width=196*(expected-1)/(8*LN_PHASE_HP);if(bar_width()!=(width?width:1))return 20;
 }
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=7;g.hp=1;
 if(bar_width()!=1)return 21;
 ln_hit(&g,g.boss_x,g.boss_y);
 if(g.state!=LN_DEFEAT || ln_boss_hp(&g)!=0 || bar_width()!=0)return 22;
 return 0;
}
#endif
int main(int argc,char **argv){
 unsigned p,spin,inv,k,i,limits[]={64,256,640,LN_CAPACITY};
#if PIXELFORGE
 {ln_render_stats_t empty,live;unsigned pixels=0;
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=7;g.boss_x=320;g.boss_y=240;
 ln_render(&g,255,discard,0,&empty);
 for(i=0;i<16;i++){
  g.lasers[0].active=1;g.lasers[0].x=320;g.lasers[0].y=240;
  g.lasers[0].age=900;g.lasers[0].angle=(unsigned short)(i*4096);
  ln_render(&g,255,discard,0,&live);
  pixels+=live.sprite_pixels-empty.sprite_pixels;
  fprintf(stderr,"BEAM %u commands=%u pixels=%u\n",i,live.commands-empty.commands,live.sprite_pixels-empty.sprite_pixels);
 }
 fprintf(stderr,"BEAM total pixels=%u\n",pixels);
 if(pixels>220000){fprintf(stderr,"FAIL excessive overlapping beam work\n");return 23;}
 }
 {int result=check_health_transitions();if(result)return result;}
#endif
 for(k=0;k<4;k++)for(inv=0;inv<2;inv++)for(spin=0;spin<2;spin++)for(p=0;p<8;p++){
 h=2166136261u;ln_reset(&g,0);ln_configure(&g,limits[k],spin);ln_begin(&g);
 g.state=LN_FIGHT;g.phase=(unsigned char)p;g.invincible=(unsigned char)inv;
 for(i=0;i<1200;i++){
   unsigned j,n=0;
   unsigned keys=(i%120<60?UART_KEY_LEFT:UART_KEY_RIGHT) | (i%500<250?UART_KEY_FIRE:0);
   ln_step(&g,(unsigned char)keys,g.last_ms+16);
   for(j=0;j<LN_CAPACITY;j++){
     ln_bullet_t *b=&g.bullets[j];
     if(!b->active)continue;
     n++;add(j);add(b->x);add(b->y);add(b->vx);add(b->ox);add(b->oy);
     add(b->angle);add(b->age);add(b->life);add(b->kind);add(b->shape);add(b->color);
     if(b->kind){add(b->ux);add(b->uy);}
     if(b->age>1000 || b->kind>10 || b->shape>4 || b->color>3)return 2;
   }
   if(n!=ln_active(&g) || n>g.bullet_limit)return 3;
   add(g.state);add(g.phase);add(g.player_x);add(g.player_y);add(g.hp);
   add(g.score);add(g.lives);add(g.emissions);add(g.deferred_emissions);add(g.event);
   for(j=0;j<LN_SHOTS;j++){add(g.shots[j].active);if(g.shots[j].active){add(g.shots[j].x);add(g.shots[j].y);}}
 }
 printf("%u %u %u %u %08x\n",limits[k],spin,p,inv,h);
 }
#if PIXELFORGE
 /* Overlapping lifetimes: still frozen after the first beam expires. */
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=6;g.invincible=1;
 g.next_emit_ms=100000;g.boss_x=300;g.boss_y=130;
 g.lasers[0].active=1;g.lasers[0].age=0;
 g.lasers[1].active=1;g.lasers[1].age=400;
 for(i=0;i<112;i++){
   int old_x=g.boss_x,old_y=g.boss_y,player=g.player_x;
   ln_step(&g,UART_KEY_RIGHT,g.last_ms+16);
   if(g.boss_x!=old_x || g.boss_y!=old_y)return 5;
   if(i==0 && g.player_x==player)return 6;
 }
 if(!g.lasers[0].active || g.lasers[1].active)return 7;
 ln_step(&g,0,g.last_ms+16);
 if(g.lasers[0].active || g.boss_frozen_ms!=1792)return 8;
 /* Actual emitted beams pin the Boss from their birth position. */
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=7;g.event=4;g.invincible=1;
 ln_step(&g,0,g.last_ms+16);
 if(!g.lasers[0].active)return 9;
 {int x=g.boss_x,y=g.boss_y;g.next_emit_ms=100000;
  for(i=0;i<112;i++){ln_step(&g,0,g.last_ms+16);if(g.boss_x!=x || g.boss_y!=y)return 10;}
  ln_step(&g,0,g.last_ms+16);
  if(g.lasers[0].active || abs(g.boss_x-x)>2 || abs(g.boss_y-y)>2)return 11;
  for(i=0;i<20;i++)ln_step(&g,0,g.last_ms+16);
  if(g.boss_x==x && g.boss_y==y)return 12;
 }
 for(k=0;k<4;k++){
   ln_bullet_t *b;unsigned shape=k==3?3:k==2?1:0;
   ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.next_emit_ms=100000;
   b=&g.bullets[0];b->active=1;g.active_count=1;b->kind=3;b->shape=shape;b->life=1000;
   b->ox=(short)(g.player_x/LN_Q+(k==0?4:5));b->oy=(short)(g.player_y/LN_Q);
   ln_step(&g,0,g.last_ms+16);
   if(g.lives != (k==1?3:2))return 13;
 }
#endif
 if(argc==2){FILE *f=fopen(argv[1],"wb");if(!f)return 4;
 ln_reset(&g,0);picture(f,"PixelForge-title");ln_configure(&g,LN_CAPACITY,0);ln_begin(&g);g.invincible=1;
 for(i=0;i<450;i++)ln_step(&g,0,g.last_ms+16);
 picture(f,"PixelForge-battle");
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=3;g.invincible=1;
 for(i=0;i<100;i++)ln_step(&g,0,g.last_ms+16);picture(f,"PixelForge-rose");
 ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=7;g.event=4;g.invincible=1;
 for(i=0;i<50;i++)ln_step(&g,0,g.last_ms+16);picture(f,"PixelForge-laser");
 g.state=LN_VICTORY;g.state_ms=4000;picture(f,"PixelForge-results");
#if PIXELFORGE
 for(i=0;i<16;i++){
  char name[32];ln_reset(&g,0);ln_begin(&g);g.state=LN_FIGHT;g.phase=7;
  g.lasers[0].active=1;g.lasers[0].x=320;g.lasers[0].y=240;
  g.lasers[0].age=900;g.lasers[0].angle=(unsigned short)(i*4096);
  snprintf(name,32,"PixelForge-beam-%u",i);picture(f,name);
 }
#endif
 fclose(f);}
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='pixelforge-check-') as folder:
 temp=Path(folder);(temp/'probe.c').write_text(source,encoding='utf8')
 outputs=[]
 for variant,defines in (('legacy',[]),('pixel640',['/DPIXELFORGE=1','/DLN_CAPACITY=640']),('pixel1024',['/DPIXELFORGE=1'])):
  exe=temp/(variant+'.exe')
  subprocess.run(['cl','/nologo','/TC','/W4','/WX','/O2','/I'+str(ROOT/'software/lunaria'),*defines,str(temp/'probe.c'),str(ROOT/'software/lunaria/lunaria.c'),str(ROOT/'software/lunaria/lunaria_render.c'),'/Fe:'+str(exe)],cwd=temp,check=True)
  result=subprocess.run([str(exe),str(temp/(variant+'.bin'))],capture_output=True,text=True)
  print(result.stderr,end='')
  result.check_returncode()
  outputs.append(result.stdout)
 from run_lunaria_checks import rasterize
 import run_lunaria_checks as rendering
 atlas=Image.frombytes('RGBA',(640,480),(ROOT/'delivery/PixelForge/atlas.argb').read_bytes(),'raw','BGRA')
 rasterize(temp/'pixel1024.bin',contact_sheets=False,atlas_override=atlas)
 comparable=lambda text:[line for line in text.splitlines() if int(line.split()[2])<6 and line.split()[3]=='1']
 assert comparable(outputs[0])==comparable(outputs[1]), 'Unrelated gameplay changed'
 print('PASS 57600 non-laser invincible ticks match legacy; intentional laser/round-hit changes separately verified')
 print('PASS capacity1024: 153600 ticks; scanned active count equals cached count, bounded life/state')
 # Exercise the actual private beam path in isolation, at all 256 LUT angles.
 probe='#include "'+(ROOT/'software/lunaria/lunaria_render.c').as_posix()+'"\n'+r'''
#include <stdio.h>
static unsigned output(void *context,const ln_command_t *c){fwrite(c,sizeof(*c),1,(FILE*)context);return 0;}
int main(int argc,char **argv){
 unsigned i;FILE *f;ln_command_t end={0};ln_render_stats_t stats={0};renderer_t r;
 ln_laser_t l={320,240,0,900,1};(void)argc;f=fopen(argv[1],"wb");if(!f)return 1;
 r.submit=output;r.context=f;r.stats=&stats;r.error=0;
 for(i=0;i<256;i++){l.angle=(unsigned short)(i*256);laser(&r,&l);fwrite(&end,sizeof(end),1,f);}
 fclose(f);return 0;
}
'''
 (temp/'beam.c').write_text(probe,encoding='utf8')
 traces={}
 for variant,define in (('old','/DPIXELFORGE=0'),('new','/DPIXELFORGE=1')):
  exe=temp/(variant+'-beam.exe');binary=temp/(variant+'-beam.bin')
  subprocess.run(['cl','/nologo','/TC','/W4','/WX','/O2','/D_CRT_SECURE_NO_WARNINGS',define,str(temp/'beam.c'),str(ROOT/'software/lunaria/lunaria.c'),'/Fe:'+str(exe)],cwd=temp,check=True)
  subprocess.run([str(exe),str(binary)],check=True)
  groups=[];commands=[]
  for command in struct.iter_unpack('<8I',binary.read_bytes()):
   if command[6]:commands.append(command)
   else:groups.append(commands);commands=[]
  assert len(groups)==256
  traces[variant]=groups
 from PIL import ImageDraw
 for angle,commands in enumerate(traces['new']):
  mask=Image.new('L',(640,480));beam_image=Image.new('RGBA',(640,480))
  for number,(op,src,stride,x,y,w,h,color) in enumerate(commands):
   assert op==3 and stride==2560 and src%16==0 and w%4==0
   x-=640;y-=300;p=(src-0x01384000)//4;sx=p%640;sy=p//640
   assert 0<=sx and sx+w<=640 and 0<=sy and sy+h<=480
   if number: # The round muzzle intentionally joins the first body strips.
    region=mask.crop((x,y,x+w,y+h));assert region.getbbox() is None,'Beam slices overlap'
    ImageDraw.Draw(mask).rectangle((x,y,x+w-1,y+h-1),fill=255)
   beam_image.alpha_composite(atlas.crop((sx,sy,sx+w,sy+h)),(x,y))
  ux=round(math.cos(angle*math.tau/256)*16384)/16384
  uy=round(math.sin(angle*math.tau/256)*16384)/16384
  # A small clear gap outside the 51px Boss ring, then a coloured round rim.
  x=round(320+ux*52);y=round(240+uy*52)
  assert beam_image.getpixel((x,y))[3]==0,(angle,'muzzle touches Boss')
  x=round(320+ux*60);y=round(240+uy*60)
  red,green,blue,alpha=beam_image.getpixel((x,y))
  assert 0<alpha<255 and red-green>70,(angle,'muzzle halo lost')
  for side in (-1,1):
   x=round(320+ux*62-uy*14*side);y=round(240+uy*62+ux*14*side)
   assert beam_image.getpixel((x,y))[3]==0,(angle,'flat muzzle corner')
  for distance in range(78,145):
   x=round(320+ux*distance);y=round(240+uy*distance)
   red,green,blue,alpha=beam_image.getpixel((x,y))
   assert alpha==255 and min(red,green,blue)>=220,(angle,distance,'centre seam')
  for side in (-1,1):
   x=round(320+ux*100-uy*13*side);y=round(240+uy*100+ux*13*side)
   red,green,blue,alpha=beam_image.getpixel((x,y))
   assert 0<alpha<255 and red-green>70,(angle,side,'halo lost')
 old_pixels=sum(c[5]*c[6] for commands in traces['old'] for c in commands)
 new_pixels=sum(c[5]*c[6] for commands in traces['new'] for c in commands)
 assert new_pixels<old_pixels*.5
 print(f'PASS 256 beam directions: continuous core, coloured sides, no overlap; pixels {old_pixels} -> {new_pixels}',flush=True)
 # Replay real renderer geometries through unchanged v13 RTL with stalls.
 # Relocate destinations to a small framebuffer, preserving x alignment,
 # source, dimensions and order. Check every pixel against reference blending.
 fixture=(ROOT/'sim/tb_alpha_stream_cache.v').read_text(encoding='utf8')
 fixture=fixture.replace('FRAME_WORDS=256*48','FRAME_WORDS=256*64').replace('.FRAME_HEIGHT(48)','.FRAME_HEIGHT(64)')
 fixture=fixture[:fixture.index('initial begin\n    for(i=0;')]
 fixture+='integer total;\ninitial begin\nfor(i=0;i<FRAME_WORDS;i=i+1)begin memory[i]=32\'ha52b4671;expected[i]=memory[i];end\n'
 for variant in ('old','new'):
  for angle in (0,32,48,64):
   fixture+='@(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;\n'
   for run in ('cold','warm'):
    fixture+='total=0;\n'
    for op,src,stride,x,y,w,h,color in traces[variant][angle]:
     fixture+=f"command(32'h{src:08x},2560,{32+x%4},4,{w},{h},255,0);total=total+elapsed;\n"
    fixture+=f'$display("BEAM_RTL {variant} {angle} {run} %0d",total);\n'
 fixture+='$finish;end\ninitial begin #100000000;$fatal(1,"timeout");end\nendmodule\n'
 (temp/'beam.v').write_text(fixture,encoding='utf8');binary=temp/'beam.vvp'
 subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_alpha_stream_cache','-Ptb_alpha_stream_cache.PIXEL_X=1','-Ptb_alpha_stream_cache.SOURCE_LATENCY=20','-o',str(binary),str(temp/'beam.v'),str(ROOT/'rtl/accelerator/alpha_blit_engine.v'),str(ROOT/'rtl/accelerator/alpha_pixel_pipeline.v')],check=True)
 result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True)
 print(result.stdout,end='');result.check_returncode()
 cycles={}
 for variant,angle,run,count in re.findall(r'BEAM_RTL (old|new) (\d+) (cold|warm) (\d+)',result.stdout):cycles[(variant,int(angle),run)]=int(count)
 assert len(cycles)==16
 for angle in (0,32,48,64):
  for run in ('cold','warm'):assert cycles['new',angle,run]<cycles['old',angle,run],(angle,run,'RTL regression')
 laser_report=dict(angles=256,old_pixels=old_pixels,new_pixels=new_pixels,rtl_cycles={f'{v}-{a}-{r}':n for (v,a,r),n in cycles.items()},rtl_board_equivalent=False)
out=ROOT/'delivery/PixelForge'
bridge=LunariaBridge(out/'PixelForge.elf',assets=out/'assets.json')
assert bridge.image.symbol_u32('g_pixelforge_available')==1
assert bridge.image.symbol_u32('g_lunaria_settings',10)==1024
assert bridge.image.symbol_u32('g_lunaria_required_hardware')==0xD0000
assert bridge.asset_hashes==[h for _,h in read_assets(out/'assets.json')]
old=Image.frombytes('RGBA',(640,480),(ROOT/'design/game_assets/atlas.argb').read_bytes(),'raw','BGRA')
new=Image.frombytes('RGBA',(640,480),(out/'atlas.argb').read_bytes(),'raw','BGRA')
# Reconstruct the original with ONLY authorised changes; all other pixels match.
patched=old.copy()
rects=[(0,448,640,480),(576,64,608,128),(608,64,640,96),(448,64,512,80),(448,160,640,224),(576,128,632,160),(512,344,640,368)]
for row in range(4):
 for col in (0,2):rects.append((448+16*col,16*row,464+16*col,16*row+16))
for rect in rects:patched.paste(new.crop(rect),rect[:2])
assert patched.tobytes()==new.tobytes(), 'Unrelated sprite modified'
for row in range(4):
 tile=new.crop((448,row*16,464,row*16+16))
 assert tile.size==(16,16) and tile.getchannel('A').getbbox()==(3,3,13,13)
 pixels=[tile.getpixel((x,y)) for y in range(16) for x in range(16)]
 high=sum(a==255 and min(r,g,b)>=230 for r,g,b,a in pixels)
 assert high==16
 assert sum(0<a<255 for r,g,b,a in pixels)<=28
 assert max(a for r,g,b,a in pixels if 0<a<255)==80
for frame in range(8):
 target=(448+frame*32,448) if frame<6 else (576,64+(frame-6)*32)
 actual=new.crop((*target,target[0]+32,target[1]+32))
 expected=old.crop((448+frame%4*32,160+frame//4*32,480+frame%4*32,192+frame//4*32))
 assert actual.tobytes()==expected.tobytes(), 'Hit effect appearance changed'
# Slope zero: white axis, saturated shoulder, thicker translucent edge.
beam=new.crop((576,128,632,136))
assert beam.getpixel((27,4))==(255,242,252,255)
assert beam.getpixel((19,4))[1]<180 and beam.getpixel((19,4))[3]==255
assert 0<beam.getpixel((14,4))[3]<255 and beam.getpixel((10,4))[3]==0
root=tk.Tk();root.withdraw()
try:
 window=LunariaWindow(root,out/'PixelForge.elf',out/'assets.json',pixelforge=True)
 root.update_idletasks()
 assert root.title()=='PixelForge' and window.maximum_bullets==1024 and window.bridge is None
finally:root.destroy()
import run_lunaria_loader_checks as checks
with patch.object(checks,'DEFAULT_ELF',out/'PixelForge.elf'):
 fake,address=checks.Checks().settings_fake()
 assert LunariaBridge.configure(fake,1024)==1
 fake,address=checks.Checks().settings_fake()
 try:LunariaBridge.configure(fake,1025)
 except ValueError:pass
 else:raise AssertionError('Over-capacity setting accepted')
 assert not fake.writes
fake=FakeBridge(out/'PixelForge.elf');fake.memory[APB+4]=0xD0000;fake.memory[APB+0x40]=0x7FFB
fake.load()
assert any(c.startswith('load_image ') for c in fake.calls)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report=dict(status='passed',board_tested=False,elf_sha256=sha(out/'PixelForge.elf'),bit_sha256=sha(out/'ti60f225_oob.bit'),differential_ticks=57600,laser_freeze_and_collision=True,health_bar_transitions=True,laser_render=laser_report,capacity_ticks=153600,capacity=1024,bullet_size=16)
(out/'checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
manifest_path=out/'manifest.json'
manifest=json.loads(manifest_path.read_text(encoding='utf8'))
manifest['artifacts']['checks.json']=sha(out/'checks.json')
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
print('PASS PixelForge 16px round/beam artwork and protected cone/player assets, renamed title, GUI, capacity mailbox and v13 loader')

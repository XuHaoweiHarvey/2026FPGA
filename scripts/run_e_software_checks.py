"""Execute the compiled E RV32 ELF against an MMIO behavioral model, no board.

Requires unicorn==2.1.4 (can be installed in a temporary --unicorn-path).
This tests software, NOT DDR timing, HDL, Sapphire debug, or HDMI pixels.
"""
import argparse
from array import array
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--unicorn-path',type=Path)
parser.add_argument('--toolchain-prefix',type=Path,
                    help='GNU cross-tool prefix ending in a hyphen; default uses the formal IDE')
parser.add_argument('--elf',type=Path,default=ROOT/'software/apb_reg_test/build/apb_reg_test.elf',
                    help='Freshly built default DEMO_MODE=0 ELF to check')
args=parser.parse_args()
if args.unicorn_path:
    sys.path.insert(0,str(args.unicorn_path))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32,UC_HOOK_MEM_READ,UC_HOOK_MEM_WRITE,UC_HOOK_CODE

TOOL_PREFIX=str(args.toolchain_prefix or
                Path('D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-'))
APB=0xF8100000
RAM=0xF9000000
MASK=0xffffffff
temp=Path(tempfile.mkdtemp(prefix='fpga-e-software-'))
print('Artifacts:',temp,flush=True)

def build(name,defines):
    out=temp/name
    command=[sys.executable,str(ROOT/'scripts/build_apb_software.py'),'--output',str(out)]
    if args.toolchain_prefix:
        command.extend(['--toolchain-prefix',str(args.toolchain_prefix)])
    for d in defines:
        command.extend(['--define',d])
    run=subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
    (temp/(name+'-build.log')).write_text(run.stdout+run.stderr,encoding='utf8')
    assert run.returncode==0,run.stdout+run.stderr
    return out/'apb_reg_test.elf'

def fields(path,typename):
    # Interpret the debugger-visible C structures from their definitions.
    source=path.read_text(encoding='utf8')
    source=re.sub(r'/\*.*?\*/','',source,flags=re.S)
    body=re.search(r'typedef struct\s*\{([^{}]+)\}\s*'+typename+r';',source)[1]
    names=[]
    for declaration in body.split(';'):
        if 'uint32_t' in declaration:
            names.extend(x.strip() for x in declaration.split('uint32_t')[1].split(','))
    return names

result_fields=fields(ROOT/'software/apb_reg_test/main.c','demo_result_t')
diag_fields=fields(ROOT/'software/apb_reg_test/accel_api.h','accel_diagnostics_t')

class Machine:
    def __init__(self,elf,case='normal',limit=2,mode=None,hold=0,target=2,wrap=False):
        self.case=case;self.limit=limit;self.mode=mode;self.hold=hold;self.target=target
        self.uc=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32)
        self.uc.mem_map(RAM,0x10000);self.uc.mem_map(APB,0x10000)
        data=elf.read_bytes()
        phoff=struct.unpack_from('<I',data,28)[0]
        phsize,phnum=struct.unpack_from('<HH',data,42)
        for i in range(phnum):
            typ,off,va,pa,filesz,memsz,flags,align=struct.unpack_from('<8I',data,phoff+i*phsize)
            if typ==1:
                assert RAM<=va and va+memsz<=RAM+0xFC00
                self.uc.mem_write(va,data[off:off+filesz])
        symbols=subprocess.check_output([TOOL_PREFIX+'nm.exe','-n',str(elf)],text=True)
        self.symbols={parts[-1]:int(parts[0],16) for line in symbols.splitlines()
                      if len(parts:=line.split())>=3}
        self.entry=struct.unpack_from('<I',data,24)[0]
        self.reg={i:0 for i in range(0,0xc8,4)}
        self.reg.update({0:0x4143434C,4:0x50000,0xc:0x1a,0x2c:0,0x30:0x800000,
                         0x34:7680,0x38:1920,0x3c:1080,0x40:0xfb,0x44:518400,
                         0x48:4050,0x4c:4050,0x50:4050,0x54:518400,0x58:1,
                         0x5c:0xfffffffc if wrap else 37,0x64:0x12,
                         0x80:0xfffffffe if wrap else 11,0x84:3,0x88:0x30,
                         0xa4:7,0xac:512,0xb4:128,0xb8:0x02000180})
        self.remaining=0;self.pending=0;self.commands=[];self.ops=[];self.writes=[]
        self.front=0;self.swaps=0;self.stopped=False;self.presented=0
        self.recorded_commands=[];self.recorded_ops=[];self.startup_command=False;self.startup_swap=False
        self.pixels=None;self.pixel_checks=0
        if case=='init_timeout': self.reg[0xc]=0
        if case=='bad_id': self.reg[0]=0
        if case=='bad_version': self.reg[4]=0x40000
        if case=='missing_color_key': self.reg[0x40]=0x7b
        if case=='policy_disabled': self.reg[0x88]=0
        if case=='resume_busy':
            self.reg[0xc]=0x19;self.reg[0x64]|=0x20
            self.remaining=20;self.startup_command=True
        if case=='resume_swap':
            self.reg[0x64]|=4;self.pending=20;self.startup_swap=True
        self.uc.hook_add(UC_HOOK_MEM_READ,self.read,begin=APB,end=APB+0xffff)
        self.uc.hook_add(UC_HOOK_MEM_WRITE,self.write,begin=APB,end=APB+0xffff)
        for symbol,handler in [('main',self.main),('scene_begin',self.scene_begin),
                               ('back_ready',self.back_ready),('frame_presented',self.frame_presented),
                               ('apb_test_done',self.done)]:
            address=self.symbols[symbol]
            self.uc.hook_add(UC_HOOK_CODE,handler,begin=address,end=address)

    def put(self,name,value): self.uc.mem_write(self.symbols[name],struct.pack('<I',value))
    def main(self,uc,address,size,data):
        # Keep the ELF's compiled default unless a test explicitly selects a mode.
        if self.mode is None:
            self.mode=struct.unpack('<I',uc.mem_read(self.symbols['g_demo_mode'],4))[0]
        for name,value in [('g_frame_limit',self.limit),('g_hold_frames',self.hold),
                           ('g_demo_mode',self.mode),('g_validation_target',self.target)]:
            self.put(name,value)
        if self.mode==3:
            self.pixels=[array('I',[0])*(1920*1080) for _ in range(2)]

    def advance(self):
        if self.remaining and self.case!='done_timeout':
            self.remaining-=1
            if not self.remaining:
                self.reg[0xc]=0x1a;self.reg[0x64]&=~0x20
                if self.case=='b_error': self.reg[0x24]=0x12;self.reg[0xc]|=4
                if self.case=='reader_error': self.reg[0x24]=0x2003;self.reg[0x78]=0x2003
                if not self.startup_command and self.ops[-1][0]==1:
                    if self.case=='blit_read_error': self.reg[0x24]=0x22;self.reg[0xc]|=4
                    if self.case=='blit_write_error': self.reg[0x24]=0x23;self.reg[0xc]|=4
                if not self.startup_command and self.ops[-1][0]==2:
                    if self.case=='color_key_read_error': self.reg[0x24]=0x22;self.reg[0xc]|=4
                    if self.case=='color_key_write_error': self.reg[0x24]=0x23;self.reg[0xc]|=4
                if self.case=='underflow': self.reg[0xa4]+=1
                if self.case=='missed': self.reg[0x84]+=1
                self.reg[0x8c]=(self.reg[0x8c]+10000)&MASK
                self.reg[0x90]=(self.reg[0x90]+32)&MASK
                if not self.startup_command:
                    if self.pixels is not None and self.reg[0x24]==0:
                        self.apply_pixels()
                    self.recorded_commands.append(self.commands[-1])
                    self.recorded_ops.append(self.ops[-1])
                self.startup_command=False
        if self.pending and self.case!='swap_timeout':
            self.pending-=1
            if not self.pending:
                assert not self.remaining
                self.front^=1
                if not self.startup_swap: self.swaps+=1
                self.startup_swap=False
                self.reg[0x2c]=self.front*0x800000;self.reg[0x30]=(1-self.front)*0x800000
                self.reg[0x68]=self.reg[0x2c]
                self.reg[0x64]=self.front|((1-self.front)<<1)|0x18
                self.reg[0x80]=(self.reg[0x80]+1)&MASK

    def read(self,uc,access,address,size,value,data):
        offset=address-APB
        assert size==4 and offset in self.reg,f'invalid APB read {offset:#x}'
        self.advance()
        if offset==0x7c and not(self.case=='hold_timeout' and self.swaps):
            self.reg[offset]=(self.reg[offset]+1)&MASK
            self.reg[0xa8]=(self.reg[0xa8]+1)&MASK
        uc.mem_write(address,struct.pack('<I',self.reg[offset]))

    def write(self,uc,access,address,size,value,data):
        offset=address-APB
        assert size==4 and offset in (8,0x10,0x14,0x18,0x1c,0x20,0x28,0x60,0xbc,0xc0,0xc4)
        self.advance();self.writes.append((offset,value))
        if offset==8:
            assert value==1,'software must never reset/clear an in-flight transaction'
            assert not self.remaining and not(self.reg[0x64]&0x24)
            op=self.reg[0xbc]
            assert op in (0,1,2),'software must explicitly select a supported operation'
            command=tuple(self.reg[o] for o in (0x10,0x14,0x18,0x1c,0x20))
            self.commands.append((self.reg[0x30],*command))
            self.ops.append((op,self.reg[0xc0],self.reg[0xc4]))
            if self.case=='ack_timeout': return
            self.reg[0x5c]=(self.reg[0x5c]+1)&MASK
            x,y,w,h,color=command
            if not(w and h and x<1920 and y<1080 and x+w<=1920 and y+h<=1080):
                self.reg[0x24]=0x11;self.reg[0xc]=0x1e;return
            if op==0:
                assert self.ops[-1][1:]==(0,0),'FILL must clear stale BLIT source parameters'
            else:
                assert self.ops[-1][1:]==(self.front*0x800000,7680)
                assert (x%4)==0 and (w%4)==0
                if self.mode==2:
                    assert (x,y,w,h,color)==(64,64,32,32,0) and op==1
                else:
                    assert self.mode==3
                    assert (x,y,w,h,color)==((384,384,128,128,0) if op==1 else (1152,384,128,128,0xff00ff))
            self.remaining=12;self.reg[0xc]=0x19;self.reg[0x64]|=0x20
        elif offset==0x60:
            assert value==3 and not self.remaining and not self.pending
            self.reg[0x64]=(self.reg[0x64]&~8)|4;self.pending=8
        else: self.reg[offset]=value

    def scene_begin(self,uc,address,size,data):
        if self.case=='rejected': self.reg[0x64]|=4

    def apply_pixels(self):
        # Execute completed commands only in this software/MMIO model. This is
        # not an HDL simulation; the separate shared-DDR test covers real RTL.
        base,x,y,w,h,color=self.commands[-1]
        op,source,stride=self.ops[-1]
        target=self.pixels[base//0x800000]
        if op==0:
            row=array('I',[color])*w
            for yy in range(y,y+h): target[yy*1920+x:yy*1920+x+w]=row
        else:
            origin=self.pixels[self.front]
            offset=(source-self.front*0x800000)//4
            for yy in range(h):
                src=offset+yy*(stride//4);dst=(y+yy)*1920+x
                if op==1: target[dst:dst+w]=origin[src:src+w]
                else:
                    for xx in range(w):
                        pixel=origin[src+xx]
                        if pixel&0xffffff!=color: target[dst+xx]=pixel

    def check_key_pixels(self,source_only):
        def sprite(xx,yy):
            value=0x80ff00ff
            if ((32<=xx<96 and 24<=yy<96) or (60<=xx<68 and 8<=yy<24) or
                (96<=yy<120 and (32<=xx<52 or 76<=xx<96))): value=0xe8e8f0
            if 40<=yy<52 and (40<=xx<52 or 76<=xx<88): value=0x203040
            if 48<=xx<80 and 72<=yy<80: value=0x00d0d0
            return value
        expected_source=array('I',[0])*(1920*1080)
        for yy in range(128):
            for xx in range(128): expected_source[yy*1920+xx]=sprite(xx,yy)
        if source_only:
            assert self.pixels[1-self.front]==expected_source,'software built an incorrect source sprite'
        else:
            assert self.pixels[self.front]==expected_source,'copy modified the source Front'
            expected=array('I',[0x182838])*(1920*448)+array('I',[0x285840])*(1920*632)
            for yy in range(128):
                for xx in range(128):
                    pixel=sprite(xx,yy)
                    expected[(384+yy)*1920+384+xx]=pixel
                    if pixel&0xffffff!=0xff00ff:
                        expected[(384+yy)*1920+1152+xx]=pixel
            assert self.pixels[1-self.front]==expected,'software color-key scene overwrote background or used wrong geometry'
        self.pixel_checks+=1

    def back_ready(self,uc,address,size,data):
        assert self.reg[0x2c]==self.front*0x800000 and self.reg[0x68]==self.reg[0x2c]
        assert len(self.recorded_commands)==len(self.commands)
        if self.mode==3:
            count=len(self.recorded_commands)-self.presented*13
            assert count in (9,13),'key scene must build/publish source, then prepare/copy Back'
            group=9 if count==9 else 4
            recent=self.recorded_commands[-group:];recent_ops=self.recorded_ops[-group:]
            assert all(c[0]==self.reg[0x30] for c in recent)
            assert [op[0] for op in recent_ops]==([0]*9 if group==9 else [0,0,1,2])
            self.check_key_pixels(source_only=group==9)
        elif self.mode==2:
            count=len(self.recorded_commands)-self.presented*7
            assert count in (5,7),'BLIT scene must complete source build, then clear/copy'
            group=5 if count==5 else 2
            recent=self.recorded_commands[-group:]
            recent_ops=self.recorded_ops[-group:]
            assert all(c[0]==self.reg[0x30] for c in recent)
            if group==5:
                assert all(op[0]==0 for op in recent_ops)
                assert [c[1:] for c in recent]==[
                    (0,0,1920,1080,0),(0,0,16,16,0xff0000),
                    (16,0,16,16,0x00ff00),(0,16,16,16,0x0000ff),
                    (16,16,16,16,0xffff00)]
            else:
                assert [op[0] for op in recent_ops]==[0,1]
                assert [c[1:] for c in recent]==[(0,0,1920,1080,0),(64,64,32,32,0)]
                assert recent_ops[-1]==(1,self.front*0x800000,7680)
        else:
            assert all(c[0]==self.reg[0x30] for c in self.recorded_commands[-(2 if self.mode==1 else 4):])

    def frame_presented(self,uc,address,size,data):
        self.presented+=1
        assert self.swaps==self.presented*(2 if self.mode in (2,3) else 1)
        if self.limit==0 and self.presented==1000:
            # Prove no built-in finite limit: the milestone was reached and
            # the default continuous configuration remains enabled.
            self.stopped=True;uc.emu_stop()

    def done(self,uc,address,size,data): self.stopped=True;uc.emu_stop()

    def run(self):
        self.uc.emu_start(self.entry,RAM+0x10000,count=80000000)
        assert self.stopped,'software exceeded instruction budget'
        words=struct.unpack('<'+'I'*(len(result_fields)+len(diag_fields)),
                            self.uc.mem_read(self.symbols['g_apb_test_result'],4*(len(result_fields)+len(diag_fields))))
        self.result=dict(zip(result_fields,words))
        self.diag=dict(zip(diag_fields,words[len(result_fields):]))
        return self

def good(machine):
    r=machine.result
    assert r['pass']==1 and r['errors']==r['underflow_delta']==r['missed_delta']==0,r
    assert r['iterations']==machine.presented
    assert r['swaps_completed']==r['swaps_requested']==machine.swaps
    assert r['commands_issued']==r['commands_completed']==len(machine.commands)
    assert r['command_delta']==r['commands_issued'] and r['swap_delta']==machine.swaps
    assert r['underflow_baseline']==7 and r['missed_baseline']==3
    assert machine.diag['error_code']==machine.diag['reader_error']==0
    assert machine.diag['writer_throttle_cycles']>0

def scene_commands(machine,test=(240,180,360,240,0xff0000)):
    for index in range(machine.presented):
        count=2 if machine.mode==1 else 4
        actual=[c[1:] for c in machine.commands[index*count:(index+1)*count]]
        if machine.mode==1: expected=[(0,0,1920,1080,0),test]
        elif index%2==0:
            expected=[(0,0,1920,1080,0x102060),test,(760,240,300,300,0x00ff00),(1260,590,450,280,0x0000ff)]
        else:
            expected=[(0,0,1920,1080,0x1c140c),(140,630,470,170,0xffff00),
                      (960,130,220,410,0x00ffff),(1300,500,370,330,0xff00ff)]
        assert actual==expected,(index,actual,expected)

def blit_demo_commands(machine):
    assert machine.presented==2
    assert len(machine.recorded_commands)==len(machine.recorded_ops)==14
    assert [op[0] for op in machine.recorded_ops].count(1)==2
    assert machine.result['blit_commands_issued']==machine.result['blit_commands_completed']==2
    assert machine.result['source_swaps_requested']==machine.result['source_swaps_completed']==2
    assert machine.result['swaps_requested']==machine.result['swaps_completed']==4
    for start in (0,7):
        assert [op[0] for op in machine.recorded_ops[start:start+7]]==[0,0,0,0,0,0,1]
        source_base=machine.recorded_commands[start][0]
        assert machine.recorded_ops[start+6]==(1,source_base,7680)
        assert machine.recorded_commands[start+6][0]==(source_base^0x800000)
        assert machine.recorded_commands[start+6][1:]==(64,64,32,32,0)

# Test the actual default artifact first; fault tests use only a shortened
# software poll limit in a separate temporary ELF. Hardware settings unchanged.
elf=args.elf.resolve()
m=Machine(elf,limit=0,target=1000).run();assert m.mode==0;good(m);scene_commands(m)
assert m.result['target_reached']==1 and m.result['running']==1
print('PASS E default ELF: 1000 continuous scenes / 4000 completed FILL_RECT / 1000 safe-swap acknowledgments; CPU only OCRAM/APB',flush=True)
m=Machine(elf,hold=60,wrap=True).run();good(m);scene_commands(m)
print('PASS E sticky DONE/tickets, command and swap wrap, 60-period hold, nonzero startup baseline',flush=True)
m=Machine(elf,case='resume_busy').run();good(m)
m=Machine(elf,case='resume_swap').run();good(m)
print('PASS E CPU rerun waits for existing writer or pending swap before baseline/commands',flush=True)
changed=build('parameter-change',['TEST_RECT_X=321','TEST_RECT_Y=123','TEST_RECT_W=137','TEST_RECT_H=89','TEST_RECT_COLOR=0x00123456'])
m=Machine(changed,mode=1).run();good(m);scene_commands(m,(321,123,137,89,0x123456))
print('PASS E rebuilt five-parameter single-rectangle mode changes exact submitted geometry/color',flush=True)
blit_elf=build('blit-demo',['DEMO_MODE=2'])
m=Machine(blit_elf,hold=60,wrap=True).run();assert m.mode==2;good(m);blit_demo_commands(m)
m=Machine(blit_elf,case='resume_swap').run();good(m);blit_demo_commands(m)
print('PASS E v5 ordinary BLIT demo: builds four-color Front source, clears Back, copies 32x32 to (64,64), and presents via four safe swaps',flush=True)
print('PASS E BLIT compiled mode, 60-period hold, counter wrap, and alternate initial Front after pending swap',flush=True)
key_elf=build('color-key-demo',['DEMO_MODE=3'])
def key_demo_commands(machine):
    good(machine)
    r=machine.result
    assert machine.mode==3 and len(machine.commands)==26 and machine.pixel_checks==4
    assert r['color_key_commands_issued']==r['color_key_commands_completed']==2
    assert r['blit_commands_issued']==r['blit_commands_completed']==2 and r['color_key_rgb']==0xff00ff
    assert r['source_swaps_completed']==2 and r['swaps_completed']==4
    for start in (0,13):
        assert [op[0] for op in machine.recorded_ops[start:start+13]]==[0]*11+[1,2]
        source=machine.recorded_commands[start][0]
        assert machine.recorded_ops[start+11:start+13]==[(1,source,7680),(2,source,7680)]
m=Machine(key_elf,hold=60,wrap=True).run();key_demo_commands(m)
m=Machine(key_elf,case='resume_swap').run();key_demo_commands(m)
key_high_x=build('color-key-high-x',['DEMO_MODE=3','DEMO_COLOR_KEY_RGB=0xAAFF00FF'])
m=Machine(key_high_x).run();key_demo_commands(m)
print('PASS E v5 color key: two scenes / 26 commands / four swaps; full 1080p XRGB source/target checks, blue/green background preservation, key X masking, wrap and alternate Front',flush=True)
for case,expected,direction in [('color_key_read_error',0x22,'read'),('color_key_write_error',0x23,'write')]:
    m=Machine(key_elf,case=case).run();r=m.result
    assert r['failure_code']==expected and r['failure_phase']==3 and r['errors']==1
    assert r['pass']==r['running']==r['iterations']==0
    assert r['commands_issued']==13 and r['commands_completed']==12
    assert r['color_key_commands_issued']==1 and r['color_key_commands_completed']==0
    assert r['blit_commands_completed']==1 and r['swaps_requested']==r['swaps_completed']==1
    assert r['axi_'+direction+'_error_observations']==1 and m.front==1
    assert all(value==1 for offset,value in m.writes if offset==8)
    print(f'PASS E {case}: {expected:#x}; source remains Front, failed Back never presented',flush=True)
for case,expected,direction in [('blit_read_error',0x22,'read'),('blit_write_error',0x23,'write')]:
    m=Machine(blit_elf,case=case).run()
    print('BLIT fault diagnostics:',case,m.result,flush=True)
    assert m.result['failure_code']==expected and m.result['failure_phase']==3
    assert m.result['errors']==1 and m.result['pass']==m.result['running']==m.result['iterations']==0
    # The model completes with an error on the STATUS read immediately after
    # an ERROR_CODE read returned zero; wait_done must recheck the error.
    assert m.result['commands_issued']==7 and m.result['commands_completed']==6, m.result
    assert m.result['blit_commands_issued']==1 and m.result['blit_commands_completed']==0
    assert m.result['command_delta']==len(m.commands)==7
    assert m.result['source_swaps_completed']==m.result['swaps_requested']==m.result['swaps_completed']==1
    assert m.result['axi_'+direction+'_error_observations']==1 and m.front==1
    assert all(value==1 for offset,value in m.writes if offset==8)
    print(f'PASS E {case}: {expected:#x}, source remains Front; failed Back never presented or reset',flush=True)
invalid=build('invalid-geometry',['TEST_RECT_W=0'])
m=Machine(invalid,mode=1).run()
assert m.result['failure_code']==0x11 and m.result['commands_completed']==1 and len(m.commands)==2
assert m.result['errors']==1 and m.result['pass']==0 and m.result['swaps_requested']==0
print('PASS E invalid rectangle retains hardware geometry error and never presents failed Back',flush=True)
fault_elf=build('bounded-faults',['ACCEL_POLL_LIMIT=64'])
faults={'bad_id':0xe000,'bad_version':0xe000,'missing_color_key':0xe003,'policy_disabled':0xe003,'init_timeout':0xe001,'ack_timeout':0xe103,
        'done_timeout':0xe101,'swap_timeout':0xe105,'hold_timeout':0xe106,'rejected':0xe102,
        'b_error':0x12,'reader_error':0x2003,'underflow':0xe109,'missed':0xe109}
for case,expected in faults.items():
    m=Machine(fault_elf,case=case,hold=1).run()
    assert m.result['failure_code']==expected and m.result['errors']==1 and m.result['pass']==0,(case,m.result)
    assert m.result['phase']==255 and m.result['running']==0
    if case.endswith('timeout'): assert m.result['timeout_count']==1
    if case=='rejected': assert m.result['rejected_operations']==m.result['rejected_commands']==1 and not m.commands
    if case in ('b_error','reader_error'): assert m.diag['error_code']==expected
    if case=='b_error': assert m.result['axi_write_error_observations']==1
    if case=='reader_error': assert m.result['axi_read_error_observations']==1
    if case in ('underflow','missed'): assert m.result[case+'_delta']==1
    if case in ('done_timeout','ack_timeout','b_error','reader_error','underflow','missed'): assert len(m.commands)==1
    if case=='swap_timeout': assert m.reg[0x64]&4 and m.result['swaps_completed']==0
    print(f'PASS E fault {case}: {expected:#x}; diagnostic snapshot and stop without reset',flush=True)
print('PASS E software emulation. MMIO model only; final E HDMI/long-run acceptance remains for the user.',flush=True)

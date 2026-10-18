"""Execute the compiled E RV32 ELF against an MMIO behavioral model, no board.

Requires unicorn==2.1.4 (can be installed in a temporary --unicorn-path).
This tests software, NOT DDR timing, HDL, Sapphire debug, or HDMI pixels.
"""
import argparse
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--unicorn-path',type=Path)
args=parser.parse_args()
if args.unicorn_path:
    sys.path.insert(0,str(args.unicorn_path))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32,UC_HOOK_MEM_READ,UC_HOOK_MEM_WRITE,UC_HOOK_CODE

TOOL=Path('D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin')
APB=0xF8100000
RAM=0xF9000000
MASK=0xffffffff
temp=Path(tempfile.mkdtemp(prefix='fpga-e-software-'))
print('Artifacts:',temp,flush=True)

def build(name,defines):
    out=temp/name
    command=[sys.executable,str(ROOT/'scripts/build_apb_software.py'),'--output',str(out)]
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
    def __init__(self,elf,case='normal',limit=2,mode=0,hold=0,target=2,wrap=False):
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
        symbols=subprocess.check_output([str(TOOL/'riscv-none-elf-nm.exe'),'-n',str(elf)],text=True)
        self.symbols={parts[-1]:int(parts[0],16) for line in symbols.splitlines()
                      if len(parts:=line.split())>=3}
        self.entry=struct.unpack_from('<I',data,24)[0]
        self.reg={i:0 for i in range(0,0xc8,4)}
        self.reg.update({0:0x4143434C,4:0x40000,0xc:0x1a,0x2c:0,0x30:0x800000,
                         0x34:7680,0x38:1920,0x3c:1080,0x40:0x7b,0x44:518400,
                         0x48:4050,0x4c:4050,0x50:4050,0x54:518400,0x58:1,
                         0x5c:0xfffffffc if wrap else 37,0x64:0x12,
                         0x80:0xfffffffe if wrap else 11,0x84:3,0x88:0x30,
                         0xa4:7,0xac:512,0xb4:128,0xb8:0x02000180})
        self.remaining=0;self.pending=0;self.commands=[];self.writes=[]
        self.front=0;self.swaps=0;self.stopped=False;self.presented=0
        self.recorded_commands=[];self.startup_command=False;self.startup_swap=False
        if case=='init_timeout': self.reg[0xc]=0
        if case=='bad_id': self.reg[0]=0
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
        for name,value in [('g_frame_limit',self.limit),('g_hold_frames',self.hold),
                           ('g_demo_mode',self.mode),('g_validation_target',self.target)]:
            self.put(name,value)

    def advance(self):
        if self.remaining and self.case!='done_timeout':
            self.remaining-=1
            if not self.remaining:
                self.reg[0xc]=0x1a;self.reg[0x64]&=~0x20
                if self.case=='b_error': self.reg[0x24]=0x12;self.reg[0xc]|=4
                if self.case=='reader_error': self.reg[0x24]=0x2003;self.reg[0x78]=0x2003
                if self.case=='underflow': self.reg[0xa4]+=1
                if self.case=='missed': self.reg[0x84]+=1
                self.reg[0x8c]=(self.reg[0x8c]+10000)&MASK
                self.reg[0x90]=(self.reg[0x90]+32)&MASK
                if not self.startup_command: self.recorded_commands.append(self.commands[-1])
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
            assert self.reg[0xbc]==0,'FILL demo must explicitly select FILL for every command'
            command=tuple(self.reg[o] for o in (0x10,0x14,0x18,0x1c,0x20))
            self.commands.append((self.reg[0x30],*command))
            if self.case=='ack_timeout': return
            self.reg[0x5c]=(self.reg[0x5c]+1)&MASK
            x,y,w,h,color=command
            if not(w and h and x<1920 and y<1080 and x+w<=1920 and y+h<=1080):
                self.reg[0x24]=0x11;self.reg[0xc]=0x1e;return
            self.remaining=12;self.reg[0xc]=0x19;self.reg[0x64]|=0x20
        elif offset==0x60:
            assert value==3 and not self.remaining and not self.pending
            self.reg[0x64]=(self.reg[0x64]&~8)|4;self.pending=8
        else: self.reg[offset]=value

    def scene_begin(self,uc,address,size,data):
        if self.case=='rejected': self.reg[0x64]|=4

    def back_ready(self,uc,address,size,data):
        assert self.reg[0x2c]==self.front*0x800000 and self.reg[0x68]==self.reg[0x2c]
        assert len(self.recorded_commands)==len(self.commands)
        assert all(c[0]==self.reg[0x30] for c in self.recorded_commands[-(2 if self.mode==1 else 4):])

    def frame_presented(self,uc,address,size,data):
        self.presented+=1
        assert self.swaps==self.presented
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
    assert r['iterations']==r['swaps_completed']==r['swaps_requested']==machine.presented
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

# Test the actual default artifact first; fault tests use only a shortened
# software poll limit in a separate temporary ELF. Hardware settings unchanged.
elf=ROOT/'software/apb_reg_test/build/apb_reg_test.elf'
m=Machine(elf,limit=0,target=1000).run();good(m);scene_commands(m)
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
invalid=build('invalid-geometry',['TEST_RECT_W=0'])
m=Machine(invalid,mode=1).run()
assert m.result['failure_code']==0x11 and m.result['commands_completed']==1 and len(m.commands)==2
assert m.result['errors']==1 and m.result['pass']==0 and m.result['swaps_requested']==0
print('PASS E invalid rectangle retains hardware geometry error and never presents failed Back',flush=True)
fault_elf=build('bounded-faults',['ACCEL_POLL_LIMIT=64'])
faults={'bad_id':0xe000,'policy_disabled':0xe003,'init_timeout':0xe001,'ack_timeout':0xe103,
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

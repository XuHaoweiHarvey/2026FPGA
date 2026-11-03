"""Exercise the actual stress build, preview renderer, ELF and stress UI offline."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import tkinter as tk
from PIL import Image
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_debug_bridge import LunariaBridge, read_assets
from lunaria_debug_window import LunariaWindow
from run_lunaria_checks import rasterize, source_image


def check_rv32_initialization():
    """Execute the real accel_api.h init instructions against mapped APB reads."""
    import importlib
    import importlib.util
    import struct

    if importlib.util.find_spec('unicorn') is None:
        # Reuse a pinned dependency outside the project, without changing the
        # user's Python installation or downloading again on every test run.
        cache = Path(tempfile.gettempdir())/'lunaria-unicorn-2.1.4'
        sys.path.insert(0, str(cache))
        importlib.invalidate_caches()
        if importlib.util.find_spec('unicorn') is None:
            print('RV32 init regression requires Unicorn; installing 2.1.4 into', cache, flush=True)
            subprocess.run([sys.executable, '-m', 'pip', '--disable-pip-version-check',
                            'install', '--only-binary=:all:', '--target', str(cache),
                            'unicorn==2.1.4'], check=True)
            importlib.invalidate_caches()
    import unicorn
    from unicorn.riscv_const import UC_RISCV_REG_A0, UC_RISCV_REG_PC, UC_RISCV_REG_RA, UC_RISCV_REG_SP

    toolchain = Path('D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin')
    bsp = ROOT/'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include'
    cases = []
    with tempfile.TemporaryDirectory(prefix='lunaria-rv32-init-') as directory:
        temp = Path(directory)
        (temp/'probe.c').write_text(
            '#include "' + (ROOT/'software/apb_reg_test/accel_api.h').as_posix() +
            '"\nuint32_t probe(void) { return accel_init(); }\n' + '''
uint32_t stream(uint32_t fast) {
 uint32_t e=accel_init(),i;if(e)return e;
 e=accel_command_batch_begin();if(e)return e;
 for(i=0;i<1280;i++) {
   uint32_t x=650+i%600,y=380+i%380;
   e=(fast && i) ? accel_submit_repeat_xy(x,y) :
     accel_submit(3,0x013ac700,2560,x,y,8,8,255);
   if(e)return e;
 }
 e=accel_submit(0,0,0,650,380,4,4,0x123456);if(e)return e;
 e=accel_submit(3,0x013ac700,2560,650,380,8,8,127);if(e)return e;
 return accel_command_batch_end();
}
''', encoding='utf8')
        (temp/'start.S').write_text('''.global _start
_start:
  li sp, 0x1003fff0
  call probe
.global test_done
test_done:
  j test_done
''', encoding='utf8')
        (temp/'probe.ld').write_text('''ENTRY(_start)
PHDRS { ram PT_LOAD; }
SECTIONS { . = 0x10000000;
 .text : { *(.text*) } :ram
 .rodata : { *(.rodata*) } :ram
 .data : { *(.data*) *(.sdata*) } :ram
 .bss : { *(.bss*) *(.sbss*) *(COMMON) } :ram
}
''', encoding='utf8')
        for required in (0xC0000, 0xD0000):
            elf = temp/f'init-{required:x}.elf'
            subprocess.run([str(toolchain/'riscv-none-elf-gcc.exe'),
                            '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-O2',
                            '-ffreestanding', '-fno-builtin', '-msmall-data-limit=0',
                            '-nostdlib', '-Wall', '-Wextra', '-Werror',
                            '-DACCEL_POLL_LIMIT=8', '-DLN_STRESS_TEST=1', '-DGAME_DISPLAY_WINDOW=1',
                            '-DGAME_ALLOW_SCALE2=1', '-DLUNARIA_PIXEL_X=1',
                            f'-DLUNARIA_HARDWARE_VERSION={required}', '-I'+str(bsp),
                            '-Wl,--no-relax', '-T'+str(temp/'probe.ld'),
                            str(temp/'start.S'), str(temp/'probe.c'), '-lgcc', '-o', str(elf)],
                           check=True, cwd=temp)
            symbols = {}
            for line in subprocess.check_output(
                    [str(toolchain/'riscv-none-elf-nm.exe'), str(elf)], text=True).splitlines():
                fields = line.split()
                if len(fields) == 3:
                    symbols[fields[2]] = int(fields[0], 16)
            data = elf.read_bytes()
            header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
            other = 0xD0000 if required == 0xC0000 else 0xC0000
            for version, caps, expected in ((required, 0x7FFB, 0),
                                             (other, 0x7FFB, 0xE000),
                                             (required, 0x3FFB, 0xE003),
                                             (required, 0x77FB, 0xE000),
                                             (required, 0x7EFB, 0xE003)):
                emu = unicorn.Uc(unicorn.UC_ARCH_RISCV, unicorn.UC_MODE_RISCV32)
                emu.mem_map(0x10000000, 0x40000)
                emu.mem_map(0xF8100000, 0x1000)
                for i in range(header[10]):
                    kind, offset, address, _, size, _, _, _ = struct.unpack_from(
                        '<8I', data, header[5]+i*header[9])
                    if kind == 1 and size:
                        emu.mem_write(address, data[offset:offset+size])
                registers = {0x00: 0x4143434C, 0x04: version, 0x0C: 8, 0x24: 0,
                             0x34: 7680, 0x38: 1920, 0x3C: 1080, 0x40: caps,
                             0x5C: 123, 0x64: 0x10, 0x88: 0x60, 0xB4: 128,
                             0xB8: 0x02000180}
                for offset, value in registers.items():
                    emu.mem_write(0xF8100000+offset, struct.pack('<I', value))
                writes = []
                emu.hook_add(unicorn.UC_HOOK_MEM_WRITE,
                             lambda uc, access, address, size, value, user: writes.append(address),
                             begin=0xF8100000, end=0xF8100FFF)
                emu.emu_start(header[4], symbols['test_done'], count=10000)
                actual = emu.reg_read(UC_RISCV_REG_A0)
                assert emu.reg_read(UC_RISCV_REG_PC) == symbols['test_done'], 'Init did not terminate'
                assert actual == expected, (hex(required), hex(version), hex(caps), hex(actual), hex(expected))
                assert not writes, 'accel_init unexpectedly mutated APB hardware'
                cases.append(dict(firmware=hex(required), hardware=hex(version),
                                  capabilities=hex(caps), result=hex(actual)))
            if required==0xD0000:
                streams=[]
                for fast,stall,error,want in ((0,False,0,0),(1,False,0,0),(1,True,0,0xE102),(1,True,0x22,0x22)):
                    emu=unicorn.Uc(unicorn.UC_ARCH_RISCV,unicorn.UC_MODE_RISCV32)
                    emu.mem_map(0x10000000,0x40000);emu.mem_map(0xF8100000,0x1000)
                    for i in range(header[10]):
                        kind,offset,address,_,size,_,_,_=struct.unpack_from('<8I',data,header[5]+i*header[9])
                        if kind==1 and size: emu.mem_write(address,data[offset:offset+size])
                    registers.update({0x04:required,0x40:0x7FFB,0x0C:0x2A,0x5C:0,0x24:0})
                    for offset,value in registers.items(): emu.mem_write(0xF8100000+offset,struct.pack('<I',value))
                    commands=[];instructions=[0]
                    def commit(uc,access,address,size,value,user):
                        if address==0xF8100008:
                            commands.append(tuple(struct.unpack('<I',uc.mem_read(0xF8100000+off,4))[0] for off in (0xBC,0xC0,0xC4,0x10,0x14,0x18,0x1C,0x20)))
                            uc.mem_write(0xF810005C,struct.pack('<I',len(commands)))
                            if stall:
                                uc.mem_write(0xF810000C,struct.pack('<I',8))
                                uc.mem_write(0xF8100024,struct.pack('<I',error))
                    def count_instruction(uc,address,size,user): instructions[0]+=1
                    emu.hook_add(unicorn.UC_HOOK_MEM_WRITE,commit,begin=0xF8100000,end=0xF8100FFF)
                    emu.hook_add(unicorn.UC_HOOK_CODE,count_instruction)
                    emu.reg_write(UC_RISCV_REG_SP,0x1003fff0);emu.reg_write(UC_RISCV_REG_RA,symbols['test_done']);emu.reg_write(UC_RISCV_REG_A0,fast)
                    emu.emu_start(symbols['stream'],symbols['test_done'],count=2000000)
                    assert emu.reg_read(UC_RISCV_REG_PC)==symbols['test_done'] and emu.reg_read(UC_RISCV_REG_A0)==want
                    if stall: assert len(commands)==1
                    else: streams.append((commands,instructions[0]))
                assert streams[0][0]==streams[1][0] and len(streams[0][0])==1282
                assert streams[1][1]<streams[0][1]
                performance=dict(generic_instructions=streams[0][1],repeat_instructions=streams[1][1],commands=1282)
                print('PASS RV32 descriptor equivalence, batch drain, queue timeout/error; instruction counts:',performance)
    print(f'PASS actual RV32 accel_init: {len(cases)} v12/v13 and missing-capability cases')
    return dict(unicorn=unicorn.__version__, cases=cases,submission=performance)


rv32 = check_rv32_initialization()
compiler = next((c for c in ('cl','gcc','clang','cc') if shutil.which(c)),None)
if not compiler: raise SystemExit('Use an initialized MSVC terminal')
with tempfile.TemporaryDirectory(prefix='lunaria-stress-check-') as directory:
    temp=Path(directory);exe=temp/'stress.exe';trace=temp/'trace.bin'
    units=[ROOT/'sim/test_lunaria_stress.c',ROOT/'software/lunaria/lunaria.c',ROOT/'software/lunaria/lunaria_render.c']
    flags=['/nologo','/TC','/W4','/WX','/O2','/D_CRT_SECURE_NO_WARNINGS','/DLN_STRESS_TEST=1'] if compiler=='cl' else ['-std=c99','-O2','-Wall','-Wextra','-Werror','-DLN_STRESS_TEST=1']
    output=['/Fe:'+str(exe)] if compiler=='cl' else ['-o',str(exe)]
    subprocess.run([compiler,*flags,*map(str,units),*output],cwd=temp,check=True)
    result=subprocess.run([str(exe),str(trace)],text=True,capture_output=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    stress_atlas=Image.frombytes('RGBA',(640,480),(ROOT/'delivery/lunaria_stress/atlas.argb').read_bytes(),'raw','BGRA')
    frames=rasterize(trace,contact_sheets=False,atlas_override=stress_atlas)
delivery=ROOT/'delivery/lunaria_stress'
bridge=LunariaBridge(delivery/'lunaria.elf',assets=delivery/'assets.json')
assert bridge.image.symbol_u32('g_lunaria_stress_test')==1
assert bridge.image.symbol_u32('g_lunaria_settings',10)==2048
assert bridge.asset_hashes==[h for _,h in read_assets(delivery/'assets.json')]
# The actual packed tile is 8x8, with visible opaque body/highlights retained.
old_atlas=source_image('atlas')
old=old_atlas.crop((450,2,462,14));new=stress_atlas.crop((448,64,456,72))
assert new.tobytes()==old.resize((8,8), Image.Resampling.LANCZOS).tobytes()
assert new.getchannel('A').getbbox()==(0,0,8,8)
assert sum(a>=250 for a in new.getchannel('A').tobytes())>=16
manifest=json.loads((delivery/'assets.json').read_text())
assert manifest['bullet_size']==8 and manifest['stress_bullet_rect']==[448,64,8,8]
assert bridge.image.symbol_u32('g_lunaria_required_hardware')==0xD0000
# Exercise the same mailbox protocol with an ELF declaring the larger capacity.
import run_lunaria_loader_checks as loader_checks
with patch.object(loader_checks,'DEFAULT_ELF',delivery/'lunaria.elf'):
    fake,address=loader_checks.Checks().settings_fake()
    assert LunariaBridge.configure(fake,2048)==1
    assert fake.writes[0]==(address+20,2048)
    fake,address=loader_checks.Checks().settings_fake()
    try: LunariaBridge.configure(fake,2049)
    except ValueError: pass
    else: raise AssertionError('Accepted over-capacity settings')
    assert not fake.writes
from game_debug_bridge import APB, DebugBridge
from run_game_debug_checks import FakeBridge
from unittest.mock import Mock
from contextlib import nullcontext
for version in (0xC0000,0xD0000):
    candidate=LunariaBridge(delivery/'lunaria.elf',assets=delivery/'assets.json')
    candidate.halted=lambda: nullcontext(True)
    candidate.read_words=lambda address,count: [version]
    candidate.upload_assets=Mock()
    with patch.object(DebugBridge,'load') as base_load:
        if version==0xD0000:
            candidate.load();base_load.assert_called_once();candidate.upload_assets.assert_called_once()
        else:
            try: candidate.load()
            except RuntimeError: pass
            else: raise AssertionError('Stress v13 accepted v12 bit')
            base_load.assert_not_called();candidate.upload_assets.assert_not_called()
fake=FakeBridge(delivery/'lunaria.elf')
fake.memory[APB+4]=0xD0000;fake.memory[APB+0x40]=0x7FFB
fake.load()
assert any(call.startswith('load_image ') for call in fake.calls)
root=tk.Tk();root.withdraw()
try:
    window=LunariaWindow(root,delivery/'lunaria.elf',delivery/'assets.json',stress=True)
    root.update_idletasks()
    assert window.bridge is None and window.invincible.get() and window.stress
    assert window.bullet_limit.get()=='256' and not window.spin_patterns.get()
    assert '\u538b\u529b\u6d4b\u8bd5' in root.title() and window.maximum_bullets==2048
finally: root.destroy()
# Existing fixture now tests small tiles FROM COLD RESET, with no 16x16 warmup.
fixture=(ROOT/'sim/tb_alpha_stream_cache.v').read_text()
rtl_outputs=[]
with tempfile.TemporaryDirectory(prefix='stress-alpha-') as directory:
    temp=Path(directory);bench=temp/'stress.v';binary=temp/'stress.vvp'
    bench.write_text(fixture,encoding='utf8')
    for cache,latency in ((1,0),(1,20),(0,20)):
        subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_alpha_stream_cache',
                        '-Ptb_alpha_stream_cache.STREAM=1',f'-Ptb_alpha_stream_cache.CACHE={cache}',
                        '-Ptb_alpha_stream_cache.PIXEL_X=1',f'-Ptb_alpha_stream_cache.SOURCE_LATENCY={latency}',
                        '-o',str(binary),str(bench),str(ROOT/'rtl/accelerator/alpha_pixel_pipeline.v'),
                        str(ROOT/'rtl/accelerator/alpha_blit_engine.v')],check=True,cwd=ROOT)
        rtl=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True)
        print(rtl.stdout,end='');print(rtl.stderr,end='');rtl.check_returncode()
        rtl_outputs.append(rtl.stdout)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report=dict(status='passed',board_tested=False,elf_sha256=sha(delivery/'lunaria.elf'),bit_sha256=sha(delivery/'ti60f225_oob.bit'),
            output=result.stdout,rtl_output='\n'.join(rtl_outputs),rv32_initialization=rv32,frames=frames,
            sources={p.relative_to(ROOT).as_posix():sha(p) for p in units+[ROOT/'software/lunaria/lunaria.h',ROOT/'scripts/run_lunaria_stress_checks.py',ROOT/'software/apb_reg_test/accel_api.h',ROOT/'software/apb_reg_test/accel_regs.h',ROOT/'rtl/accelerator/alpha_blit_engine.v',ROOT/'sim/tb_alpha_stream_cache.v']})
(ROOT/'output/lunaria/verification/stress-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print('PASS stress ELF/assets, 2048 mailbox/UI, 8x8 packed artwork and rendered previews')

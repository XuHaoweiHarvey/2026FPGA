"""Run compiled RV32 M2 scene/metric checks. No DDR, HDMI, or board model."""
import argparse
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--unicorn-path',type=Path)
p.add_argument('--toolchain-prefix',default='D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-')
p.add_argument('--rect-count',type=int,default=24)
a=p.parse_args()
assert 1<=a.rect_count<=64
if a.unicorn_path: sys.path.insert(0,str(a.unicorn_path))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32,UC_HOOK_CODE
from unicorn.riscv_const import UC_RISCV_REG_SP,UC_RISCV_REG_GP

with tempfile.TemporaryDirectory(prefix='fpga-m2-sw-') as d:
    elf=Path(d)/'scene.elf'
    gcc=a.toolchain_prefix+'gcc.exe'
    nm=a.toolchain_prefix+'nm.exe'
    subprocess.run([gcc,'-march=rv32im_zicsr_zifencei','-mabi=ilp32','-O2',
                    f'-DRECT_COUNT={a.rect_count}',
                    '-ffreestanding','-nostdlib','-nostartfiles','-Wl,-Ttext=0x1000',
                    '-Wl,-e,main',str(ROOT/'sim/m2_software_checks.c'),'-lgcc','-o',str(elf)],
                   check=True,cwd=ROOT)
    syms={parts[-1]:int(parts[0],16) for line in subprocess.check_output(
        [nm,'-n',str(elf)],text=True).splitlines() if len(parts:=line.split())>=3}
    data=elf.read_bytes()
    uc=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32)
    uc.mem_map(0,0x800000)
    for i in range(struct.unpack_from('<H',data,44)[0]):
        phoff=struct.unpack_from('<I',data,28)[0]
        phsize=struct.unpack_from('<H',data,42)[0]
        typ,off,va,pa,filesz,memsz,flags,align=struct.unpack_from('<8I',data,phoff+i*phsize)
        if typ==1:
            assert va+memsz<=0x800000
            uc.mem_write(va,data[off:off+filesz])
    uc.reg_write(UC_RISCV_REG_SP,0x700000)
    uc.reg_write(UC_RISCV_REG_GP,syms['__global_pointer$'])
    stopped=[]
    def done(u,address,size,user):
        stopped.append(True)
        u.emu_stop()
    uc.hook_add(UC_HOOK_CODE,done,begin=syms['m2_checks_done'],end=syms['m2_checks_done'])
    uc.emu_start(syms['main'],0,count=200000000)
    assert stopped,'M2 scene check exceeded instruction budget'
    result=struct.unpack('<I',uc.mem_read(syms['g_m2_check_result'],4))[0]
    assert result==0,f'M2 scene/metric check {result} failed'
print('PASS compiled RV32 M2 scene: deterministic CPU/FPGA tasks, two physical slot histories, movement bounds, three full-image CPU copies, asset bases, real frame FPS, five-second boundary and speedup')

"""Cross-compile and execute real RV32 storage/game tests with Unicorn.

Requires Unicorn 2.1+ in this Python, and the normal Efinity GNU RV32 toolchain.
All artifacts are confined to --output. No hardware, flash erase or download.
"""
import argparse
from pathlib import Path
import struct
import subprocess
import sys
import importlib.util

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ide-root',type=Path,default=Path('C:/Efinity/efinity-riscv-ide-2026.1'))
parser.add_argument('--unicorn-path',type=Path)
parser.add_argument('--output',type=Path,default=ROOT/'output/flash-tests')
args=parser.parse_args()
if args.unicorn_path:sys.path.insert(0,str(args.unicorn_path))
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32, UC_HOOK_CODE
from unicorn.riscv_const import UC_RISCV_REG_PC
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
(out/'start.S').write_text('''.global _start
_start:
  la sp, test_stack_top
  call main
  la t0, test_exit_code
  sw a0, 0(t0)
.global test_done
test_done:
  j test_done
.section .bss
.align 4
test_exit_code: .space 4
  .space 32768
test_stack_top:
''')
(out/'assert.h').write_text('''extern volatile unsigned test_result;
#define assert(x) do { if (!(x)) { test_result=__LINE__; __asm__ volatile("j test_done"); } } while(0)
''')
(out/'test.ld').write_text('''ENTRY(_start)
SECTIONS { . = 0x10000000; .text : { *(.text*) } .rodata : { *(.rodata*) }
 .data : { *(.data*) *(.sdata*) } .bss : { *(.bss*) *(.sbss*) *(COMMON) } }
''')
(out/'result.c').write_text('volatile unsigned test_result;')
gcc=args.ide_root/'toolchain/bin/riscv-none-elf-gcc.exe'
nm=args.ide_root/'toolchain/bin/riscv-none-elf-nm.exe'
def run(name,sources,includes=(),spi=False):
    elf=out/(name+'.elf')
    subprocess.run([str(gcc),'-march=rv32im_zicsr_zifencei','-mabi=ilp32','-O2','-g',
        '-ffreestanding','-fno-builtin','-nostdlib','-Wall','-Wextra','-Werror',
        '-Wno-misleading-indentation','-I'+str(out),*['-I'+str(s) for s in includes],'-T'+str(out/'test.ld'),
        str(out/'start.S'),*[str(s) for s in sources],'-lgcc','-o',str(elf)],check=True)
    symbols={}
    for line in subprocess.check_output([str(nm),str(elf)],text=True).splitlines():
        fields=line.split()
        if len(fields)==3:symbols[fields[2]]=int(fields[0],16)
    data=elf.read_bytes();header=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    uc=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32);uc.mem_map(0x10000000,0x400000)
    uc.mem_map(0x20000000,0x800000);uc.mem_write(0x20000000,b'\xff'*0x800000)
    if spi:
        sys.path.insert(0,str(ROOT/'sim'))
        from flash_spi_model import attach
        attach(uc)
    for i in range(header[10]):
        typ,off,vaddr,_,filesz,memsz,_,_=struct.unpack_from('<8I',data,header[5]+i*header[9])
        if typ==1 and filesz:uc.mem_write(vaddr,data[off:off+filesz])
    stopped=[]
    def stop(emu,address,size,user):stopped.append(True);emu.emu_stop()
    uc.hook_add(UC_HOOK_CODE,stop,begin=symbols['test_done'],end=symbols['test_done'])
    uc.emu_start(header[4],0,count=60000000)
    if not stopped:raise AssertionError(f'{name}: instruction budget exceeded PC={uc.reg_read(UC_RISCV_REG_PC):x}')
    failure=struct.unpack('<I',uc.mem_read(symbols['test_result'],4))[0]
    exitcode=struct.unpack('<I',uc.mem_read(symbols['test_exit_code'],4))[0]
    if failure or exitcode:raise AssertionError(f'{name}: failed source line {failure}, return {exitcode}')
    print('PASS RV32 '+name)
run('flash-storage',[ROOT/'sim/test_flash_store.c',ROOT/'software/flash/flash_store.c'])
run('game-logic',[ROOT/'sim/test_survival_game.c',ROOT/'software/interactive_demo/game_logic.c',out/'result.c'])
run('spi-transport',[ROOT/'sim/test_flash_spi.c',ROOT/'software/flash/flash_spi.c',ROOT/'software/flash/flash_store.c'],
    [ROOT/'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include'],spi=True)
(out/'stdio.h').write_text('static int printf(const char *fmt,...) {(void)fmt;return 0;}\n')
run('uart-protocol',[ROOT/'sim/test_uart_keyboard_protocol.c',out/'result.c'])
run('uart-input',[ROOT/'sim/test_uart_keyboard_input.c',out/'result.c'],[ROOT/'sim/mock_uart'])
print('PASS no board access; crash-safe save, CRC/pack bounds, portable game regression')

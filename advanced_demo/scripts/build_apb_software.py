"""Build the RAM-only APB test against the formal soc_control BSP."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ide-root', type=Path, default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
parser.add_argument('--toolchain-prefix',type=Path,
                    help='Optional complete GNU cross-tool prefix, ending in a hyphen; default uses the formal IDE')
parser.add_argument('--output', type=Path)
parser.add_argument('--program', choices=('apb','m1a','m1b','m2','advanced'), default='apb')
parser.add_argument('--opt', choices=('Og','O2'), default='Og')
parser.add_argument('--define', action='append', default=[], metavar='NAME=VALUE',
                    help='Optional C macro override, e.g. TEST_RECT_X=320; tests use a temporary output')
args = parser.parse_args()
bsp = ROOT / 'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc'
startup = ROOT / 'embedded_sw/soc_control/software/standalone/common/start.S'
soc_h = (bsp / 'include/soc.h').read_text(encoding='utf8')
macros = dict(re.findall(r'^#define\s+(\w+)\s+(0x[0-9a-fA-F]+|\d+)\s*$', soc_h, re.M))
def value(name):
    return int(macros[name], 0)
conf = json.loads((ROOT / 'ip/soc_control/settings.json').read_text(encoding='utf8'))['conf']
assert conf['DDR'] == "1'b1" and conf['DDR_AXI4'] == "1'b1" and conf['Cache'] == "1'b0"
assert conf['CpuCount'] == '1' and conf['OCRSize'] == '65536'
assert value('SYSTEM_RISCV_ISA_RV32I') == 1 and value('SYSTEM_RISCV_ISA_EXT_M') == 1
for extension in ('A', 'C', 'F', 'D'):
    assert value('SYSTEM_RISCV_ISA_EXT_' + extension) == 0, 'Recheck generated ISA before rebuilding'
assert value('IO_APB_SLAVE_0_INPUT_SIZE') >= 0xE8
assert value('SYSTEM_DDR_BMB') == 0x1000 and value('SYSTEM_DDR_BMB_SIZE') == 0xe0000000
assert value('SYSTEM_RAM_A_SIZE') == value('SYSTEM_RAM_A_CTRL_SIZE') == 65536
linker = bsp / 'linker/default.ld'
text = linker.read_text(encoding='utf8')
origin = int(re.search(r'ORIGIN\s*=\s*(0x[0-9A-Fa-f]+)', text)[1], 0)
length = int(re.search(r'LENGTH\s*=\s*(\d+)K', text)[1]) * 1024
assert origin == value('SYSTEM_RAM_A_CTRL') and length == value('SYSTEM_RAM_A_CTRL_SIZE')
default_output = ROOT / ('software/advanced_demo/build' if args.program=='advanced' else
                         'software/m2_demo/build' if args.program=='m2' else
                         'software/m1b_compare/build' if args.program=='m1b' else
                         'software/m1a_ddr_smoke/build' if args.program=='m1a' else
                         'software/apb_reg_test/build')
out = (args.output or default_output).resolve()
out.mkdir(parents=True, exist_ok=True)
bin_dir = args.ide_root / 'toolchain/bin'
tool_prefix = str(args.toolchain_prefix or (bin_dir / 'riscv-none-elf-'))
gcc = Path(tool_prefix+'gcc.exe')
objcopy = Path(tool_prefix+'objcopy.exe')
objdump = Path(tool_prefix+'objdump.exe')
nm = Path(tool_prefix+'nm.exe')
flags = ['-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-'+args.opt, '-g3', '-ffreestanding',
         '-ffunction-sections', '-fdata-sections', '-Wall', '-Wextra', '-Werror',
         '-DUSE_GP', '-DNO_LIBC_INIT_ARRAY', '-I' + str(bsp / 'include')]
for define in args.define:
    assert re.fullmatch(r'[A-Z][A-Z0-9_]*=[A-Za-z0-9_xX()+-]+',define), define
    flags.append('-D'+define)
if args.program == 'm1b':
    assert not any(d.startswith('DEMO_MODE=') for d in args.define)
    flags.append('-DDEMO_MODE=5')
if args.program == 'm2':
    assert not any(d.startswith('DEMO_MODE=') for d in args.define)
    flags.append('-DDEMO_MODE=6')
if args.program == 'advanced':
    assert not any(d.startswith('DEMO_MODE=') for d in args.define)
    flags.append('-DDEMO_MODE=7')
def run(command):
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)
source = ROOT / ('software/m1a_ddr_smoke/main.c' if args.program=='m1a' else 'software/apb_reg_test/main.c')
basename = 'm1a_ddr_smoke' if args.program=='m1a' else 'm1b_compare' if args.program=='m1b' else 'm2_demo' if args.program=='m2' else 'advanced_demo' if args.program=='advanced' else 'apb_reg_test'
run([gcc, *flags, '-c', source, '-o', out / 'main.o'])
run([gcc, *flags, '-c', startup, '-o', out / 'start.o'])
elf = out / (basename+'.elf')
run([gcc, *flags, '-nostdlib', '-nostartfiles', '-Wl,--gc-sections', '-T', linker,
     '-Wl,-Map,' + str(out / (basename+'.map')), out / 'start.o', out / 'main.o', '-lgcc', '-o', elf])
run([objcopy, '-O', 'binary', elf, out / (basename+'.bin')])
run([objcopy, '-O', 'ihex', elf, out / (basename+'.hex')])
dump = subprocess.check_output([str(objdump), '-d', '-S', str(elf)], cwd=ROOT, text=True)
(out / (basename+'.disasm')).write_text(dump, encoding='utf8')
symbols = subprocess.check_output([str(nm), '-n', '-S', str(elf)], text=True)
required = ('_start','main','m1a_test_done','g_m1a_result','_sp') if args.program=='m1a' else \
           ('_start','main','m1b_test_done','g_m1b_result','_sp') if args.program=='m1b' else \
           ('_start','main','m2_error_stop','m2_cycle_boundary','g_m2_result','_sp') if args.program=='m2' else \
           ('_start','main','advanced_demo_done','g_advanced_result','_sp') if args.program=='advanced' else \
           ('_start', 'main', 'apb_test_done', 'g_apb_test_result', 'g_benchmark_result', '_sp')
selected = [line for line in symbols.splitlines() if line.split()[-1] in
            required]
assert len(selected) == len(required)
for line in selected:
    address = int(line.split()[0], 16)
    assert origin <= address <= origin + length - 1024, line
# PT_LOAD segments must all lie in the formal on-chip RAM, never the DDR.
readelf = Path(tool_prefix+'readelf.exe')
segments = subprocess.check_output([str(readelf), '-l', '-W', str(elf)], text=True)
for line in segments.splitlines():
    fields = line.split()
    if fields and fields[0] == 'LOAD':
        virtual, physical, size = int(fields[2], 16), int(fields[3], 16), int(fields[5], 16)
        assert origin <= virtual and virtual + size <= origin + length - 1024, line
        assert origin <= physical and physical + size <= origin + length - 1024, line
print(f'PASS formal BSP RAM ELF: APB base={value("IO_APB_SLAVE_0_INPUT"):#010x}, '
      f'RAM={origin:#010x}/{length} bytes')
print('\n'.join(selected))
print('ELF:', elf)

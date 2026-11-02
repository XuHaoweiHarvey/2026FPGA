"""Build APB checks, inherited benchmarks, or the UART-controlled game."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ide-root', type=Path, default=Path('C:/Efinity/efinity-riscv-ide-2026.1'))
parser.add_argument('--toolchain-prefix',type=Path,
                    help='Optional complete GNU cross-tool prefix, ending in a hyphen; default uses the formal IDE')
parser.add_argument('--output', type=Path)
parser.add_argument('--program', choices=('apb','m1a','m1b','m2','game','lunaria','keyboard-test','flash-probe','flash-maint'), default='apb')
parser.add_argument('--opt', choices=('Og','O2','Os'), default='Og')
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
if args.program in ('game', 'lunaria', 'keyboard-test'):
    assert conf['UART0'] == "1'b1", 'Enable UART0 in Efinity IP Manager before building UART software'
    assert 'SYSTEM_UART_0_IO_CTRL' in macros, 'Regenerate the Sapphire SoC/BSP with UART0 enabled'
    # An enabled IP/BSP alone is insufficient while the wrapper still reserves
    # RX/TX with an idle driver. Check the physical-port bindings before linking.
    subprocess.run([sys.executable, str(ROOT / 'scripts/check_project.py')], cwd=ROOT, check=True)
assert value('SYSTEM_RAM_A_SIZE') == value('SYSTEM_RAM_A_CTRL_SIZE') == 65536
linker = ROOT / 'software/flash/ocram.ld'  # explicit JTAG/OCRAM, no DDR boot
text = linker.read_text(encoding='utf8')
origin = int(re.search(r'ORIGIN\s*=\s*(0x[0-9A-Fa-f]+)', text)[1], 0)
length = int(re.search(r'LENGTH\s*=\s*(\d+)K', text)[1]) * 1024
assert origin == value('SYSTEM_RAM_A_CTRL') and length == value('SYSTEM_RAM_A_CTRL_SIZE')
default_output = ROOT / ('software/interactive_demo/build/game' if args.program=='game' else
                         'software/lunaria/build' if args.program=='lunaria' else
                         'software/interactive_demo/build/keyboard-test' if args.program=='keyboard-test' else
                         'software/m2_demo/build' if args.program=='m2' else
                         'software/m1b_compare/build' if args.program=='m1b' else
                         'software/m1a_ddr_smoke/build' if args.program=='m1a' else
                         'software/flash/build/'+args.program if args.program.startswith('flash-') else
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
if 'PIXELFORGE=1' in args.define:
    flags += ['-flto']
if args.program == 'm1b':
    assert not any(d.startswith('DEMO_MODE=') for d in args.define)
    flags.append('-DDEMO_MODE=5')
if args.program == 'm2':
    assert not any(d.startswith('DEMO_MODE=') for d in args.define)
    flags.append('-DDEMO_MODE=6')
def run(command):
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)
source = ROOT / ('software/lunaria/main.c' if args.program=='lunaria' else
                 'software/m1a_ddr_smoke/main.c' if args.program=='m1a' else
                 'software/interactive_demo/game_main.c' if args.program=='game' else
                 'software/interactive_demo/uart_keyboard_test.c' if args.program=='keyboard-test' else
                 'software/flash/flash_probe.c' if args.program=='flash-probe' else
                 'software/flash/flash_maint.c' if args.program=='flash-maint' else
                 'software/apb_reg_test/main.c')
basename = 'm1a_ddr_smoke' if args.program=='m1a' else 'm1b_compare' if args.program=='m1b' else 'm2_demo' if args.program=='m2' else 'apb_reg_test'
if args.program == 'game': basename = 'survival_game'
if args.program == 'lunaria': basename = 'lunaria'
if args.program == 'keyboard-test': basename = 'uart_keyboard_test'
if args.program.startswith('flash-'): basename = args.program.replace('-', '_')
if args.program == 'flash-maint': flags.append('-DFLASH_MAINTENANCE_BUILD=1')
run([gcc, *flags, '-c', source, '-o', out / 'main.o'])
objects = [out / 'start.o', out / 'main.o']
if args.program == 'game':
    game_logic = ROOT / 'software/interactive_demo/game_logic.c'
    run([gcc, *flags, '-c', game_logic, '-o', out / 'game_logic.o'])
    objects.append(out / 'game_logic.o')
if args.program == 'lunaria':
    for unit in ('lunaria', 'lunaria_render'):
        run([gcc, *flags, '-c', ROOT / ('software/lunaria/'+unit+'.c'), '-o', out/(unit+'.o')])
        objects.append(out/(unit+'.o'))
if args.program == 'game' or args.program.startswith('flash-'):
    extra = ['flash_store', 'flash_spi']
    if args.program == 'game': extra.append('game_flash')
    for unit in extra:
        run([gcc, *flags, '-c', ROOT / ('software/flash/'+unit+'.c'), '-o', out / (unit+'.o')])
        objects.append(out / (unit+'.o'))
run([gcc, *flags, '-c', startup, '-o', out / 'start.o'])
elf = out / (basename+'.elf')
keep = ('g_game_required_caps', 'g_game_alpha_hardware_compatible',
        'g_game_scale2_compatible', 'g_game_showcase_available',
        'g_lunaria_available', 'g_lunaria_asset_hashes', 'g_lunaria_required_hardware',
        'g_game_build_config') if args.program == 'lunaria' else ()
if args.program == 'lunaria' and 'PIXELFORGE=1' in args.define:
    keep += ('g_pixelforge_available',)
if args.program == 'lunaria' and 'LN_STRESS_TEST=1' in args.define:
    keep += ('g_lunaria_stress_test',)
run([gcc, *flags, '-nostdlib', '-nostartfiles', '-Wl,--gc-sections', '-T', linker,
     *['-Wl,--undefined='+name for name in keep],
     '-Wl,-Map,' + str(out / (basename+'.map')), *objects, '-lgcc', '-o', elf])
run([objcopy, '-O', 'binary', elf, out / (basename+'.bin')])
run([objcopy, '-O', 'ihex', elf, out / (basename+'.hex')])
dump = subprocess.check_output([str(objdump), '-d', '-S', str(elf)], cwd=ROOT, text=True)
(out / (basename+'.disasm')).write_text(dump, encoding='utf8')
symbols = subprocess.check_output([str(nm), '-n', '-S', str(elf)], text=True)
required = ('_start','main','m1a_test_done','g_m1a_result','_sp') if args.program=='m1a' else \
           ('_start','main','m1b_test_done','g_m1b_result','_sp') if args.program=='m1b' else \
           ('_start','main','m2_error_stop','m2_cycle_boundary','g_m2_result','_sp') if args.program=='m2' else \
           ('_start','main','game_demo_done','g_game_result','g_debug_control',
            'g_debug_status','g_debug_first_fault','_sp') if args.program=='game' else \
           ('_start','main','g_debug_control','g_debug_status','g_debug_first_fault',
            'g_lunaria_upload','g_lunaria_chunk','_sp',*keep) if args.program=='lunaria' else \
           ('_start','main','g_uart_keyboard_result','_sp') if args.program=='keyboard-test' else \
           ('_start','main','flash_dump_ready','g_flash_dump','_sp') if args.program=='flash-probe' else \
           ('_start','main','flash_maint_ready','g_flash_maint','_sp') if args.program=='flash-maint' else \
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

"""Build the standalone basic_demo application against the generated formal BSP."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ide-root', type=Path,
                        default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
    parser.add_argument('--toolchain-prefix', type=Path,
                        help='Complete GNU cross-tool prefix, ending in a hyphen')
    parser.add_argument('--output', type=Path, default=PROJECT / 'build')
    parser.add_argument('--opt', choices=('Og', 'O2'), default='O2')
    parser.add_argument('--define', action='append', default=[], metavar='NAME=VALUE')
    parser.add_argument('--clean', action='store_true', help='Remove this project build directory')
    args = parser.parse_args()
    out = args.output.resolve()
    build_root = (PROJECT / 'build').resolve()
    if build_root.parent != PROJECT:
        parser.error('The project build directory must not redirect outside the project')
    if out != build_root and not out.is_relative_to(build_root):
        parser.error('--output must be inside this project build directory')
    if args.clean:
        if out.exists():
            shutil.rmtree(out)
        print('Cleaned:', out)
        return

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
        assert value('SYSTEM_RISCV_ISA_EXT_' + extension) == 0, 'Recheck generated ISA'
    assert value('IO_APB_SLAVE_0_INPUT_SIZE') >= 0xE0
    assert value('SYSTEM_DDR_BMB') == 0x1000 and value('SYSTEM_DDR_BMB_SIZE') == 0xe0000000
    assert value('SYSTEM_RAM_A_SIZE') == value('SYSTEM_RAM_A_CTRL_SIZE') == 65536
    linker = bsp / 'linker/default.ld'
    script = linker.read_text(encoding='utf8')
    origin = int(re.search(r'ORIGIN\s*=\s*(0x[0-9A-Fa-f]+)', script)[1], 0)
    length = int(re.search(r'LENGTH\s*=\s*(\d+)K', script)[1]) * 1024
    assert origin == value('SYSTEM_RAM_A_CTRL') and length == value('SYSTEM_RAM_A_CTRL_SIZE')

    prefix = str(args.toolchain_prefix or (args.ide_root / 'toolchain/bin/riscv-none-elf-'))
    flags = ['-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-' + args.opt, '-g3',
             '-ffreestanding', '-ffunction-sections', '-fdata-sections', '-Wall', '-Wextra',
             '-Werror', '-DUSE_GP', '-DNO_LIBC_INIT_ARRAY', '-I' + str(bsp / 'include')]
    for define in args.define:
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*=[A-Za-z0-9_xX()+-]+', define):
            parser.error('Invalid macro override: ' + define)
        if define.startswith('DEMO_MODE='):
            parser.error('basic_demo directly builds its sole application; DEMO_MODE is obsolete')
        flags.append('-D' + define)

    def run(command):
        subprocess.run([str(x) for x in command], cwd=PROJECT, check=True)

    out.mkdir(parents=True, exist_ok=True)
    gcc = prefix + 'gcc.exe'
    run([gcc, *flags, '-c', PROJECT / 'main.c', '-o', out / 'main.o'])
    run([gcc, *flags, '-c', startup, '-o', out / 'start.o'])
    elf = out / 'basic_demo.elf'
    run([gcc, *flags, '-nostdlib', '-nostartfiles', '-Wl,--gc-sections', '-T', linker,
         '-Wl,-Map,' + str(out / 'basic_demo.map'), out / 'start.o', out / 'main.o',
         '-lgcc', '-o', elf])
    required = {'_start', 'main', 'm2_error_stop', 'm2_cycle_boundary', 'g_m2_result', '_sp'}
    symbols = subprocess.check_output([prefix + 'nm.exe', '-n', '-S', str(elf)], text=True)
    selected = [line for line in symbols.splitlines() if line.split()[-1] in required]
    assert {line.split()[-1] for line in selected} == required
    limit = origin + length - 1024
    for line in selected:
        assert origin <= int(line.split()[0], 16) <= limit, line
    segments = subprocess.check_output([prefix + 'readelf.exe', '-l', '-W', str(elf)], text=True)
    loads = 0
    for line in segments.splitlines():
        fields = line.split()
        if fields and fields[0] == 'LOAD':
            loads += 1
            virtual, physical, size = (int(fields[i], 16) for i in (2, 3, 5))
            assert origin <= virtual and virtual + size <= limit, line
            assert origin <= physical and physical + size <= limit, line
    assert loads, 'ELF has no loadable segments'
    run([prefix + 'objcopy.exe', '-O', 'binary', elf, out / 'basic_demo.bin'])
    run([prefix + 'objcopy.exe', '-O', 'ihex', elf, out / 'basic_demo.hex'])
    dump = subprocess.check_output([prefix + 'objdump.exe', '-d', '-S', str(elf)], text=True)
    (out / 'basic_demo.disasm').write_text(dump, encoding='utf8')
    print(f'PASS basic_demo: APB={value("IO_APB_SLAVE_0_INPUT"):#010x}, '
          f'OCRAM={origin:#010x}/{length}, application and stack below {limit:#010x}')
    print('\n'.join(selected))
    print('ELF:', elf)


if __name__ == '__main__':
    main()

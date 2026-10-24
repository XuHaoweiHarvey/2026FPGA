
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv, cwd=ROOT, env=None):
    result = subprocess.run([str(part) for part in argv], cwd=cwd, env=env,
                            capture_output=True, text=True, errors='replace', timeout=60)
    if result.returncode:
        raise RuntimeError('命令失败：' + str(argv) + '\n' + result.stdout + result.stderr)
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--efinity-root', type=Path, default=Path('D:/Efinity'))
    args = parser.parse_args()
    efinity = args.efinity_root.resolve()
    ide = efinity / 'efinity-riscv-ide-2026.1'
    commit = command(['git', 'rev-parse', 'HEAD']).strip()
    source_paths = ['rtl', 'ip/soc_control', 'embedded_sw/soc_control',
                    'software/interactive_demo', 'software/apb_reg_test', 'software/m1b_compare',
                    'ti60f225_oob.xml', 'ti60f225_oob.peri.xml', 'ti60f225_oob.sdc', 'constraints']
    dirty = command(['git', 'status', '--porcelain', '--', *source_paths]).strip()
    if dirty:
        raise RuntimeError('构建相关源码与记录的 Git 基线不同，请先核对再封存：\n' + dirty)

    now = datetime.now(timezone(timedelta(hours=8)))
    name = 'advanced_uart_' + now.strftime('%Y%m%d') + '_' + commit[:7]
    out = (args.output or ROOT / 'output/board_ready' / name).resolve()
    archive = out.with_suffix('.zip')
    if out.exists() or archive.exists():
        raise FileExistsError('输出目录或压缩包已存在，请用 --output 指定新的名称：' + str(out))

    copies = {
        'outflow/ti60f225_oob.bit': 'bit/ti60f225_oob.bit',
        'software/interactive_demo/build/game/survival_game.elf': 'ide_project/firmware/survival_game.elf',
        'software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf': 'ide_project/firmware/uart_keyboard_test.elf',
        'embedded_sw/soc_control/cpu0.yaml': 'ide_project/openocd/cpu0.yaml',
        'software/apb_reg_test/openocd/ftdi_ti.cfg': 'ide_project/openocd/ftdi_ti.cfg',
        'software/apb_reg_test/openocd/debug_ti.cfg': 'ide_project/openocd/debug_ti.cfg',
        'software/apb_reg_test/apb_reg_test_ti.launch': 'tools/launch_template.xml',
        'software/apb_reg_test/.cproject': 'tools/cproject_template.xml',
        'tools/keyboard_uart.py': 'tools/keyboard_uart.py',
        'scripts/refresh_board_debug.py': 'tools/refresh_board_debug.py',
        'scripts/check_apb_debug.py': 'tools/check_apb_debug.py',
        'docs/BOARD_READY_GUIDE.md': '00_上板操作说明.md',
        'docs/GAME_BUILD_REPORT.md': 'docs/游戏构建报告.md',
        'docs/BOARD_VALIDATION_CHECKLIST.md': 'docs/上板验证清单.md',
        'docs/KEYBOARD_UART_INPUT.md': 'docs/键盘UART说明.md',
    }
    openocd = 'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/openocd/'
    for path in (ROOT / openocd).glob('*.xml'):
        copies[openocd + path.name] = 'ide_project/openocd/' + path.name
    for path in (ROOT / openocd).glob('*.dtd'):
        copies[openocd + path.name] = 'ide_project/openocd/' + path.name
    copies[openocd + 'sapphire_soc_xsvd.json'] = 'ide_project/openocd/sapphire_soc_xsvd.json'
    for filename in ('ti60f225_oob.proj_state.ini', 'ti60f225_oob.place.rpt',
                     'ti60f225_oob.route.rpt', 'ti60f225_oob.timing.rpt',
                     'ti60f225_oob.pgm.out', 'design_issue.xml'):
        copies['outflow/' + filename] = 'reports/' + filename
    for source in copies:
        if not (ROOT / source).is_file():
            raise FileNotFoundError(ROOT / source)
    if 'last_run_state=pass' not in (ROOT / 'outflow/ti60f225_oob.proj_state.ini').read_text():
        raise RuntimeError('最近 bitstream 编译状态不是 pass')
    for source in ('software/interactive_demo/build/game/survival_game.elf',
                   'software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf'):
        data = (ROOT / source).read_bytes()
        if (data[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 243
                or struct.unpack_from('<I', data, 24)[0] != 0xF9000000):
            raise RuntimeError('ELF 的架构或入口地址不符合当前工程：' + source)
    required_tools = {
        'Efinity 主程序': efinity / 'bin/efinity.exe',
        'Programmer 入口': efinity / 'pgm/bin/efx_pgm/__main__.py',
        'Programmer 版本': efinity / 'pgm/bin/efx_pgm/_version.py',
        'Efinity Python': efinity / 'python311/bin/python.exe',
        'RISC-V IDE': ide / 'Efinity-RISCV-IDE/efinity-riscv-ide.exe',
        'IDE 启动配置': ide / 'Efinity-RISCV-IDE/efinity-riscv-ide.ini',
        'Java': ide / 'Efinity-RISCV-IDE/jre/bin/java.exe',
        'OpenOCD': ide / 'openocd/bin/openocd.exe',
        'GDB': ide / 'toolchain/bin/riscv-none-elf-gdb.exe',
    }
    for path in required_tools.values():
        if not path.is_file():
            raise FileNotFoundError(path)
    out.mkdir(parents=True)
    files = []
    for source, target in copies.items():
        src, dst = ROOT / source, out / target
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        checksum = digest(src)
        if checksum != digest(dst):
            raise RuntimeError('复制校验失败：' + target)
        files.append({'path': target, 'source': source, 'bytes': dst.stat().st_size,
                      'sha256': checksum,
                      'source_mtime': datetime.fromtimestamp(src.stat().st_mtime, now.tzinfo).isoformat()})

    # Keep the copied historical guides' local Markdown links usable.
    for filename in ('游戏构建报告.md', '上板验证清单.md', '键盘UART说明.md'):
        path = out / 'docs' / filename
        content = path.read_text(encoding='utf8')
        for old, new in (('GAME_BUILD_REPORT.md', '游戏构建报告.md'),
                         ('BOARD_VALIDATION_CHECKLIST.md', '上板验证清单.md'),
                         ('KEYBOARD_UART_INPUT.md', '键盘UART说明.md')):
            content = content.replace('](' + old + ')', '](' + new + ')')
        path.write_text(content, encoding='utf8')
        entry = next(item for item in files if item['path'] == 'docs/' + filename)
        entry['sha256'], entry['bytes'] = digest(path), path.stat().st_size

    tool_output = {}
    tool_output['工程检查'] = command([sys.executable, '-B', ROOT / 'scripts/check_project.py'])
    for label, argv in (
        ('OpenOCD 版本', [required_tools['OpenOCD'], '--version']),
        ('GDB 版本', [required_tools['GDB'], '--version']),
        ('Java 版本', [required_tools['Java'], '-version']),
        ('串口枚举', [sys.executable, '-B', out / 'tools/keyboard_uart.py', '--list']),
        ('调试配置检查', [sys.executable, '-B', out / 'tools/refresh_board_debug.py',
                         '--package', out, '--ide-root', ide]),
    ):
        tool_output[label] = command(argv)
    (out / 'reports/工具检查原始输出.json').write_text(
        json.dumps(tool_output, ensure_ascii=False, indent=2) + '\n', encoding='utf8')

    verify = '''import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'manifest.json').read_text(encoding='utf8'))
for item in manifest['files']:
    path = root / item['path']
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit('FAIL: ' + item['path'])
print('PASS package SHA-256:', len(manifest['files']), 'files; source commit:', manifest['code_commit'])
'''
    (out / 'tools/verify_package.py').write_text(verify, encoding='utf8')
    # User-run helper: uses only a local environment, never system PATH settings.
    helper = '''@echo off
setlocal
set "PYTHONHOME={python_home}"
"{python}" -B "%~dp0tools\\refresh_board_debug.py" --package "%~dp0." --ide-root "{ide}"
if errorlevel 1 (
    echo FAILED: Read the error above before using the debug configurations.
    pause
    exit /b 1
)
echo Ready. Import the ide_project folder into the RISC-V IDE.
pause
'''.format(python_home=efinity / 'python311', python=required_tools['Efinity Python'], ide=ide)
    (out / 'refresh_debug.cmd').write_text(helper, encoding='ascii', newline='\r\n')
    for relative in ('tools/verify_package.py', 'refresh_debug.cmd'):
        path = out / relative
        files.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    manifest = {
        'code_commit': commit, 'branch': command(['git', 'branch', '--show-current']).strip(),
        'created_at': now.isoformat(), 'board': 'TI60F225I3-V4',
        'capture_method': '复制已存在的 bit/ELF，本次封存未重新编译 FPGA 或固件',
        'build_sources_match_commit': True,
        'board_validated': False, 'tool_paths': {key: str(path) for key, path in required_tools.items()},
        'configurations': ['ide_project/uart_keyboard_test_ti.launch', 'ide_project/survival_game_ti.launch'],
        'mutable_files': ['ide_project/.project', 'ide_project/.cproject',
                          'ide_project/uart_keyboard_test_ti.launch', 'ide_project/survival_game_ti.launch'],
        'files': sorted(files, key=lambda item: item['path']),
    }
    table = '\n'.join('| ' + label + ' | `' + str(path) + '` | 存在 |'
                      for label, path in required_tools.items())
    report = f'''# 本机下载与调试工具检查报告

检查时间：{now.isoformat()}。源码基线：`{commit}`。

| 工具或文件 | 本机路径 | 结果 |
|---|---|---|
{table}

## 已完成的离线检查

- GDB、OpenOCD 和 Java 实际启动并输出版本。
- 工程源文件、寄存器合同与 UART SoC/BSP 连接检查通过。
- 两个 ELF 均为小端 ELF32 RISC-V，入口地址 `0xF9000000`。
- GDB 能读到诊断程序的 `g_uart_keyboard_result` 和游戏的 `g_game_result`。
- 两个调试配置的主程序、下载镜像、调试符号均指向包内对应 ELF，启动前构建已关闭。
- 用实际 OpenOCD 内置 Jim Tcl 解析配置，硬件命令已替换为记录操作；检查通过。
- OpenOCD 工作区为 `0xF900FC00`、1024 字节，保留已有 Hard JTAG 参数。
- 已复制文件的 SHA-256 与封存来源逐个核对；包内附带独立校验脚本。

## 配置中需要特别区分的地方

原工程的 `apb_reg_test_ti.launch` 仍指向 M2 固件。本次保留该配置，
新增包内 `uart_keyboard_test_ti` 和 `survival_game_ti` 两个配置，导入项目名为
`advanced_board_debug`。两个配置均关闭自动继续，并设置 `main` 停止点。连接后按 Resume/F8，
若随后停在 `main`，再按一次 F8，让 CPU 持续运行。
同一时间只运行一个调试会话。Programmer 下载完成后先退出，释放 USB/JTAG 通道。

## 拿到板卡后才能验证

USB 驱动、Programmer 检测到的硬件、JTAG 下载和调试、FT4232 UART/COM 通道、
JTAG/UART 同时使用，以及实际图像和性能均未验证。Programmer 和 IDE 主程序路径已核对，
本次没有启动它们的图形界面，也没有安装或替换 USB 驱动。
现有配置使用 FTDI VID:PID `0403:6011`、JTAG channel 1、描述 `Quad RS232-HS`；
明天需与实际板卡枚举结果核对，不能用该 JTAG 通道号推断 UART COM 号。

当前串口枚举结果（仅记录现状，接板后重新查询）：

```text
{tool_output['串口枚举'].strip()}
```

详细命令输出见 `reports/工具检查原始输出.json`。
'''
    (out / '01_工具检查报告.md').write_text(report, encoding='utf8')
    for relative in ('01_工具检查报告.md', 'reports/工具检查原始输出.json'):
        path = out / relative
        files.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    manifest['files'] = sorted(files, key=lambda item: item['path'])
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    (out / 'SHA256SUMS.txt').write_text(''.join(
        item['sha256'] + '  ' + item['path'] + '\n' for item in manifest['files']), encoding='utf8')
    command([sys.executable, '-B', out / 'tools/verify_package.py'])
    shutil.make_archive(str(out), 'zip', root_dir=out.parent, base_dir=out.name)
    (archive.parent / (archive.name + '.sha256')).write_text(
        digest(archive) + '  ' + archive.name + '\n', encoding='ascii')
    print('源码基线：', commit)
    print('烧录包目录：', out)
    print('ZIP：', archive)
    print('已复制和校验：', len(files), '个文件；两个调试配置离线检查通过。')


if __name__ == '__main__':
    main()

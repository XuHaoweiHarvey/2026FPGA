"""为烧录包生成本机 RISC-V IDE 调试配置；不连接或操作板卡。"""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


OCD = 'ilg.gnumcueclipse.debug.gdbjtag.openocd.'
CORE = 'org.eclipse.cdt.debug.gdbjtag.core.'
CDT = 'org.eclipse.cdt.launch.'


def save_xml(path, root, cproject=False):
    ET.indent(root, space='    ')
    header = '<?xml version="1.0" encoding="UTF-8"?>\n'
    if cproject:
        header += '<?fileVersion 4.0.0?>\n'
    path.write_text(header + ET.tostring(root, encoding='unicode') + '\n', encoding='utf8')


def refresh(package, ide):
    project = package / 'ide_project'
    debug = project / 'openocd'
    project_name = 'advanced_board_debug'
    for required in (
        ide / 'Efinity-RISCV-IDE/efinity-riscv-ide.exe',
        ide / 'openocd/bin/openocd.exe',
        ide / 'toolchain/bin/riscv-none-elf-gdb.exe',
        debug / 'cpu0.yaml',
        debug / 'ftdi_ti.cfg',
        debug / 'debug_ti.cfg',
        debug / 'sapphire_soc_32bit-reg.xml',
        debug / 'sapphire_soc_xsvd.json',
    ):
        if not required.is_file():
            raise FileNotFoundError(required)

    description = ET.Element('projectDescription')
    ET.SubElement(description, 'name').text = project_name
    ET.SubElement(description, 'comment').text = '预编译固件调试项目，无自动构建'
    ET.SubElement(description, 'projects')
    ET.SubElement(description, 'buildSpec')
    natures = ET.SubElement(description, 'natures')
    for nature in ('org.eclipse.cdt.core.cnature', 'org.eclipse.cdt.core.ccnature',
                   'org.eclipse.cdt.managedbuilder.core.managedBuildNature',
                   'org.eclipse.cdt.managedbuilder.core.ScannerConfigNature'):
        ET.SubElement(natures, 'nature').text = nature
    save_xml(project / '.project', description)

    cproject = ET.parse(package / 'tools/cproject_template.xml').getroot()
    for node in cproject.iter():
        for key, value in list(node.attrib.items()):
            node.set(key, value.replace('apb_reg_test', project_name))
        if node.tag == 'builder':
            node.set('command', (ide / 'build_tools/bin/make.exe').as_posix())
            node.set('buildPath', '${workspace_loc:/' + project_name + '}')
        if node.tag == 'option' and node.get('valueType') == 'includePath':
            node[:] = []
            ET.SubElement(node, 'listOptionValue', {'builtIn': 'false', 'value': debug.as_posix()})
    save_xml(project / '.cproject', cproject, cproject=True)

    for name in ('uart_keyboard_test', 'survival_game'):
        elf = project / 'firmware' / (name + '.elf')
        if not elf.is_file():
            raise FileNotFoundError(elf)
        launch = ET.parse(package / 'tools/launch_template.xml').getroot()
        updates = {
            OCD + 'gdbServerExecutable': (ide / 'openocd/bin/openocd.exe').as_posix(),
            'org.eclipse.cdt.dsf.gdb.DEBUG_NAME': (ide / 'toolchain/bin/riscv-none-elf-gdb.exe').as_posix(),
            OCD + 'gdbServerOther':
                "-c 'set bsp_loc {" + debug.as_posix() + "}'\n"
                + "-f '" + (debug / 'ftdi_ti.cfg').as_posix() + "'\n"
                + "-f '" + (debug / 'debug_ti.cfg').as_posix() + "'",
            OCD + 'targetRegFile': (debug / 'sapphire_soc_32bit-reg.xml').as_posix(),
            'ilg.gnumcueclipse.debug.gdbjtag.svdPath': (debug / 'sapphire_soc_xsvd.json').as_posix(),
            CDT + 'PROGRAM_NAME': elf.as_posix(),
            CDT + 'PROJECT_ATTR': project_name,
            # CDT: disabled=0, enabled=1, workspace preference=2.
            CDT + 'ATTR_BUILD_BEFORE_LAUNCH_ATTR': '0',
            CORE + 'imageFileName': elf.as_posix(),
            CORE + 'symbolsFileName': elf.as_posix(),
            CORE + 'pcRegister': 'f9000000',
            CORE + 'setPcRegister': 'true',
            CORE + 'useFileForImage': 'true',
            CORE + 'useFileForSymbols': 'true',
            CORE + 'useProjBinaryForImage': 'false',
            CORE + 'useProjBinaryForSymbols': 'false',
            CORE + 'loadImage': 'true',
            CORE + 'loadSymbols': 'true',
            CORE + 'setStopAt': 'true',
            CORE + 'stopAt': 'main',
            CORE + 'setResume': 'false',
            OCD + 'doContinue': 'false',
            'com.ashling.riscfree.debug.opxd.core.isRTOSDebug': 'false',
            OCD + 'enableSemihosting': 'false',
        }
        existing = {node.get('key'): node for node in launch}
        for key, value in updates.items():
            if key not in existing:
                raise ValueError('调试模板缺少属性：' + key)
            existing[key].set('value', value)
        mapped = existing['org.eclipse.debug.core.MAPPED_RESOURCE_PATHS']
        mapped[:] = []
        ET.SubElement(mapped, 'listEntry', {'value': '/' + project_name})
        save_xml(project / (name + '_ti.launch'), launch)


def check(package, ide):
    project = package / 'ide_project'
    debug = project / 'openocd'
    project_tree = ET.parse(project / '.project').getroot()
    assert project_tree.find('name').text == 'advanced_board_debug'
    assert not list(project_tree.find('buildSpec')), '调试项目不应有自动构建任务'
    ftdi = (debug / 'ftdi_ti.cfg').read_text(encoding='utf8')
    target = (debug / 'debug_ti.cfg').read_text(encoding='utf8')
    assert 'ftdi channel 1' in ftdi and 'ftdi vid_pid 0x0403 0x6011' in ftdi
    assert 'ftdi device_desc "Quad RS232-HS"' in ftdi
    assert 'set proj_loc $bsp_loc' in target and '[info script]' not in target
    assert '-work-area-phys 0xf900fc00 -work-area-size 1024' in target
    for include in re.findall(r'href="([^"]+)"',
                              (debug / 'sapphire_soc_32bit-reg.xml').read_text(encoding='utf8')):
        assert (debug / include).is_file(), include
    for name, result_symbol in (('uart_keyboard_test', 'g_uart_keyboard_result'),
                                 ('survival_game', 'g_game_result')):
        launch = project / (name + '_ti.launch')
        properties = {node.get('key'): node.get('value') for node in ET.parse(launch).getroot()}
        elf = (project / 'firmware' / (name + '.elf')).as_posix()
        for key in (CDT + 'PROGRAM_NAME', CORE + 'imageFileName', CORE + 'symbolsFileName'):
            assert properties[key] == elf, (key, properties[key])
        assert properties[CDT + 'ATTR_BUILD_BEFORE_LAUNCH_ATTR'] == '0'
        assert properties[CORE + 'pcRegister'] == 'f9000000'
        assert properties[OCD + 'doContinue'] == 'false'
        for key in (OCD + 'gdbServerExecutable', 'org.eclipse.cdt.dsf.gdb.DEBUG_NAME',
                    OCD + 'targetRegFile', 'ilg.gnumcueclipse.debug.gdbjtag.svdPath'):
            assert Path(properties[key]).is_file(), (key, properties[key])
        result = subprocess.run([
            str(ide / 'toolchain/bin/riscv-none-elf-gdb.exe'), '--batch', '--nx',
            '-ex', 'file "' + elf + '"', '-ex', 'info address ' + result_symbol,
            '-ex', 'print /x 0xf9000000',
        ], capture_output=True, text=True, timeout=20)
        if result.returncode or result_symbol not in result.stdout:
            raise RuntimeError(result.stdout + result.stderr)
        print(result.stdout.strip())
        subprocess.run([sys.executable, '-B', str(package / 'tools/check_apb_debug.py'),
                        '--launch', str(launch), '--ide-root', str(ide)], check=True, timeout=40)
    print('PASS 两个 ELF 的下载路径、符号路径、入口地址和无硬件 OpenOCD 配置检查')
    print('待接板验证：USB 驱动、JTAG、COM 通道和实际下载运行。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--ide-root', type=Path, default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    package, ide = args.package.resolve(), args.ide_root.resolve()
    if not (package / 'tools/launch_template.xml').is_file():
        parser.error('请使用 --package 指定生成的烧录包目录。')
    if not args.check_only:
        refresh(package, ide)
    check(package, ide)


if __name__ == '__main__':
    main()

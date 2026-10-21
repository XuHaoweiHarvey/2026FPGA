"""Prepare project-owned IDE metadata/OpenOCD copy, leaving generated BSP read-only."""
from pathlib import Path
import argparse
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
project = ROOT / 'software/apb_reg_test'
bsp_root = ROOT / 'embedded_sw/soc_control'
bsp = bsp_root / 'bsp/efinix/EfxSapphireSoc'
reference = ROOT / ('demo/08_Ti60F225_hardjtag_demo/par/ddr_demo_ti60/'
                    'embedded_sw/soc/software/standalone/gpio/gpioDemo')
ide = Path('D:/Efinity/efinity-riscv-ide-2026.1')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--debug-only', action='store_true', help='Preserve IDE project/build metadata')
args = parser.parse_args()

def write_xml(path, tree, cproject=False):
    ET.indent(tree, space='    ')
    body = ET.tostring(tree, encoding='unicode')
    prefix = '<?xml version="1.0" encoding="UTF-8"?>\n'
    if cproject:
        prefix += '<?fileVersion 4.0.0?>\n'
    path.write_text(prefix + body + '\n', encoding='utf8')

if not args.debug_only:
    description = ET.parse(reference / '.project').getroot()
    description.find('name').text = 'apb_reg_test'
    links = description.find('linkedResources')
    links.clear()
    for name, location in [('common', bsp_root / 'software/standalone/common'), ('bsp', bsp)]:
        link = ET.SubElement(links, 'link')
        ET.SubElement(link, 'name').text = name
        ET.SubElement(link, 'type').text = '2'
        ET.SubElement(link, 'location').text = location.as_posix()
    write_xml(project / '.project', description)

    cp = ET.parse(reference / '.cproject').getroot()
    for node in cp.iter():
        for key, value in list(node.attrib.items()):
            node.set(key, value.replace('gpioDemo', 'apb_reg_test'))
        if node.tag == 'builder':
            node.set('command', (ide / 'build_tools/bin/make.exe').as_posix())
            node.set('buildPath', '${workspace_loc:/apb_reg_test}')
            node.set('autoBuildTarget', 'all')
            node.set('incrementalBuildTarget', 'all')
            node.set('cleanBuildTarget', 'clean')
        if node.tag == 'option' and node.get('valueType') == 'includePath':
            node[:] = []
            for path in (bsp / 'include', ide / 'toolchain/riscv-none-elf/include', project):
                ET.SubElement(node, 'listOptionValue', {'builtIn':'false', 'value':path.as_posix()})
        if node.tag == 'option' and node.get('valueType') == 'definedSymbols':
            node[:] = []
    write_xml(project / '.cproject', cp, True)

openocd = project / 'openocd'
openocd.mkdir(exist_ok=True)
ftdi = (bsp / 'openocd/ftdi_ti.cfg').read_text(encoding='utf8')
assert 'ftdi vid_pid 0x0403 0x6011' in ftdi and 'ftdi channel 1' in ftdi
ftdi, count = re.subn(r'(?m)^(\s*ftdi device_desc )"[^"]*"',
                     r'\1"Quad RS232-HS"', ftdi)
assert count == 1
(openocd / 'ftdi_ti.cfg').write_text(ftdi, encoding='utf8')
soc_h = (bsp / 'include/soc.h').read_text(encoding='utf8')
ram_base = int(re.search(r'^#define SYSTEM_RAM_A_CTRL (0x[0-9a-fA-F]+)', soc_h, re.M)[1], 0)
ram_size = int(re.search(r'^#define SYSTEM_RAM_A_CTRL_SIZE (0x[0-9a-fA-F]+)', soc_h, re.M)[1], 0)
# The generated work area is at RAM base, overlapping a RAM-only application's
# entry code. Move it to the last 1 KiB; build_apb_software checks no ELF/stack
# allocation reaches that reservation. Only this project-owned cfg is changed.
debug = (bsp / 'openocd/debug_ti.cfg').read_text(encoding='utf8')
debug, count = re.subn(r'-work-area-phys 0xF9000000 -work-area-size 1024',
                      f'-work-area-phys {ram_base+ram_size-1024:#010x} -work-area-size 1024', debug)
assert count > 0
# gpioDemo's generated script searches parents for its BSP. Our project is
# outside that tree, so use the same explicit bsp_loc argument as gpioDemo's
# successful launch, with no cwd change or Jim [info script] dependency.
start = debug.index('    # Initialize proj_loc')
end = debug.index('    adapter speed 800', start)
debug = debug[:start] + '    set proj_loc $bsp_loc\n\n' + debug[end:]
(openocd / 'debug_ti.cfg').write_text(debug, encoding='utf8')
(openocd / 'sapphire.cfg').write_text(
    '# Compatibility entry for existing IDE configurations; no [info script].\n'
    + 'set bsp_loc {' + bsp_root.as_posix() + '}\n'
    + 'source {' + (openocd/'ftdi_ti.cfg').as_posix() + '}\n'
    + 'source {' + (openocd/'debug_ti.cfg').as_posix() + '}\n', encoding='utf8')

launch_path = project / 'apb_reg_test_ti.launch'
# Preserve IDE-added resource mapping and user settings when refreshing debug.
launch = ET.parse(launch_path if launch_path.exists() else reference / 'gpioDemo_ti.launch').getroot()
updates = {
    'com.ashling.riscfree.debug.opxd.core.isRTOSDebug':'false',
    'ilg.gnumcueclipse.debug.gdbjtag.openocd.enableSemihosting':'false',
    'ilg.gnumcueclipse.debug.gdbjtag.openocd.gdbServerOther':
        ("-c 'set bsp_loc {" + bsp_root.as_posix() + "}'\n"
         + "-f '" + (openocd/'ftdi_ti.cfg').as_posix() + "'\n"
         + "-f '" + (openocd/'debug_ti.cfg').as_posix() + "'"),
    'ilg.gnumcueclipse.debug.gdbjtag.openocd.targetRegFile':
        (bsp / 'openocd/sapphire_soc_32bit-reg.xml').as_posix(),
    'ilg.gnumcueclipse.debug.gdbjtag.svdPath':
        (bsp / 'openocd/sapphire_soc_xsvd.json').as_posix(),
    'org.eclipse.cdt.debug.gdbjtag.core.setPcRegister':'true',
    # The IDE prepends 0x to this hexadecimal field; keep digits only.
    'org.eclipse.cdt.debug.gdbjtag.core.pcRegister':format(ram_base, 'x'),
    'org.eclipse.cdt.launch.PROGRAM_NAME':'build/apb_reg_test.elf',
    'org.eclipse.cdt.launch.PROJECT_ATTR':'apb_reg_test',
}
for node in launch:
    if node.get('key') in updates:
        node.set('value', updates[node.get('key')])
write_xml(project / 'apb_reg_test_ti.launch', launch)
assert not any('D:\\Efinity\\projects' in node.get('value','') for node in launch)
print('Prepared apb_reg_test IDE project + Titanium Hard JTAG launch; generated BSP untouched.')

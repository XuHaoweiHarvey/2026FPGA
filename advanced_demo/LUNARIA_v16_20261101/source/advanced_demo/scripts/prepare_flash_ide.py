"""Create a separate project/three launch files using the existing team IDE profile.

Run prepare_apb_ide.py --debug-only first when moving the repository: its project
owns the already-verified FT4232HL hard-JTAG adapter and OCRAM work-area profile.
This script does not launch OpenOCD or modify the board.
"""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--ide-root',type=Path,default=Path('C:/Efinity/efinity-riscv-ide-2026.1'))
a=p.parse_args();project=ROOT/'software/flash';reference=ROOT/'software/apb_reg_test'
def save(path,tree,cproject=False):
    ET.indent(tree,space='    ')
    prefix='<?xml version="1.0" encoding="UTF-8"?>\n'
    if cproject:prefix+='<?fileVersion 4.0.0?>\n'
    path.write_text(prefix+ET.tostring(tree,encoding='unicode')+'\n',encoding='utf8')
tree=ET.parse(reference/'.project').getroot();tree.find('name').text='game_flash'
links=tree.find('linkedResources')
if links is not None:tree.remove(links)
save(project/'.project',tree)
tree=ET.parse(reference/'.cproject').getroot()
for node in tree.iter():
    for key,value in list(node.attrib.items()):node.set(key,value.replace('apb_reg_test','game_flash'))
    if node.tag=='builder':
        node.set('command',(a.ide_root/'build_tools/bin/make.exe').as_posix())
        node.set('buildPath','${workspace_loc:/game_flash}')
        node.set('autoBuildTarget','game');node.set('incrementalBuildTarget','game')
    if node.tag=='option' and node.get('valueType')=='includePath':
        node[:]=[]
        for path in (ROOT/'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include',project):
            ET.SubElement(node,'listOptionValue',{'builtIn':'false','value':path.as_posix()})
save(project/'.cproject',tree,True)
for name,elf in [('game','../interactive_demo/build/game/survival_game.elf'),
                 ('probe','build/flash-probe/flash_probe.elf'),
                 ('maintenance','build/flash-maint/flash_maint.elf')]:
    tree=ET.parse(reference/'apb_reg_test_ti.launch').getroot()
    for node in tree:
        key=node.get('key','')
        if key=='org.eclipse.cdt.launch.PROGRAM_NAME':node.set('value',elf)
        elif key in ('org.eclipse.cdt.debug.gdbjtag.core.imageFileName',
                     'org.eclipse.cdt.debug.gdbjtag.core.symbolsFileName'):
            node.set('value',(project/elf).resolve().as_posix())
        elif key=='org.eclipse.cdt.launch.PROJECT_ATTR':node.set('value','game_flash')
        elif key=='org.eclipse.debug.core.MAPPED_RESOURCE_PATHS':
            for entry in node:entry.set('value','/game_flash')
        elif node.get('value'):
            value=node.get('value')
            value=value.replace('D:/Efinity/efinity-riscv-ide-2026.1',a.ide_root.as_posix())
            node.set('value',value)
    save(project/(name+'_ti.launch'),tree)
print('PASS game_flash IDE project + game/probe/maintenance launch profiles')

"""Read-only checks of reset RAM, physical SPI interface, bitstream and IDE paths."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--require-bitstream',action='store_true')
p.add_argument('--hardware-dir',type=Path,default=ROOT/'outflow')
a=p.parse_args()
bytes_at_reset=[]
for i in range(4):
    path=ROOT/f'ip/soc_control/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin'
    rows=path.read_text().splitlines();assert len(rows)==16384
    bytes_at_reset.append(int(rows[0],2))
assert bytes(bytes_at_reset)==bytes.fromhex('6f000000'),'Reset must park, never boot from asset offset zero'
print('PASS generated RAM starts with RV32 jal x0,0 at 0xF9000000')
for launch in ('game','maintenance','probe'):
    tree=ET.parse(ROOT/f'software/flash/{launch}_ti.launch').getroot()
    attrs={n.get('key'):n.get('value') for n in tree}
    for name in ('imageFileName','symbolsFileName'):
        path=Path(attrs['org.eclipse.cdt.debug.gdbjtag.core.'+name])
        assert path.is_file() and path.suffix=='.elf',path
        assert ROOT.resolve() in path.resolve().parents,path
    assert attrs['org.eclipse.cdt.debug.gdbjtag.core.pcRegister']=='f9000000'
print('PASS three IDE launches use the local game/probe/maintenance ELF and OCRAM entry')
if a.require_bitstream:
    for ext in ('lpf','interface.csv','bit','hex'):
        path=a.hardware_dir/f'ti60f225_oob.{ext}'
        assert path.is_file() and path.stat().st_size>0,path
    import csv
    rows=list(csv.reader((a.hardware_dir/'ti60f225_oob.interface.csv').read_text().splitlines()))
    flat='\n'.join(','.join(row) for row in rows)
    for name in ('flash_cs_n','flash_sck','flash_mosi','flash_miso'):assert name in flat
    print('PASS real physical interface, LPF, .bit and .hex files exist (no board access)')

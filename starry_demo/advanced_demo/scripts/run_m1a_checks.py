"""M1a protocol checks against the generated Sapphire upsizer and local bridge.

The whole vendor netlist contains encrypted sections that Icarus cannot parse;
extract one unchanged public generated module into a temporary compile unit.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iverilog',default='iverilog')
parser.add_argument('--vvp',default='vvp')
args=parser.parse_args()
source=(root/'ip/soc_control/source/hardware/netlist/EfxSapphireSoc.v').read_text()
start=source.index('module BmbUpSizerBridge (')
end=source.index('endmodule',start)+len('endmodule')
module=source[start:end]+'\n'
assert module.count('module BmbUpSizerBridge')==1
print('Generated BmbUpSizerBridge SHA256:',hashlib.sha256(module.encode()).hexdigest(),flush=True)
with tempfile.TemporaryDirectory(prefix='fpga-m1a-checks-') as temp:
    out=Path(temp)
    generated=out/'BmbUpSizerBridge.v'
    generated.write_text(module)
    for name,files in (
        ('tb_sapphire_ddr_lane',[root/'sim/tb_sapphire_ddr_lane.v',generated]),
        ('tb_cpu_ddr_bridge',[root/'sim/tb_cpu_ddr_bridge.v',root/'rtl/framebuffer/cpu_ddr_bridge.v']),
    ):
        binary=out/(name+'.vvp')
        subprocess.run([args.iverilog,'-g2012','-s',name,'-o',str(binary),*(str(f) for f in files)],check=True)
        subprocess.run([args.vvp,str(binary)],check=True)

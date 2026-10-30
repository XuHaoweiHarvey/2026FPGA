"""Regenerate SPI0 using the installed Efinity IP Manager (never patch vendor RTL).

Run with Efinity's Python after setup.bat. Back up your checkout first: this
regenerates SoC/BSP output. UART/DDR/OCRAM/debug configuration is preserved.
"""
import argparse
import os
from pathlib import Path
import sys

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--efinity-home',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
home=args.efinity_home.resolve()
os.environ['EFINITY_HOME']=str(home)
os.environ['EFXIPM_HOME']=str(home/'ipm')
os.environ.setdefault('EFINITY_USER_DIR',str(root/'output/ipm-user'))
(root/'output/ipm-user').mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(home/'ipm/bin'))
from efx_ipmgr.api_v2 import IPManagerBackend, IPGenerationSetting
setting=IPGenerationSetting.load(root/'ip/soc_control/settings.json')
setting.params['SPI0']="1'b1"
setting.params['HexFile_PathEnable']="1'b1"
setting.params['HexFile_Path']='"software/flash/jtag_wait.hex"'

backend=IPManagerBackend.singleton()
backend.load(setting.vlnv,device='Ti60F225',family='Titanium')
params=setting.get_formatted_params(backend.get_ip_params(setting.vlnv))
targets=setting.get_formatted_outputs()
result=backend.generate_ip(setting.vlnv,params,targets,'soc_control',
    proj_path=root,user_proj_path=root,user_ip_location=root,
    device='Ti60F225',family='Titanium',project_name='ti60f225_oob',
    project_xml_path=str(root/'ti60f225_oob.xml'),
    peri_xml_file_path=str(root/'ti60f225_oob.peri.xml'))
if result is None: raise SystemExit('IP generation failed')
result.save(root/'ip/soc_control/settings.json')
print('PASS vendor-generated SPI0 SoC/BSP; next check physical pin bindings.')

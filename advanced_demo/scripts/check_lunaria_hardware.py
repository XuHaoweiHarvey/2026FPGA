"""Verify the completed v12 flow, final timing, and compiled source snapshot."""
from pathlib import Path
import hashlib
import json
import re
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'output/lunaria_v12_hardware'
OUT=ROOT/'output/lunaria/verification'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
source=json.loads((BUILD/'source_manifest.json').read_text(encoding='utf8'))
normalized=[]
for name,digest in source['sources'].items():
    if sha(BUILD/name)!=digest:
        # Efinity strips the final XML newline when updating its project.
        assert name=='ti60f225_oob.xml' and sha(ROOT/name)==digest
        assert (BUILD/name).read_bytes().rstrip(b'\r\n')==(ROOT/name).read_bytes().rstrip(b'\r\n')
        normalized.append(name)
    if name.startswith('rtl/') and name!='rtl/ti60f225_oob_top.v':
        assert sha(ROOT/name)==digest,'RTL differs from compiled source: '+name
top=(ROOT/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
for name in ('DISPLAY_WINDOW_ENABLE','DISPLAY_SCALE2_ENABLE','ALPHA_STREAM_ENABLE',
             'ALPHA_SPRITE_CACHE_ENABLE','ALPHA_WIDE_CACHE_ENABLE'):
    top=top.replace(f'parameter {name} = 0,',f'parameter {name} = 1,')
top=top.replace('parameter [31:0] HARDWARE_VERSION = 0,',"parameter [31:0] HARDWARE_VERSION = 32'h000c0000,")
assert top==(BUILD/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
flow=(BUILD/'outflow/ti60f225_oob.log').read_text(encoding='utf8',errors='replace')
for stage in ('map','pgm'):assert 'Stage completed: '+stage in flow
timing=BUILD/'outflow/ti60f225_oob.timing.rpt'
text=timing.read_text(encoding='utf8',errors='replace')
summary=text.split('Setup (Max) Clock Relationship',1)[1].split('---------- Clock Relationship Summary (end)',1)[0]
rows=re.findall(r'^(\S+)\s+(\S+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\(',summary,re.M)
assert len(rows)>20
assert all(float(row[3])>=0 for row in rows), 'Negative final setup/hold slack'
fmax=text.split('Maximum possible analyzed clocks frequency',1)[1].split('Geomean',1)[0]
core=re.search(r'^core_clk\s+([0-9.]+)\s+([0-9.]+)',fmax,re.M)
assert core and float(core[2])>=100
bit=BUILD/'outflow/ti60f225_oob.bit'
assert bit.stat().st_size>100000
render=json.loads((OUT/'render-checks.json').read_text())
assert render['status']=='passed' and render['rgb_exact_match']
legacy=ROOT/'output/lunaria-alpha-legacy-checks.log'
assert 'PASS Alpha arithmetic/DMA/APB' in legacy.read_text(encoding='utf8',errors='replace')
debug=ROOT/'output/lunaria-debug-regression.log'
assert 'Ran 35 tests' in debug.read_text(encoding='utf8',errors='replace') and '\nOK' in debug.read_text(encoding='utf8',errors='replace')
report={'status':'passed','hardware_version':'0x000c0000','capabilities':'0x0000fffb',
    'core_clock_hz':100000000,'analyzed_core_fmax_mhz':float(core[2]),
    'minimum_reported_setup_or_hold_slack_ns':min(float(row[3]) for row in rows),
    'clock_relationship_rows_checked':len(rows),'bit_sha256':sha(bit),'timing_sha256':sha(timing),
    'source_manifest_sha256':sha(BUILD/'source_manifest.json'),
    'efinity_final_newline_normalization':normalized,
    'board_tested':False,'stable_60_fps_measured':False,
    'sources':{name:sha(ROOT/name) for name in ('scripts/prepare_lunaria_hardware.py',
        'scripts/check_lunaria_hardware.py','rtl/accelerator/alpha_blit_engine.v',
        'rtl/accelerator/graphics_engine.v','rtl/framebuffer/rgb_framebuffer.v','rtl/ti60f225_oob_top.v')},
    'legacy_alpha_log_sha256':sha(legacy),'debug_log_sha256':sha(debug)}
(OUT/'hardware-v12-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print(json.dumps({k:v for k,v in report.items() if k!='sources'},indent=2))

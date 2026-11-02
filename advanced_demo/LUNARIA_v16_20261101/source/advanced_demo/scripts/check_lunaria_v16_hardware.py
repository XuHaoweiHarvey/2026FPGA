"""Gate v16 delivery on current RTL, successful flow and final timing."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'output/lunaria_v16_hardware'
OUT=ROOT/'output/lunaria_v16_candidate/verification'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
source=json.loads((BUILD/'source_manifest.json').read_text(encoding='utf8'))
assert source['hardware_version']=='0x00100000' and source['capabilities']=='0x000ffffb'
assert source['read_outstanding']==1 and source['tile_compositor']
normalized=[]
for name,digest in source['sources'].items():
    if sha(BUILD/name)!=digest:
        assert name=='ti60f225_oob.xml' and sha(ROOT/name)==digest
        assert (BUILD/name).read_bytes().rstrip(b'\r\n')==(ROOT/name).read_bytes().rstrip(b'\r\n')
        normalized.append(name)
    if name.startswith('rtl/') and name!='rtl/ti60f225_oob_top.v':
        assert sha(ROOT/name)==digest,'Compiled source differs: '+name
top=(ROOT/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
for name in ('DISPLAY_WINDOW_ENABLE','DISPLAY_SCALE2_ENABLE','ALPHA_STREAM_ENABLE',
 'ALPHA_SPRITE_CACHE_ENABLE','ALPHA_WIDE_CACHE_ENABLE','BEAM_ENABLE',
 'ALPHA_OVERLAP_ENABLE','ALPHA_READ_AHEAD_ENABLE','TILE_COMPOSITOR_ENABLE'):
    top=top.replace(f'parameter {name} = 0,',f'parameter {name} = 1,')
top=top.replace('parameter [31:0] HARDWARE_VERSION = 0,',"parameter [31:0] HARDWARE_VERSION = 32'h00100000,")
assert top==(BUILD/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
flow=(BUILD/'outflow/ti60f225_oob.log').read_text(encoding='utf8',errors='replace')
for stage in ('map','pgm'):assert 'Stage completed: '+stage in flow
timing=BUILD/'outflow/ti60f225_oob.timing.rpt'
text=timing.read_text(encoding='utf8',errors='replace')
summary=text.split('Setup (Max) Clock Relationship',1)[1].split('---------- Clock Relationship Summary (end)',1)[0]
rows=re.findall(r'^(\S+)\s+(\S+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\(',summary,re.M)
assert len(rows)>20 and all(float(r[3])>=0 for r in rows),'Final timing failure'
fmax=text.split('Maximum possible analyzed clocks frequency',1)[1].split('Geomean',1)[0]
core=re.search(r'^core_clk\s+([0-9.]+)\s+([0-9.]+)',fmax,re.M)
assert core and float(core[2])>=100
placement=(BUILD/'outflow/ti60f225_oob.place.rpt').read_text(encoding='utf8',errors='replace')
ram=re.search(r'Memory Blocks:\s*(\d+)\s*/\s*(\d+)',placement)
assert ram and int(ram[1])<=int(ram[2])
checks={}
paths={'tile-fault':'output/lunaria_v16_faults/checks.json',
 'tile-contract':'output/lunaria_v16_contract/checks.json',
 'tile-trace':'output/lunaria_v16_trace/trace-tile-checks.json',
 'integration':'output/lunaria_v16_integration_final/checks.json',
 'queue':'output/lunaria_v16_queue/checks.json',
 'legacy-ddr':'output/lunaria_v15_checks/checks.json',
 'upload':'output/lunaria_v151_upload/checks.json'}
for label,name in paths.items():
    report=json.loads((ROOT/name).read_text(encoding='utf8'))
    assert report['status']=='passed',name
    for filename,digest in report['sources'].items():assert sha(ROOT/filename)==digest,filename
    checks[label]={'path':name,'sha256':sha(ROOT/name)}
for label,needle in (('alpha-legacy','PASS Alpha arithmetic/DMA/APB'),('debug','Ran 35 tests'),
 ('integration','PASS shared Alpha:'),('queue','PASS v7 queue: nine ordered DMA fills')):
    log=ROOT/f'output/lunaria-v16-{label}.log';content=log.read_text(encoding='utf8',errors='replace')
    assert needle in content and 'FAILED (' not in content and 'FATAL:' not in content,label
    checks[label+'-log']={'path':log.relative_to(ROOT).as_posix(),'sha256':sha(log)}
bit=BUILD/'outflow/ti60f225_oob.bit';assert bit.stat().st_size>100000
report=dict(status='passed',hardware_version='0x00100000',capabilities='0x000ffffb',
 core_clock_hz=100000000,analyzed_core_fmax_mhz=float(core[2]),
 minimum_reported_setup_or_hold_slack_ns=min(float(r[3]) for r in rows),
 clock_relationship_rows_checked=len(rows),ram_blocks_used=int(ram[1]),ram_blocks_total=int(ram[2]),
 bit_sha256=sha(bit),timing_sha256=sha(timing),source_manifest_sha256=sha(BUILD/'source_manifest.json'),
 board_tested=False,stable_60_fps_measured=False,read_outstanding=1,
 checks=checks,efinity_xml_normalization=normalized,
 sources={n:sha(ROOT/n) for n in ('scripts/check_lunaria_v16_hardware.py','scripts/prepare_lunaria_v16_hardware.py',
 'rtl/accelerator/tiled_graphics_engine.v','rtl/accelerator/alpha_blit_engine.v',
 'rtl/framebuffer/rgb_framebuffer.v','rtl/framebuffer/buffer_manager.v','rtl/ti60f225_oob_top.v')})
(OUT/'hardware-v16-checks.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('checks','sources')},indent=2))

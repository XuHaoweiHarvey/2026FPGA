"""Offline RTL guard/ownership tests and compiled firmware memory checks."""
from pathlib import Path
import os
import hashlib
import json
import re
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import ElfImage, RAM_START, RAM_END
elf=ROOT/'software/lunaria/build/lunaria.elf'
image=ElfImage(elf)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert image.symbols['__stack_size'][0]==8192
assert image.symbol('_sp')<=RAM_END
assert image.symbol_u32('g_lunaria_settings',10)==4096
assert image.symbols['game'][1]<1024, 'Bullet pool accidentally included in OCRAM'
frames=[]
for path in elf.parent.glob('*.su'):
    for line in path.read_text().splitlines():
        name,size,kind=line.split('\t')
        assert kind=='static',line
        frames.append({'function':name.split(':')[-1],'bytes':int(size)})
assert frames and sum(row['bytes'] for row in frames)<8192
soc=(ROOT/'ip/soc_control/soc_control.v').read_text(encoding='utf8',errors='replace')
assert 'DBusSimplePlugin' in soc and 'DBusCachedPlugin' not in soc
cases=[('tb_cpu_ddr_bridge',['sim/tb_cpu_ddr_bridge.v','rtl/framebuffer/cpu_ddr_bridge.v'],
        ['-Ptb_cpu_ddr_bridge.SPRITE_ENABLE=1']),
       ('tb_buffer_manager',['sim/tb_buffer_manager.v','rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v'],[]),
       ('tb_alpha_pixel_pipeline',['sim/tb_alpha_pixel_pipeline.v','rtl/accelerator/alpha_pixel_pipeline.v'],[])]
outputs={};sources=set()
with tempfile.TemporaryDirectory(prefix='lunaria-memory-') as folder:
    for top,files,options in cases:
        binary=Path(folder)/(top+'.vvp')
        subprocess.run(['iverilog','-g2005-sv','-s',top,*options,'-o',str(binary),*files],cwd=ROOT,check=True)
        result=subprocess.run(['vvp',str(binary)],cwd=ROOT,capture_output=True,text=True,check=True)
        assert 'PASS' in result.stdout
        outputs[top]=result.stdout; sources.update(files)
        print(result.stdout.splitlines()[0])
sources.update(('scripts/run_lunaria_memory_checks.py','software/lunaria/main.c','software/lunaria/lunaria_pool.c',
                'software/lunaria/lunaria_pool.h','ip/soc_control/soc_control.v'))
report={'status':'passed','board_tested':False,'elf_sha256':sha(elf),
        'ocram_including_stack':image.symbol('_sp')-RAM_START,
        'stack_reserved_bytes':8192,'headroom_before_debug_reserved':RAM_END-image.symbol('_sp'),
        'largest_compiler_reported_C_frame':max(row['bytes'] for row in frames),
        'sum_compiler_reported_C_frames':sum(row['bytes'] for row in frames),
        'stack_scope':'GCC static C frames; not a measured high-water mark or library call-graph bound',
        'cpu_data_bus':'generated DBusSimplePlugin (no data cache)',
        'scratch_per_slot':[0x10000,0x30000],'source_window_first_byte':300*7680+640*4,
        'rtl_results':outputs,'sources':{name:sha(ROOT/name) for name in sorted(sources)}}
(Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))/'verification/memory-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print(f'PASS OCRAM {report["ocram_including_stack"]} bytes incl 8192 stack; headroom {report["headroom_before_debug_reserved"]}')

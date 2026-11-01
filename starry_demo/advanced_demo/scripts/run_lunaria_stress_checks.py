"""Exercise the actual stress build, preview renderer, ELF and stress UI offline."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import tkinter as tk
from PIL import Image
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_debug_bridge import LunariaBridge, read_assets
from lunaria_debug_window import LunariaWindow
from run_lunaria_checks import rasterize

compiler = next((c for c in ('cl','gcc','clang','cc') if shutil.which(c)),None)
if not compiler: raise SystemExit('Use an initialized MSVC terminal')
with tempfile.TemporaryDirectory(prefix='lunaria-stress-check-') as directory:
    temp=Path(directory);exe=temp/'stress.exe';trace=temp/'trace.bin'
    units=[ROOT/'sim/test_lunaria_stress.c',ROOT/'software/lunaria/lunaria.c',ROOT/'software/lunaria/lunaria_render.c']
    flags=['/nologo','/TC','/W4','/WX','/O2','/D_CRT_SECURE_NO_WARNINGS','/DLN_STRESS_TEST=1'] if compiler=='cl' else ['-std=c99','-O2','-Wall','-Wextra','-Werror','-DLN_STRESS_TEST=1']
    output=['/Fe:'+str(exe)] if compiler=='cl' else ['-o',str(exe)]
    subprocess.run([compiler,*flags,*map(str,units),*output],cwd=temp,check=True)
    result=subprocess.run([str(exe),str(trace)],text=True,capture_output=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    stress_atlas=Image.frombytes('RGBA',(640,480),(ROOT/'delivery/lunaria_stress/atlas.argb').read_bytes(),'raw','BGRA')
    frames=rasterize(trace,contact_sheets=False,atlas_override=stress_atlas)
delivery=ROOT/'delivery/lunaria_stress'
bridge=LunariaBridge(delivery/'lunaria.elf',assets=delivery/'assets.json')
assert bridge.image.symbol_u32('g_lunaria_stress_test')==1
assert bridge.image.symbol_u32('g_lunaria_settings',10)==832
assert bridge.asset_hashes==[h for _,h in read_assets(delivery/'assets.json')]
# Verify byte-exact visible artwork at all destination residues and global alphas.
old_atlas=Image.open(ROOT/'output/lunaria/atlas.png').convert('RGBA')
old=old_atlas.crop((448,0,464,16));new=stress_atlas.crop((448,64,460,76))
assert new.tobytes()==old.crop((2,2,14,14)).tobytes()
for a in (0,64,128,255):
    for x in range(4):
        before=Image.new('RGBA',(32,32),(13,19,31,255));after=before.copy()
        t=old.copy();u=new.copy()
        t.putalpha(t.getchannel('A').point(lambda v:(v*a+127)//255))
        u.putalpha(u.getchannel('A').point(lambda v:(v*a+127)//255))
        before.alpha_composite(t,(x+4,4));after.alpha_composite(u,(x+6,6))
        assert before.tobytes()==after.tobytes()
# Exercise the same mailbox protocol with an ELF declaring the larger capacity.
import run_lunaria_loader_checks as loader_checks
with patch.object(loader_checks,'DEFAULT_ELF',delivery/'lunaria.elf'):
    fake,address=loader_checks.Checks().settings_fake()
    assert LunariaBridge.configure(fake,832)==1
    assert fake.writes[0]==(address+20,832)
    fake,address=loader_checks.Checks().settings_fake()
    try: LunariaBridge.configure(fake,833)
    except ValueError: pass
    else: raise AssertionError('Accepted over-capacity settings')
    assert not fake.writes
root=tk.Tk();root.withdraw()
try:
    window=LunariaWindow(root,delivery/'lunaria.elf',delivery/'assets.json',stress=True)
    root.update_idletasks()
    assert window.bridge is None and window.invincible.get() and window.stress
    assert window.bullet_limit.get()=='256' and not window.spin_patterns.get()
    assert '压力测试' in root.title() and window.maximum_bullets==832
finally: root.destroy()
# Reuse the existing RTL fixture in a temporary directory: no new project files.
# Exercise the actual 12x12 source and all destination pixel residues on v12.
fixture=(ROOT/'sim/tb_alpha_stream_cache.v').read_text()
fixture=fixture.replace('initial begin','integer stress16_cycles,stress12_cycles;\ninitial begin',1)
fixture=fixture.replace('    if (PIXEL_X) begin', """    if (PIXEL_X) begin
        command(32'h013ac700,2560,33,4,16,16,255,0);
        command(32'h013ac700,2560,33,4,16,16,255,0); stress16_cycles=elapsed;
        command(32'h013ac700,2560,33,4,12,12,255,0); stress12_cycles=elapsed;
        if(stress12_cycles >= stress16_cycles) $fatal(1,"12x12 did not reduce blit cycles");
        $display("PASS stress RTL warm same-source: 16x16=%0d cycles, 12x12=%0d cycles",stress16_cycles,stress12_cycles);
        for(i=0;i<4;i=i+1) begin
            command(32'h013ac700,2560,32+i,4,12,12,255,0);
            command(32'h013ac700,2560,36+i,17,12,12,127,0);
        end
""",1)
with tempfile.TemporaryDirectory(prefix='stress-alpha-') as directory:
    temp=Path(directory);bench=temp/'stress.v';binary=temp/'stress.vvp'
    bench.write_text(fixture)
    subprocess.run(['D:/iverilog/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_alpha_stream_cache',
                    '-Ptb_alpha_stream_cache.STREAM=1','-Ptb_alpha_stream_cache.CACHE=1','-Ptb_alpha_stream_cache.PIXEL_X=1',
                    '-o',str(binary),str(bench),str(ROOT/'rtl/accelerator/alpha_pixel_pipeline.v'),
                    str(ROOT/'rtl/accelerator/alpha_blit_engine.v')],check=True,cwd=ROOT)
    rtl=subprocess.run(['D:/iverilog/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True)
    print(rtl.stdout,end='');print(rtl.stderr,end='');rtl.check_returncode()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report=dict(status='passed',board_tested=False,elf_sha256=sha(delivery/'lunaria.elf'),
            output=result.stdout,rtl_output=rtl.stdout,frames=frames,
            sources={p.relative_to(ROOT).as_posix():sha(p) for p in units+[ROOT/'software/lunaria/lunaria.h',ROOT/'scripts/run_lunaria_stress_checks.py']})
(ROOT/'output/lunaria/verification/stress-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print('PASS stress ELF/assets, 832 mailbox/UI, exact visible artwork and rendered previews')

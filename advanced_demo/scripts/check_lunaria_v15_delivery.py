"""Verify packaged hashes, bit/ELF pairing and packaged UIs without a board."""
from pathlib import Path
import hashlib
import json
import sys
import tkinter as tk
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def check_sums(folder):
    rows=(folder/'SHA256SUMS.txt').read_text(encoding='utf8').splitlines()
    seen=set()
    for row in rows:
        digest,name=row.split('  ',1)
        path=(folder/name).resolve()
        assert path.is_relative_to(folder.resolve()) and name not in seen,name
        assert sha(path)==digest,name
        seen.add(name)
    return len(seen)


def main():
    count=check_sums(OUT)
    previous_count=check_sums(ROOT/'output/lunaria_v14_delivery')
    m=json.loads((OUT/'manifest.json').read_text(encoding='utf8'))
    assert m['recommended_hardware']=='v15' and not m['board_tested']
    assert m['revision']=='v15.1-serial-ddr-compatibility-20261031'
    assert m['read_outstanding']==m['hardware_v15_checks']['read_outstanding']==1
    h=json.loads((OUT/'hardware/v15/source_manifest.json').read_text())
    assert h['read_outstanding']==1 and h['revision']=='v15.1-serial-ddr-compatibility'
    original=ROOT/'output/lunaria_v15_initial_delivery/hardware/v15/ti60f225_oob.bit'
    assert sha(original)!=m['hardware_sha256']['v15']
    assert sha(OUT/'lunaria.elf')==sha(ROOT/'output/lunaria_v15_initial_delivery/lunaria.elf')
    assert m['hardware_sha256']['v15']==sha(OUT/'hardware/v15/ti60f225_oob.bit')
    assert m['hardware_v15_checks']['bit_sha256']==m['hardware_sha256']['v15']
    assert m['hardware_sha256']['v13']==sha(ROOT/'output/lunaria_v13_delivery/hardware/v13/ti60f225_oob.bit')
    assert m['elf_sha256']==sha(OUT/'lunaria.elf')
    assert m['ddr_checks']['status']==m['trace_checks']['status']=='passed'
    assert m['ocram']['stack_bytes']==8192
    for name in ('使用说明.md','DDR优化说明.md'):
        assert '\ufffd' not in (OUT/name).read_text(encoding='utf8'),name
    sys.path.insert(0,str(OUT/'tools'))
    from game_debug_bridge import ElfImage
    from lunaria_debug_bridge import LunariaBridge
    from lunaria_debug_window import LunariaWindow
    from lunaria_pc import Preview
    elf=ElfImage(OUT/'lunaria.elf')
    assert elf.symbol_u32('g_lunaria_v15_compatible')==0x40000
    assert elf.symbol_u32('g_lunaria_v14_compatible')==0x20000
    assert elf.symbols['g_lunaria_timing'][1]==28
    bridge=LunariaBridge(OUT/'lunaria.elf',assets=OUT/'assets.json')
    root=tk.Tk();root.withdraw()
    try:
        window=LunariaWindow(root,OUT/'lunaria.elf',OUT/'assets.json')
        root.update_idletasks()
        assert window.bridge is None and 'v15' in root.title()
        def labels(widget):
            result=[]
            for child in widget.winfo_children():
                if 'text' in child.keys():result.append(str(child.cget('text')))
                result.extend(labels(child))
            return result
        assert 'DDR 诊断 5 秒' in labels(root)
        window.show_status({'phase':4,'hardware_version':0xf0000,'runtime':{},
                            'lunaria_timing':dict(update_us=100,submit_us=200,drain_us=300,swap_us=400)})
    finally:root.destroy()
    root=tk.Tk();root.withdraw()
    try:
        preview=Preview(root,OUT,schedule=False)
        for limit in (64,400,512,768,4096):
            preview.limit.set(str(limit));assert preview.apply_settings()
            assert preview.engine.status()[8]==limit
        preview.phase.set('加速 / 激光');preview.practice()
        for _ in range(180):preview.engine.dll.pc_tick(0)
        preview.draw();root.update_idletasks()
        assert len(preview.engine.pixels())==640*480*3
    finally:root.destroy()
    result=dict(status='passed',packaged_files=count,preserved_v14_files=previous_count,
                bit_sha256=m['hardware_sha256']['v15'],elf_sha256=m['elf_sha256'],
                manifest_sha256=sha(OUT/'manifest.json'),sha256sums_sha256=sha(OUT/'SHA256SUMS.txt'),
                packaged_debug_ui=True,packaged_interactive_preview=True,board_connected=False)
    (ROOT/'output/lunaria-v15-delivery-checks.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()

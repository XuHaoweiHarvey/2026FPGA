"""Verify packaged files and exercise the packaged tools without a board."""
from pathlib import Path
import hashlib,json,sys,tkinter as tk
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria_v16'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def sums(folder,legacy=False):
    seen=set()
    for row in (folder/'SHA256SUMS.txt').read_text(encoding='utf8').splitlines():
        digest,name=row.split('  ',1);path=(folder/name).resolve()
        if legacy and '__pycache__' in Path(name).parts:continue
        assert path.is_relative_to(folder.resolve()) and name not in seen
        assert sha(path)==digest,name
        seen.add(name)
    return len(seen)
def main():
    count=sums(OUT);old=sums(ROOT/'output/lunaria',True);backup=sums(ROOT/'output/lunaria_v151_delivery',True)
    m=json.loads((OUT/'manifest.json').read_text(encoding='utf8'))
    assert m['recommended_hardware']=='v16' and not m['board_tested']
    assert sha(OUT/'lunaria.elf')==m['elf_sha256']
    assert sha(OUT/'hardware/v16/ti60f225_oob.bit')==m['bit_sha256']
    for name,h in m['checks'].items():assert sha(OUT/f'verification/{name}-checks.json')==h
    sys.path.insert(0,str(OUT/'tools'));sys.dont_write_bytecode=True
    from game_debug_bridge import ElfImage
    from lunaria_debug_bridge import LunariaBridge
    from lunaria_debug_window import LunariaWindow
    from lunaria_pc import Preview
    elf=ElfImage(OUT/'lunaria.elf');assert elf.symbol_u32('g_lunaria_v16_compatible')==0x80000
    assert elf.symbols['__stack_size'][0]==8192
    bridge=LunariaBridge(OUT/'lunaria.elf',assets=OUT/'assets.json')
    root=tk.Tk();root.withdraw()
    try:
        window=LunariaWindow(root,OUT/'lunaria.elf',OUT/'assets.json');root.update_idletasks()
        assert window.bridge is None and 'v16' in root.title()
        window.show_status(dict(phase=4,hardware_version=0x100000,runtime={},
            lunaria_timing=dict(update_us=100,submit_us=200,drain_us=300,swap_us=400)))
    finally:root.destroy()
    root=tk.Tk();root.withdraw()
    try:
        preview=Preview(root,OUT,schedule=False)
        for limit in (64,128,256,400,512,768,1024,2048,4096):
            preview.limit.set(str(limit));assert preview.apply_settings()
            assert preview.engine.status()[8]==limit
        preview.phase.set('加速 / 激光');preview.practice()
        for _ in range(180):preview.engine.dll.pc_tick(0)
        preview.draw();root.update_idletasks()
        assert len(preview.engine.pixels())==640*480*3
    finally:root.destroy()
    result=dict(status='passed',packaged_files=count,preserved_delivery_files=old,preserved_backup_files=backup,
        packaged_debug_ui=True,packaged_interactive_preview=True,board_connected=False,
        bit_sha256=m['bit_sha256'],elf_sha256=m['elf_sha256'],manifest_sha256=sha(OUT/'manifest.json'))
    (ROOT/'output/lunaria-v16-delivery-checks.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()

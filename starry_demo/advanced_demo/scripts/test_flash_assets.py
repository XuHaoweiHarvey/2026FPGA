"""Host pack/export/maintenance-script checks with real PNGs and simulated NOR."""
import importlib.util
from pathlib import Path
import re
import struct
import sys
import tempfile
import json
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import flash_assets as assets
import flash_transfer as transfer
from PIL import Image

def rejected(fn):
    try:fn()
    except (ValueError,FileExistsError):return
    raise AssertionError('Expected invalid input rejection')

with tempfile.TemporaryDirectory(prefix='flash-assets-') as temp:
    root=Path(temp);sample=root/'input';assets.sample(sample)
    # User-transparent color-key pixels must become magenta, not black squares.
    with Image.open(sample/'sprite_atlas.png') as im:
        im.putpixel((64,0),(0,0,0,0));im.save(sample/'sprite_atlas.png')
    packed=root/'assets.bin';assets.pack(sample/'manifest.json',packed)
    data=packed.read_bytes();report=assets.inspect(data)
    assert len(data)==0x4c0000
    pixel=report['resources'][3]['offset']+64*4
    assert data[pixel:pixel+4]==bytes.fromhex('ff00ff00')
    damaged=bytearray(data);damaged[-1]^=1;rejected(lambda:assets.inspect(damaged))
    rejected(lambda:assets.inspect(data[:160]));rejected(lambda:assets.pack(sample/'manifest.json',packed))
    extracted=root/'extracted';assets.unpack(packed,extracted)
    repacked=root/'repacked.bin';assets.pack(extracted/'manifest.json',repacked)
    assert repacked.read_bytes()==data
    # Interpret generated restore/set/action commands as a NOR maintenance target.
    upload=root/'upload';transfer.upload(packed,upload)
    nor=bytearray(b'\xff'*0x800000);nor[0x7e0000:]=b'\x5a'*0x20000
    fields={};payload=b'';actions=0
    for line in (upload/'upload.gdb').read_text().splitlines():
        match=re.fullmatch(r'restore (\S+) binary &g_flash_maint.data\[0\]',line)
        if match:payload=Path(match[1]).read_bytes()
        match=re.fullmatch(r'set g_flash_maint\.(\w+) = (\w+)',line)
        if not match:continue
        field,value=match.groups();fields[field]=int(value,0)
        if field!='action':continue
        actions+=1;a=fields['address'];n=fields['length']
        assert a+n<=0x7e0000 and fields['cookie']==0x464c5348
        if fields['action']==2:
            assert a%4096==0 and n==4096;nor[a:a+n]=b'\xff'*n
        else:
            assert fields['action']==3 and len(payload)==n
            assert assets.zlib.crc32(payload)==fields['crc']
            for i,value in enumerate(payload):nor[a+i]&=value
    assert nor[:len(data)]==data and nor[0x7e0000:]==b'\x5a'*0x20000
    # Reconstruct an actual full-image export from independently numbered chunks.
    dump=root/'dump';transfer.dump(dump,0,len(data))
    manifest=json.loads((dump/'chunks.json').read_text())
    for part in manifest['chunks']:
        (dump/part['file']).write_bytes(nor[part['offset']:part['offset']+part['length']])
    joined=root/'joined.bin';transfer.join(dump,joined)
    assert joined.read_bytes()==data;assets.inspect(joined.read_bytes())
    first=dump/manifest['chunks'][0]['file'];first.write_bytes(b'bad')
    rejected(lambda:transfer.join(dump,root/'incomplete.bin'))
    rejected(lambda:transfer.dump(root/'bad',0x7fffff,2))
    print(f'PASS pack/unpack byte-for-byte, PNG transparency, corrupted/truncated data, {actions} guarded upload actions, dump/join, save preservation')

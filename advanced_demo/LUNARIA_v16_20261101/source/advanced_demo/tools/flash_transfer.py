"""Prepare IDE GDB scripts for explicit Flash maintenance; never accesses a board.

Upload scripts operate only on [0,0x7e0000), preserving both save areas.
An interrupted asset update requires another upload; asset updates are not atomic.
Dump scripts use the read-only probe. Join checks each chunk's expected length;
the asset inspector subsequently verifies header/table/pixel CRCs.
"""
import argparse
import json
from pathlib import Path
import zlib

ASSET_END=0x7e0000
FLASH_BYTES=0x800000
CHUNK=2560  # fits the read-only probe and the maintenance firmware

def quoted(path):
    value=Path(path).resolve().as_posix()
    # Shipped GDB restore/dump split the filename at whitespace and treat quotes
    # literally. Fail early rather than generate a script that cannot run.
    if not value.isascii() or any(c.isspace() or c in '\"\'' for c in value):
        raise ValueError('GDB transfer directory must use ASCII characters without spaces or quotes')
    return value

def stop(symbol):
    return [f'tbreak {symbol}','continue']

def checked(commands, obj, expected=None):
    condition=f'{obj}.error != 0'
    if expected is not None:condition+=f' || {obj}.length != {expected}'
    return ['if $flash_abort == 0',*commands,
            f'if {condition}',f'printf "FLASH STOP error=%u\\n", {obj}.error',
            'set $flash_abort = 1','end','end']

def output_dir(path):
    if path.exists() and any(path.iterdir()):raise FileExistsError('Output directory must be empty')
    path.mkdir(parents=True,exist_ok=True)

def upload(source,directory):
    from flash_assets import inspect
    data=source.read_bytes();report=inspect(data)
    # Do not accept an 8-MiB readback as an update image: preserve saves.
    if len(data)!=report['total'] or len(data)>ASSET_END:raise ValueError('Use an exact packed asset image')
    output_dir(directory)
    obj='g_flash_maint'
    lines=['# Load flash_maint.elf and stop at main before sourcing this file.',
           'set pagination off','set confirm off','set $flash_abort = 0',
           *stop('flash_maint_ready'),
           f'if {obj}.error != 0',f'printf "INIT ERROR %u\\n", {obj}.error',
           'set $flash_abort = 1','end']
    # Erase only sectors occupied by this image; the previous pack may be larger.
    # Its unused tail is ignored by the new header's total field.
    for address in range(0,(len(data)+4095)&~4095,4096):
        commands=[f'set {obj}.address = {address}',f'set {obj}.length = 4096',
                  f'set {obj}.cookie = 0x464c5348',f'set {obj}.action = 2',*stop('flash_maint_ready')]
        lines+=checked(commands,obj)
    # Header/table go last, so a partial upload cannot look like a complete pack.
    blocks=list(range(0x10000,len(data),CHUNK))+list(range(0,0x10000,CHUNK))
    for index,address in enumerate(blocks):
        limit=len(data) if address>=0x10000 else 0x10000
        payload=data[address:min(address+CHUNK,limit)]
        part=directory/f'upload_{index:05d}.bin';part.write_bytes(payload)
        commands=[f'restore {quoted(part)} binary &{obj}.data[0]',
                  f'set {obj}.address = {address}',f'set {obj}.length = {len(payload)}',
                  f'set {obj}.crc = {zlib.crc32(payload)}',f'set {obj}.cookie = 0x464c5348',
                  f'set {obj}.action = 3',*stop('flash_maint_ready')]
        lines+=checked(commands,obj)
    lines+=['if $flash_abort == 0','echo FLASH UPLOAD VERIFIED. Load the game ELF next.\\n','end']
    (directory/'upload.gdb').write_text('\n'.join(lines)+'\n',encoding='utf8')
    (directory/'source.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    print(f'Prepared {len(data)} bytes; scripts do not run until sourced in IDE: {directory/"upload.gdb"}')

def dump(directory,offset,length):
    if offset<0 or length<=0 or offset+length>FLASH_BYTES:raise ValueError('Dump range outside Flash')
    output_dir(directory);obj='g_flash_dump'
    lines=['# Load flash_probe.elf and stop at main before sourcing this file.',
           'set pagination off','set confirm off','set $flash_abort = 0',*stop('flash_dump_ready'),
           f'if {obj}.error != 0','set $flash_abort = 1','end']
    parts=[]
    for address in range(offset,offset+length,CHUNK):
        n=min(CHUNK,offset+length-address);name=f'dump_{address:06x}.bin';parts.append(dict(offset=address,length=n,file=name))
        commands=[f'set {obj}.request_offset = {address}',f'set {obj}.request_length = {n}',*stop('flash_dump_ready')]
        lines+=checked(commands,obj,n)
        lines+=['if $flash_abort == 0',f'if {obj}.offset != {address}',
                'set $flash_abort = 1','end','end',
                'if $flash_abort == 0',f'dump binary memory {quoted(directory/name)} &{obj}.data[0] &{obj}.data[{n}]',
                'end']
    lines+=['if $flash_abort == 0','echo FLASH DUMP COMPLETE. Run join on the computer.\\n','end']
    (directory/'dump.gdb').write_text('\n'.join(lines)+'\n',encoding='utf8')
    (directory/'chunks.json').write_text(json.dumps(dict(offset=offset,length=length,chunks=parts),indent=2),encoding='utf8')
    print(directory/'dump.gdb')

def join(directory,output):
    manifest=json.loads((directory/'chunks.json').read_text(encoding='utf8'));data=bytearray();cursor=manifest['offset']
    for part in manifest['chunks']:
        if part['offset']!=cursor:raise ValueError('Missing or out-of-order chunk')
        name=part['file']
        if Path(name).name!=name:raise ValueError('Invalid chunk filename')
        payload=(directory/name).read_bytes()
        if len(payload)!=part['length']:raise ValueError(f'Incomplete chunk: {name}')
        data.extend(payload);cursor+=len(payload)
    if len(data)!=manifest['length']:raise ValueError('Incomplete dump')
    if output.exists():raise FileExistsError(output)
    output.write_bytes(data)
    print(f'{output}: {len(data)} bytes, original Flash offset {manifest["offset"]:#x}, CRC32 {zlib.crc32(data):08x}')

def settings(directory,score,difficulty):
    if not 0<=score<=0xffffffff or difficulty not in (0,1,2):raise ValueError('Invalid save settings')
    output_dir(directory);obj='g_flash_maint'
    lines=['# Explicit save replacement; load flash_maint ELF and halt at main.',
           'set pagination off','set $flash_abort = 0',*stop('flash_maint_ready'),
           f'if {obj}.error != 0','set $flash_abort = 1','end']
    lines+=checked([f'set {obj}.high_score = {score}',f'set {obj}.difficulty = {difficulty}',
                    f'set {obj}.cookie = 0x464c5348',f'set {obj}.action = 4',*stop('flash_maint_ready')],obj)
    lines+=['if $flash_abort == 0','echo SAVE COMMITTED.\\n','end']
    (directory/'settings.gdb').write_text('\n'.join(lines)+'\n',encoding='utf8')
    print(directory/'settings.gdb')

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='cmd',required=True)
    q=sub.add_parser('upload');q.add_argument('input',type=Path);q.add_argument('directory',type=Path)
    q=sub.add_parser('dump');q.add_argument('directory',type=Path);q.add_argument('--offset',type=lambda x:int(x,0),default=0);q.add_argument('--length',type=lambda x:int(x,0),default=0x800000)
    q=sub.add_parser('join');q.add_argument('directory',type=Path);q.add_argument('output',type=Path)
    q=sub.add_parser('settings');q.add_argument('directory',type=Path);q.add_argument('--score',type=int,required=True);q.add_argument('--difficulty',type=int,choices=(0,1,2),required=True)
    a=p.parse_args()
    if a.cmd=='upload':upload(a.input,a.directory)
    elif a.cmd=='dump':dump(a.directory,a.offset,a.length)
    elif a.cmd=='join':join(a.directory,a.output)
    else:settings(a.directory,a.score,a.difficulty)
if __name__=='__main__':main()

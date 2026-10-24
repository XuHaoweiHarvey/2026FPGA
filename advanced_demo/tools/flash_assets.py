"""Pack PNG resources for the current four DDR windows; validate/extract readbacks.

Commands: sample DIR, pack manifest.json assets.bin, inspect assets.bin,
unpack assets.bin DIR, saves flash-readback.bin. Does not access a board.
"""
import argparse
import json
from pathlib import Path
import struct
import zlib

MAGIC=0x53413246
CAPACITY=0x800000
ASSET_END=0x7e0000
SAVE_A=0x7e0000
SAVE_B=0x7f0000
HEADER=struct.Struct('<8I')
ENTRY=struct.Struct('<8I')
NAMES={1:'background0',2:'background1',3:'background2',4:'sprite_atlas'}

def inspect(data):
    if len(data)<160: raise ValueError('Truncated header/table')
    magic,version,hsize,count,total,table_crc,reserved,crc=HEADER.unpack_from(data)
    if (magic,version,hsize,count,reserved)!=(MAGIC,1,32,4,0): raise ValueError('Unsupported header')
    if zlib.crc32(data[:28])!=crc: raise ValueError('Header CRC mismatch')
    if not 160<=total<=ASSET_END or len(data)<total: raise ValueError('Invalid package length')
    table=data[32:160]
    if zlib.crc32(table)!=table_crc: raise ValueError('Directory CRC mismatch')
    rows=[];end=0x10000
    for index in range(4):
        rid,offset,w,h,stride,fmt,length,pcrc=ENTRY.unpack_from(table,index*32)
        if (rid,w,h,stride,fmt,length)!=(index+1,640,480,2560,2 if index==3 else 1,0x12c000):
            raise ValueError('Resource contract mismatch')
        if offset<end or offset%4096 or offset>total or length>total-offset:
            raise ValueError('Resource overlap/out of bounds')
        if zlib.crc32(data[offset:offset+length])!=pcrc: raise ValueError(f'Resource {rid} CRC mismatch')
        end=offset+length
        rows.append(dict(id=rid,name=NAMES[rid],offset=offset,width=w,height=h,
                         stride=stride,format=fmt,length=length,crc32=pcrc))
    return dict(version=version,total=total,resources=rows)

def pack(manifest,output):
    from PIL import Image
    spec=json.loads(manifest.read_text(encoding='utf-8'))
    rows=spec['resources']
    if len(rows)!=4 or sorted(r['id'] for r in rows)!=[1,2,3,4]:
        raise ValueError('Exactly resource IDs 1,2,3,4 are required')
    result=bytearray(b'\xff'*0x10000);table=bytearray()
    for row in sorted(rows,key=lambda r:r['id']):
        rid=row['id'];path=manifest.parent/row['file']
        with Image.open(path) as image:
            if image.size!=(640,480):raise ValueError(f'{path}: expected 640x480')
            image=image.convert('RGBA')
            if rid<4:image.putalpha(0)
            else:
                # Player/enemy use the existing RGB color-key engine, not alpha.
                # Translate transparent PNG pixels; reject unsupported edge alpha.
                for origin in (64,96):
                    for y in range(32):
                        for x in range(origin,origin+32):
                            red,green,blue,alpha=image.getpixel((x,y))
                            if alpha==0:image.putpixel((x,y),(255,0,255,0))
                            elif alpha!=255:raise ValueError('Player/enemy slots require binary transparency')
            payload=image.tobytes('raw','BGRA')
        offset=(len(result)+4095)&~4095
        result.extend(b'\xff'*(offset-len(result)));result.extend(payload)
        table.extend(ENTRY.pack(rid,offset,640,480,2560,2 if rid==4 else 1,len(payload),zlib.crc32(payload)))
    if len(result)>ASSET_END:raise ValueError('Assets overlap save region')
    prefix=struct.pack('<7I',MAGIC,1,32,4,len(result),zlib.crc32(table),0)
    result[:32]=prefix+struct.pack('<I',zlib.crc32(prefix));result[32:160]=table
    report=inspect(result)
    if output.exists():raise FileExistsError(f'Output exists: {output}')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(result)
    output.with_suffix('.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))

def unpack(path,directory):
    from PIL import Image
    data=path.read_bytes();report=inspect(data)
    if directory.exists() and any(directory.iterdir()):raise FileExistsError('Extraction directory is not empty')
    directory.mkdir(parents=True,exist_ok=True)
    for r in report['resources']:
        payload=data[r['offset']:r['offset']+r['length']]
        image=Image.frombytes('RGBA',(640,480),payload,'raw','BGRA')
        if r['format']==1:image=image.convert('RGB')
        image.save(directory/(r['name']+'.png'))
    for r in report['resources']:r['file']=r['name']+'.png'
    (directory/'manifest.json').write_text(json.dumps(report,indent=2),encoding='utf-8')

def sample(directory):
    from PIL import Image
    if directory.exists() and any(directory.iterdir()):raise FileExistsError('Sample directory is not empty')
    directory.mkdir(parents=True,exist_ok=True);rows=[]
    for rid in range(1,5):
        image=Image.new('RGBA',(640,480),(255,0,255,0));pixels=image.load()
        for y in range(480):
            for x in range(640):
                if rid<4:
                    r=(x+(y>>1)+rid*37)&255;g=(y+(x>>2)+rid*19)&255
                    b=224 if ((x+y)>>5)&1 else 40
                    pixels[x,y]=(r,g,b,255)
                elif x<64 and y<64:
                    d=(x-31)**2+(y-31)**2
                    a=0 if d>=1024 else 24+(1023-d)*220//1023
                    pixels[x,y]=(255,116,48,a)
                elif 64<=x<96 and y<32:
                    sx=x-64;body=4<=y<=28 and (12 if y<12 else 5+y//5)<=sx<(20 if y<12 else 27-y//5)
                    wing=16<=y<=25 and (sx<7 or sx>=25)
                    if body or wing:pixels[x,y]=(0,234,255,255) if 8<=y<=15 and 13<=sx<=18 else (244,248,255,255)
                elif 96<=x<128 and y<32:
                    sx=x-96
                    if (sx-16)**2+(y-15)**2<190 and not(y<8 and(sx<11 or sx>20)):
                        pixels[x,y]=(255,176,32,255) if (sx//4+y//4)&1 else (232,64,80,255)
                elif 128<=x<144 and y<16:
                    d=(x-136)**2+(y-8)**2
                    pixels[x,y]=(48,232,255,0 if d>64 else 80+(64-d)*160//64)
        name=NAMES[rid]+'.png';image.save(directory/name);rows.append(dict(id=rid,file=name))
    (directory/'manifest.json').write_text(json.dumps(dict(resources=rows),indent=2),encoding='utf-8')

def saves(path):
    data=path.read_bytes();records=[]
    for slot in (SAVE_A,SAVE_B):
        if len(data)<slot+36:continue
        magic,version,seq,length,score,difficulty,flags,crc,commit=struct.unpack_from('<9I',data,slot)
        valid=(magic==0x56533246 and version==1 and length==12 and difficulty<=2 and flags==0 and
               commit==0x54494d43 and zlib.crc32(data[slot:slot+28])==crc)
        records.append(dict(slot=hex(slot),valid=valid,sequence=seq,high_score=score,difficulty=difficulty))
    print(json.dumps(records,indent=2))

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    for name in ('inspect','saves'):
        p=sub.add_parser(name);p.add_argument('input',type=Path)
    p=sub.add_parser('sample');p.add_argument('directory',type=Path)
    p=sub.add_parser('pack');p.add_argument('manifest',type=Path);p.add_argument('output',type=Path)
    p=sub.add_parser('unpack');p.add_argument('input',type=Path);p.add_argument('directory',type=Path)
    args=parser.parse_args()
    if args.command=='sample':sample(args.directory)
    elif args.command=='pack':pack(args.manifest,args.output)
    elif args.command=='unpack':unpack(args.input,args.directory)
    elif args.command=='saves':saves(args.input)
    else:print(json.dumps(inspect(args.input.read_bytes()),indent=2))
if __name__=='__main__':main()

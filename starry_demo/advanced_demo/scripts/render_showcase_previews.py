"""Turn host-rasterized firmware frames into PNGs, without image dependencies."""
from pathlib import Path
import struct
import zlib

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output'

def png(path,width,height,rows):
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',width,height,8,2,0,0,0))+
                     chunk(b'IDAT',zlib.compress(b''.join(b'\0'+row for row in rows),9))+chunk(b'IEND',b''))

def main():
    frames=[]
    for name in ('wave3','boss_hit','victory'):
        data=(OUT/f'showcase_{name}.ppm').read_bytes()
        header=b'P6\n640 480\n255\n'
        assert data.startswith(header) and len(data)==len(header)+640*480*3
        data=data[len(header):]
        rows=[data[y*1920:(y+1)*1920] for y in range(480)]
        png(OUT/f'showcase_{name}.png',640,480,rows)
        frames.append(rows)
        scaled=[]
        for row in rows:
            doubled=b''.join(row[x:x+3]*2 for x in range(0,len(row),3))
            scaled.extend([b'\0'*960+doubled+b'\0'*960]*2)
        png(OUT/f'showcase_{name}_1080p.png',1920,1080,
            [b'\0'*5760]*60+scaled+[b'\0'*5760]*60)
    png(OUT/'showcase_preview.png',1920,480,
        [b''.join(frame[y] for frame in frames) for y in range(480)])
    print('PASS exported firmware preview PNGs and centered 2x 1080p reference')

if __name__=='__main__':
    main()

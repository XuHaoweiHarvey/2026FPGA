"""Small command-level GD25LQ64/FIFO model for RV32 MMIO transport regression.

Exercises actual driver MMIO and timeouts; electrical timing, protection bits,
real FIFO backpressure and board routing remain hardware acceptance items.
"""
import struct
from collections import deque
from unicorn import UC_HOOK_MEM_READ,UC_HOOK_MEM_WRITE

def attach(uc):
    base=0xf8014000;clint=0xf8b00000
    uc.mem_map(base,4096);uc.mem_map(clint,0x10000)
    flash=bytearray(b'\xff'*0x800000);fifo=deque();ticks=0;selected=False
    opcode=None;address=[];payload=[];position=0;wel=False;injected=False
    def ctl():return struct.unpack('<I',uc.mem_read(0x20000000,4))[0]
    def read(emu,access,a,size,value,user):
        nonlocal ticks,position,injected
        if ctl()!=4:injected=False
        if a==base+4 and ctl()==4 and not injected:
            fifo.extend((0x66,0x77));injected=True
        v=0
        if a==base+4:v=(0 if ctl()==3 else 256)|(len(fifo)<<16)
        elif a==base:v=fifo.popleft() if fifo else 0
        elif a==clint+0xbff8:ticks+=10000;v=ticks&0xffffffff
        elif a==clint+0xbffc:v=ticks>>32
        emu.mem_write(a,v.to_bytes(size,'little'))
    def write(emu,access,a,size,value,user):
        nonlocal selected,opcode,address,payload,position,wel
        if a!=base:return
        if value&0x800:
            if value&0x80:
                selected=True;opcode=None;address=[];payload=[];position=0
            else:
                if selected and opcode==0x06:wel=True
                if selected and opcode==0x02 and wel:
                    start=int.from_bytes(bytes(address),'big')
                    for i,b in enumerate(payload):flash[start+i]&=b
                    wel=False
                if selected and opcode==0x20 and wel:
                    start=int.from_bytes(bytes(address),'big');flash[start:start+4096]=b'\xff'*4096;wel=False
                selected=False
        elif value&0x100:
            b=value&255
            if opcode is None:opcode=b
            elif opcode in (3,2,0x20) and len(address)<3:address.append(b)
            elif opcode==2:payload.append(b)
        elif value&0x200:
            if opcode==0x9f:v=(b'\xc8\x60\x17' if ctl()!=1 else b'\xff'*3)[position%3]
            elif opcode==5:v=(2 if wel else 0)|(1 if ctl()==2 else 0)
            elif opcode==3:v=flash[int.from_bytes(bytes(address),'big')+position]
            else:v=255
            fifo.append(v);position+=1
    uc.hook_add(UC_HOOK_MEM_READ,read,begin=base,end=base+4095)
    uc.hook_add(UC_HOOK_MEM_READ,read,begin=clint,end=clint+0xffff)
    uc.hook_add(UC_HOOK_MEM_WRITE,write,begin=base,end=base+4095)

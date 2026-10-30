"""Test real IDE GDB restore/dump syntax against a local fake RAM target.

No hardware/OpenOCD connection, execution or Flash access. Verifies file paths,
DWARF buffer expressions, binary restore and dump with the shipped GDB executable.
"""
import argparse
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--ide-root',type=Path,default=Path('C:/Efinity/efinity-riscv-ide-2026.1'))
a=p.parse_args();ram={}
def memory(address,size):return bytes(ram.get(address+i,0) for i in range(size))
def unescape(data):
    out=bytearray();escaped=False
    for b in data:
        if escaped:out.append(b^32);escaped=False
        elif b==125:escaped=True
        else:out.append(b)
    return bytes(out)
class Target(socketserver.BaseRequestHandler):
    def handle(self):
        stream=self.request.makefile('rb')
        while True:
            c=stream.read(1)
            if not c:return
            if c!=b'$':continue
            packet=bytearray()
            while True:
                c=stream.read(1)
                if not c:return
                if c==b'#':break
                packet.extend(c)
            stream.read(2);self.request.sendall(b'+');cmd=unescape(packet)
            response=b''
            if cmd.startswith(b'qSupported'):response=b'PacketSize=4000'
            elif cmd==b'?':response=b'S05'
            elif cmd in (b'qfThreadInfo',):response=b'm1'
            elif cmd==b'qsThreadInfo':response=b'l'
            elif cmd==b'qC':response=b'QC1'
            elif cmd.startswith(b'qAttached'):response=b'1'
            elif cmd.startswith(b'qSymbol'):response=b'OK'
            elif cmd.startswith((b'H',b'T',b'!')):response=b'OK'
            elif cmd==b'g':response=(b'00000000'*32+b'000000f9')
            elif cmd.startswith(b'p'):response=b'00000000'
            elif cmd.startswith(b'm'):
                address,size=[int(x,16) for x in cmd[1:].split(b',')]
                response=memory(address,size).hex().encode()
            elif cmd.startswith((b'M',b'X')):
                prefix,data=cmd[1:].split(b':',1);address,size=[int(x,16) for x in prefix.split(b',')]
                if cmd[:1]==b'M':data=bytes.fromhex(data.decode())
                assert len(data)==size
                for i,b in enumerate(data):ram[address+i]=b
                response=b'OK'
            elif cmd.startswith(b'D'):response=b'OK'
            checksum=sum(response)&255
            self.request.sendall(b'$'+response+b'#'+f'{checksum:02x}'.encode())
            if cmd.startswith(b'D'):return

with tempfile.TemporaryDirectory(prefix='flash-gdb-') as temp:
    directory=Path(temp)/'transfer';directory.mkdir()
    source=directory/'input.bin';output=directory/'output.bin'
    source.write_bytes(bytes(range(256))*10)
    with socketserver.TCPServer(('127.0.0.1',0),Target) as server:
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        commands=directory/'commands.gdb'
        commands.write_text('\n'.join([
            f'target remote 127.0.0.1:{server.server_address[1]}',
            f'restore {source.as_posix()} binary &g_flash_maint.data[0]',
            f'dump binary memory {output.as_posix()} &g_flash_maint.data[0] &g_flash_maint.data[2560]',
            'disconnect'])+'\n')
        command=[str(a.ide_root/'toolchain/bin/riscv-none-elf-gdb.exe'),'--batch','--nx',
                 str(ROOT/'software/flash/build/flash-maint/flash_maint.elf'),'-x',str(commands)]
        try:
            result=subprocess.run(command,capture_output=True,text=True,timeout=30)
            if result.returncode:raise AssertionError(result.stdout+result.stderr)
            assert output.exists(),result.stdout+result.stderr
            assert output.read_bytes()==source.read_bytes(),result.stdout+result.stderr
        finally:server.shutdown()
print('PASS real IDE GDB restore/dump + buffer addresses on a local fake RAM target')

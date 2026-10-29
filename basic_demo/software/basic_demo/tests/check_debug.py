"""Validate the IDE PC field with actual GDB, and Jim Tcl with hardware disabled."""
import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--launch', type=Path, default=ROOT/'basic_demo_ti.launch')
parser.add_argument('--ide-root', type=Path, default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
args = parser.parse_args()
properties = {e.get('key'):e.get('value') for e in ET.parse(args.launch).getroot()}
pc = properties['org.eclipse.cdt.debug.gdbjtag.core.pcRegister']
assert properties['org.eclipse.cdt.debug.gdbjtag.core.setPcRegister'] == 'true'
# The actual IDE failure log shows that its PC field is prefixed with 0x.
# Exercise that number parser in GDB without requiring target registers.
gdb = args.ide_root/'toolchain/bin/riscv-none-elf-gdb.exe'
number = '0x'+pc
result = subprocess.run([str(gdb),'--batch','--nx','-ex','print /x '+number],
                        capture_output=True,text=True,timeout=10)
assert result.returncode == 0, ('IDE PC field produces set $pc='+number+'\n'+result.stdout+result.stderr)
assert int(number,16) == 0xF9000000
print('PASS actual GDB parses the IDE PC number: '+number,flush=True)

(ROOT/'build').mkdir(exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='debug-check-',dir=ROOT/'build'))
guard = out/'no-hardware.tcl'
guard.write_text('''# No real adapter, target, init, reset, memory or run command can execute.
set DEBUG_CHECK_CALLS {}
foreach cmd {adapter ftdi jtag target vexriscv targets poll_period init halt reset resume load_image jtag_ntrst_delay gdb_target_description} {
    if {[llength [info commands $cmd]]} { rename $cmd DEBUG_saved_$cmd }
    proc $cmd {args} "lappend ::DEBUG_CHECK_CALLS \\[linsert \\$args 0 $cmd\\]"
}
''',encoding='utf8')
checks = out/'assert-config.tcl'
checks.write_text('''foreach required {{adapter speed 800} {ftdi device_desc {Quad RS232-HS}} {ftdi vid_pid 0x0403 0x6011} {ftdi channel 1} {halt}} {
    if {[lsearch -exact $DEBUG_CHECK_CALLS $required] < 0} {error "Missing expected configuration: $required"}
}
if {$proj_loc ne $bsp_loc} {error "Wrong CPU BSP path"}
if {![file exists [file join $proj_loc cpu0.yaml]]} {error "Missing formal cpu0.yaml"}
if {$LEGACY_IDE != 0 || $STANDARD_DEBUG != 0} {error "Debug mode changed"}
echo "PASS actual OpenOCD Jim Tcl config parsing; hardware calls disabled"
''',encoding='utf8')
options=properties['ilg.gnumcueclipse.debug.gdbjtag.openocd.gdbServerOther']
assert '${' not in options, 'Debug options must contain prepared project paths'
command=[str(args.ide_root/'openocd/bin/openocd.exe'),'-f',str(guard),
         *shlex.split(options),'-f',str(checks),'-c','shutdown']
result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=10)
assert result.returncode == 0,result.stdout+result.stderr
assert 'PASS actual OpenOCD Jim Tcl' in result.stdout+result.stderr
print('PASS actual OpenOCD Jim Tcl; Titanium configuration and formal YAML path validated (no hardware)')
print('Artifacts:',out)

"""Run C-side unit tests and frozen-reference regressions; no board access."""
import argparse
import pathlib
import subprocess
import sys
import datetime
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--iverilog', default='iverilog')
p.add_argument('--vvp', default='vvp')
args = p.parse_args()
compiler = pathlib.Path(shutil.which(args.iverilog) or args.iverilog).resolve()
ivl_dir = compiler.parent.parent / 'lib' / 'ivl'
compiler_flags = ['-B', str(ivl_dir)] if ivl_dir.is_dir() else []
runtime_flags = ['-M', '-', '-M', str(ivl_dir)] if ivl_dir.is_dir() else []
out = ROOT / 'test_results'
out.mkdir(exist_ok=True)
tests = [
    ('tb_c_priority', ['sim/tb_c_priority.v', 'rtl/c_display_read_priority.v']),
    ('tb_c_range', ['sim/tb_c_range.v', 'rtl/c_front_range_guard.v']),
    ('tb_c_arbiter', ['sim/tb_c_arbiter.v', 'rtl/c_axi_read_arbiter.v']),
    ('tb_c_command', ['sim/tb_c_command.v', 'rtl/c_command_service.v',
                      'rtl/c_front_range_guard.v', 'rtl/c_buffer_manager.v']),
    ('tb_c_blit_integration', ['sim/tb_c_blit_integration.v', 'rtl/c_command_service.v',
                              'rtl/c_front_range_guard.v', 'rtl/c_buffer_manager.v',
                              'rtl/c_axi_read_arbiter.v', 'reference/blit_engine.v']),
    ('tb_buffer_manager', ['reference/tb_buffer_manager.v', 'reference/buffer_manager.v',
                            'reference/video_frame_cdc.v']),
    ('tb_c_manager_regression', ['sim/tb_c_manager_regression.v', 'rtl/c_buffer_manager.v',
                                 'reference/video_frame_cdc.v']),
    ('tb_read_frame_guard', ['reference/tb_read_frame_guard.v', 'reference/read_frame_guard.v']),
    ('tb_fill_rect_writer', ['reference/tb_fill_rect_writer.v', 'reference/fill_rect_writer.v']),
]
lines = ['UTC: ' + datetime.datetime.now(datetime.timezone.utc).isoformat()]
def run(cmd):
    lines.append('COMMAND: ' + subprocess.list2cmdline([str(s) for s in cmd]))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
    lines.extend([r.stdout, r.stderr])
    print(r.stdout, end='')
    if r.stderr:
        print(r.stderr, file=sys.stderr, end='')
    if r.returncode:
        raise RuntimeError('Exit status ' + str(r.returncode))
try:
    for top, files in tests:
        binary = out / (top + '.vvp')
        run([args.iverilog, *compiler_flags, '-g2012', '-Wall', '-s', top, '-o', str(binary), *files])
        run([args.vvp, *runtime_flags, str(binary)])
    lines.append('PASS ALL C PACKAGE TESTS')
    print(lines[-1])
except Exception as e:
    lines.append('FAIL: ' + str(e))
    print(lines[-1], file=sys.stderr)
    sys.exit(1)
finally:
    (out / 'simulation.log').write_text('\n'.join(lines), encoding='utf-8')

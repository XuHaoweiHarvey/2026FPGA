"""v14 exact-image regressions and controlled-latency v13/v14 comparison."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/lunaria/verification'
IVERILOG = 'D:/iverilog/bin/iverilog.exe'
VVP = 'D:/iverilog/bin/vvp.exe'
ALPHA = ['rtl/accelerator/alpha_blit_engine.v', 'rtl/accelerator/alpha_pixel_pipeline.v']
GRAPHICS = ALPHA + ['rtl/accelerator/graphics_engine.v', 'rtl/accelerator/blit_engine.v',
                    'rtl/accelerator/fill_rect_writer.v']


def main():
    results = {}
    with tempfile.TemporaryDirectory(prefix='lunaria-ddr-') as temp:
        def sim(name, top, sources, **params):
            binary = Path(temp) / (name + '.vvp')
            subprocess.run([IVERILOG, '-g2005-sv', '-s', top,
                            *[f'-P{top}.{k}={v}' for k, v in params.items()],
                            '-o', str(binary), f'sim/{top}.v', *sources], cwd=ROOT, check=True)
            run = subprocess.run([VVP, str(binary)], cwd=ROOT, capture_output=True, text=True)
            assert run.returncode == 0 and 'PASS ' in run.stdout, name + '\n' + run.stdout + run.stderr
            results[name] = run.stdout
            print(name + ': ' + run.stdout.splitlines()[0], flush=True)

        for overlap in (0, 1):
            sim(f'cache-{overlap}', 'tb_lunaria_alpha_cache', ALPHA, OVERLAP=overlap)
            sim(f'beam-{overlap}', 'tb_lunaria_beam', GRAPHICS, OVERLAP=overlap)
        for stream in (0, 1):
            for name, params in [('pixels', {}), ('read-error', {'INJECT_RRESP': 1}),
                                 ('write-error', {'INJECT_BRESP': 1}), ('early-last', {'MALFORMED_RLAST': 1}),
                                 ('late-last', {'MALFORMED_RLAST': 2}), ('read-timeout', {'TIMEOUT_READ': 1})]:
                sim(f'{name}-stream{stream}', 'tb_alpha_blit_engine', ALPHA,
                    OVERLAP=1, STREAM_ENABLE=stream, **params)
        for fault in range(7):
            sim(f'overlap-stalls-{fault}', 'tb_lunaria_overlap', ALPHA, FAULT_CASE=fault)
        for enabled in (0, 1):
            sim(f'perf-apb-{enabled}', 'tb_lunaria_perf_regs', ['rtl/control/accel_regs.v'], ENABLED=enabled)
    cycles = {}
    for overlap in (0, 1):
        match = re.search(r'cold=(\d+) warm=(\d+) trim=(\d+)', results[f'cache-{overlap}'])
        cycles[f'v{13+overlap}'] = dict(zip(('cold', 'warm', 'trim'), map(int, match.groups())))
    assert all(cycles['v14'][k] < cycles['v13'][k] for k in cycles['v13'])
    names = [*GRAPHICS, 'rtl/control/accel_regs.v', 'rtl/control/sapphire_control.v',
             'rtl/framebuffer/rgb_framebuffer.v', 'rtl/ti60f225_oob_top.v',
             'sim/tb_lunaria_alpha_cache.v', 'sim/tb_lunaria_beam.v', 'sim/tb_alpha_blit_engine.v',
             'sim/tb_lunaria_overlap.v', 'sim/tb_lunaria_perf_regs.v', 'scripts/run_lunaria_ddr_checks.py']
    report = dict(status='passed', board_tested=False, stable_60_fps_measured=False,
                  scope='RTL unit tests with controlled AXI stalls; not board FPS or measured DDR bandwidth',
                  cycles=cycles, results=results,
                  sources={n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'ddr-v14-checks.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf8')
    print(json.dumps(cycles, indent=2))


if __name__ == '__main__':
    main()

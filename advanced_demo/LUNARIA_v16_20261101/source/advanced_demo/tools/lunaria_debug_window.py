"""Dedicated LUNARIA UI; no connection/load occurs until the user clicks."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
import tkinter as tk
from tkinter import ttk

from game_debug_window import DebugWindow
from lunaria_debug_bridge import LunariaBridge, DEFAULT_ELF, DEFAULT_ASSETS

NAMES = ('环形 / 自机狙 / 留隙','螺旋 / 反向摩尔纹','黄金角向日葵','花瓣 / 分数玫瑰','五角星 / 多边形','星形叠层','加速 / 停顿 / 激光','组合符卡')
STATES = ('标题画面','Boss 入场','战斗','阶段预警','击毁演出','VICTORY','GAME OVER')


class LunariaWindow(DebugWindow):
    def __init__(self, root, elf=DEFAULT_ELF, assets=DEFAULT_ASSETS):
        def factory(elf, ide):
            return LunariaBridge(elf, ide, assets,
                                 lambda message: self.events.put(('progress',message)))
        super().__init__(root,elf,bridge_factory=factory)
        root.title('LUNARIA 星海梦境 — v16 分块合成')
        self.alpha.set('255'); self.cap.set('1'); self.delay.set('0')
        self.bullet_limit = tk.StringVar(value='256')
        self.spin_patterns = tk.BooleanVar(value=False)
        box = root.winfo_children()[0]
        for frame in box.winfo_children():
            if isinstance(frame,ttk.LabelFrame):
                title = frame.cget('text')
                if title.startswith('板上操作'):
                    ttk.Button(frame,text='DDR 诊断 5 秒',command=self.measure_ddr).pack(side='left',padx=3)
                    for widget in frame.winfo_children():
                        if isinstance(widget,ttk.Button) and widget.cget('text') in ('一键自测','满负载场景'):
                            widget.pack_forget()
                        elif isinstance(widget,ttk.Button) and widget.cget('text') == '演示战役':
                            widget.configure(text='星海战役')
                elif title.startswith('运行参数'):
                    frame.configure(text='LUNARIA 参数：修改后点击应用')
                    for widget in frame.winfo_children():
                        info = widget.grid_info()
                        if info and (int(info['row']) >= 2 or int(info['column']) < 3):
                            widget.grid_remove()
                    ttk.Label(frame,text='敌弹上限 64–4096').grid(row=0,column=0)
                    ttk.Combobox(frame,textvariable=self.bullet_limit,
                                 values=(64,128,256,512,1024,2048,3072,4096),width=16).grid(row=1,column=0,padx=5)
                    ttk.Checkbutton(frame,text='扩张时旋转花瓣 / 星形',variable=self.spin_patterns).grid(
                        row=1,column=1,columnspan=2,padx=5)
                    ttk.Label(frame,text='应用会重启当前弹幕、重置峰值；实际数量随图案变化。测量期间锁定设置。').grid(
                        row=2,column=0,columnspan=6,sticky='w',pady=(6,0))
                    ttk.Button(frame,text='打开电脑同源预览',command=self.preview).grid(
                        row=3,column=0,columnspan=2,sticky='w',pady=(6,0))
        self.notice.set('素材通过 4 KiB 邮箱上传，首次约 2.46 MB。更换已封存素材须先重新配置现有 bit。')
        self.summary.set('先结束 IDE Debug，点击连接，然后点击加载；窗口不会自动连接板卡。')
        self.log('素材清单：'+str(Path(assets).resolve()))
        self.preview_folder = Path(assets).resolve().parent

    def preview(self):
        if not (self.preview_folder/'lunaria_pc.dll').is_file():
            return self.log('缺少电脑预览 DLL，请使用完整的新版交付包。')
        subprocess.Popen([sys.executable,'-B',str(Path(__file__).with_name('lunaria_pc.py')),
                          '--folder',str(self.preview_folder)],
                         creationflags=subprocess.CREATE_NO_WINDOW if sys.platform=='win32' else 0)

    def apply(self):
        try:
            limit, alpha = int(self.bullet_limit.get()), int(self.alpha.get())
            if not 64 <= limit <= 4096 or not 0 <= alpha <= 255:
                raise ValueError
        except ValueError:
            return self.log('敌弹上限须为 64–4096 的整数，Alpha 须为 0–255 的整数')
        options = (0,900,1,int(self.invincible.get()),alpha)
        spin = int(self.spin_patterns.get())
        def done(sequence):
            self.log(f'子弹设置 {sequence} 已提交：上限 {limit}，扩张旋转 {bool(spin)}；等待读取确认。')
            self.root.after(150,self.read)
        self.run(lambda:self.require_bridge().configure(limit,spin,options),done)

    def load(self):
        self.summary.set('校验 ELF 与素材，然后安全加载、分块上传；请等待完成。')
        def done(_):
            self.log('ELF、背景和图集已加载；按空格开始，或点击星海战役。')
            self.root.after(150,self.read)
        self.run(lambda: self.require_bridge().load(),done)

    def measure(self):
        def done(sequence):
            self.measuring = True
            self.notice.set('正在测量当前弹幕 60 秒；射击和暂停暂时屏蔽，避免提前击败当前阶段。')
            self.log(f'测量命令 {sequence} 已提交。无敌调试须已开启；整个区间不进行 JTAG 读取。')
            self.root.after(62000,lambda:self.finish_measure(sequence))
        self.run(lambda:self.require_bridge().command(7),done)

    def measure_ddr(self):
        def done(report):
            rate=report['alpha_MB_per_second']; wait=report['wall_time_percent']
            hit=report['cache_hit_percent']
            hit_label=f'{hit:.1f}%' if hit is not None else '无请求'
            self.log(f'DDR {report["seconds"]:.2f} 秒：贴图读取 {rate["source_beats"]:.1f} MB/s，'
                     f'目标读取 {rate["destination_beats"]:.1f} MB/s，写回 {rate["write_beats"]:.1f} MB/s；'
                     f'缓存命中 {hit_label}',report)
            self.log('等待占总时间：'+', '.join(f'{k}={v:.1f}%' for k,v in wait.items()))
            if 'source_bursts' in report['counters']:
                counters=report['counters']
                self.log('读取细分（100 MHz 周期；目标首拍等待包含排在贴图之后的时间）：'+
                         ', '.join(f'{key}={counters[key]}' for key in
                         ('source_address_wait','target_address_wait','source_first_wait','target_first_wait',
                          'source_interbeat_wait','target_interbeat_wait','source_bursts','target_bursts')))
            self.log(report['note'])
        self.run(lambda:self.require_bridge().measure_ddr(),done)

    def show_status(self, status):
        self.last_status = status
        runtime, presentation = status.get('runtime',{}),status.get('presentation',{})
        state = presentation.get('state',0)
        phase = max(0,min(7,presentation.get('boss_phase',1)-1))
        label = STATES[state] if state < len(STATES) else str(state)
        if status.get('phase') == 255:
            label = '固件故障'
        elif status.get('phase') in (1,2,3):
            label = '初始化 / 等待素材'
        self.summary.set(f'{label} | {NAMES[phase]} | 生命 {status.get("lives",0)} | '
                         f'分数 {status.get("score",0)} | FPS {status.get("fps_x100",0)/100:.2f} | '
                         f'绘制 {runtime.get("render_us",0)/1000:.2f} ms | 错误 0x{status.get("error",0):04X}')
        version = status.get('hardware_version',0) >> 16
        self.summary.set(self.summary.get()+f' | 硬件 v{version}')
        timing=status.get('lunaria_timing',{})
        if timing and not status.get('partial_lunaria_timing'):
            self.log(f'本帧：逻辑/分页 {timing["update_us"]/1000:.3f} ms，'
                     f'提交/背压 {timing["submit_us"]/1000:.3f} ms，'
                     f'末尾排空 {timing["drain_us"]/1000:.3f} ms，'
                     f'等待换帧 {timing["swap_us"]/1000:.3f} ms。提交时间含硬件队列背压和渲染期间分页等待。')
        if version in (10,11,12):
            self.log('请升级到交付包 hardware/v16 的 bit，启用连续激光和 DDR 读写优化。')
        metrics = status.get('lunaria_metrics',{})
        if metrics and not status.get('partial_lunaria_metrics'):
            self.summary.set(self.summary.get()+f' | 子弹 {metrics["bullets"]} / 峰值 {metrics["peak_bullets"]}'
                             f' | 活动元素 {metrics["elements"]} / 峰值 {metrics["peak_elements"]}')
        settings = status.get('lunaria_settings',{})
        if settings:
            self.summary.set(self.summary.get()+f' | 上限 {settings["limit"]} / 容量 {settings["capacity"]}')
            if settings['sequence'] != settings['ack']:
                self.log('子弹设置等待固件在帧边界应用')
            elif settings['result']:
                self.log(f'子弹设置被固件拒绝：0x{settings["result"]:04X}')
        if presentation:
            self.log(f'渲染 640×480 / 显示 {presentation["display_width"]}×{presentation["display_height"]} '
                     f'@({presentation["display_x"]},{presentation["display_y"]})；Boss {phase+1}/8')
        self.uart_rx_label.set(f'板端接收 {status.get("uart_accepted",0)} 帧，按键 0x{status.get("buttons",0):02X}')
        self.log('状态 '+json.dumps(status,ensure_ascii=False),status)
        if status.get('error') in (0xEA01,0xEA08):
            self.log('已有另一套封存素材：断开 JTAG，重新配置相同的兼容 bit，再加载 LUNARIA。')
        if any(status.get(key) for key in ('partial_publication','partial_runtime','partial_presentation','partial_lunaria_metrics')):
            self.log('当前快照可能跨帧；完整性能以独立 60 秒结果为准。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--elf',type=Path,default=DEFAULT_ELF)
    parser.add_argument('--assets',type=Path,default=DEFAULT_ASSETS)
    args = parser.parse_args()
    root = tk.Tk()
    LunariaWindow(root,args.elf,args.assets)
    root.mainloop()


if __name__ == '__main__': main()

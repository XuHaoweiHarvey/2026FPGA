"""Dedicated LUNARIA UI; no connection/load occurs until the user clicks."""
import argparse
import json
from pathlib import Path
import tkinter as tk
from tkinter import ttk

from game_debug_window import DebugWindow
from lunaria_debug_bridge import LunariaBridge, DEFAULT_ELF, DEFAULT_ASSETS

NAMES = ('环形 / 自机狙 / 留隙','螺旋 / 反向摩尔纹','黄金角向日葵','花瓣 / 分数玫瑰','五角星 / 多边形','星形叠层','加速 / 停顿 / 激光','组合符卡')
STATES = ('标题画面','Boss 入场','战斗','阶段预警','击毁演出','VICTORY','GAME OVER')


class LunariaWindow(DebugWindow):
    def __init__(self, root, elf=DEFAULT_ELF, assets=DEFAULT_ASSETS, stress=False):
        self.stress = stress
        self.maximum_bullets = 832 if stress else 640
        def factory(elf, ide):
            bridge = LunariaBridge(elf, ide, assets,
                                 lambda message: self.events.put(('progress',message)))
            if self.stress and bridge.image.symbol_u32('g_lunaria_stress_test') != 1:
                raise ValueError('压力测试入口需要专用 stress ELF')
            return bridge
        super().__init__(root,elf,bridge_factory=factory)
        root.title('LUNARIA 压力测试 — v12' if stress else 'LUNARIA 星海梦境 — v10 / v11')
        if stress: self.invincible.set(True)
        self.alpha.set('255'); self.cap.set('1'); self.delay.set('0')
        self.bullet_limit = tk.StringVar(value='256')
        self.spin_patterns = tk.BooleanVar(value=False)
        box = root.winfo_children()[0]
        for frame in box.winfo_children():
            if isinstance(frame,ttk.LabelFrame):
                title = frame.cget('text')
                if title.startswith('板上操作'):
                    for widget in frame.winfo_children():
                        if isinstance(widget,ttk.Button) and widget.cget('text') in ('一键自测','满负载场景'):
                            widget.pack_forget()
                        elif isinstance(widget,ttk.Button) and widget.cget('text') == '演示战役':
                            widget.configure(text='重启压力测试' if stress else '星海战役')
                elif title.startswith('运行参数'):
                    frame.configure(text='LUNARIA 参数：修改后点击应用')
                    if stress:
                        for item in frame.winfo_children():
                            if isinstance(item,ttk.Checkbutton) and item.cget('text') == '无敌调试':
                                item.configure(text='恒定无敌',state='disabled')
                    for widget in frame.winfo_children():
                        info = widget.grid_info()
                        if info and (int(info['row']) >= 2 or int(info['column']) < 3):
                            widget.grid_remove()
                    ttk.Label(frame,text=f'敌弹上限 64–{self.maximum_bullets}').grid(row=0,column=0)
                    ttk.Combobox(frame,textvariable=self.bullet_limit,
                                 values=((64,128,256,384,512,610,640,704,768,832) if stress else (64,128,256,384,512,640)),width=16).grid(row=1,column=0,padx=5)
                    ttk.Checkbutton(frame,text='扩张时旋转花瓣 / 星形',variable=self.spin_patterns,
                                    state='disabled' if stress else 'normal').grid(
                        row=1,column=1,columnspan=2,padx=5)
                    ttk.Label(frame,text=('恒定无敌；从 Boss 补弹到所选上限；击空血条自动补满。测量时可移动开火。' if stress else
                        '应用会重启当前弹幕、重置峰值；实际数量随图案变化。测量期间锁定设置。')).grid(
                        row=2,column=0,columnspan=6,sticky='w',pady=(6,0))
        self.notice.set('素材通过 4 KiB 邮箱上传，首次约 2.46 MB。更换已封存素材须先重新配置现有 bit。')
        self.summary.set('先结束 IDE Debug，点击连接，然后点击加载；窗口不会自动连接板卡。')
        self.log('素材清单：'+str(Path(assets).resolve()))

    def apply(self):
        try:
            limit, alpha = int(self.bullet_limit.get()), int(self.alpha.get())
            if not 64 <= limit <= self.maximum_bullets or not 0 <= alpha <= 255:
                raise ValueError
        except ValueError:
            return self.log(f'敌弹上限须为 64–{self.maximum_bullets} 的整数，Alpha 须为 0–255 的整数')
        options = (0,900,1,1 if self.stress else int(self.invincible.get()),alpha)
        spin = 0 if self.stress else int(self.spin_patterns.get())
        def done(sequence):
            self.log(f'子弹设置 {sequence} 已提交：上限 {limit}，扩张旋转 {bool(spin)}；等待读取确认。')
            self.root.after(150,self.read)
        self.run(lambda:self.require_bridge().configure(limit,spin,options),done)

    def load(self):
        self.summary.set('校验 ELF 与素材，然后安全加载、分块上传；请等待完成。')
        def done(_):
            self.log('压力测试已开始：持续无敌，可直接移动开火、调整敌弹上限。' if self.stress else
                     'ELF、背景和图集已加载；按空格开始，或点击星海战役。')
            self.root.after(150,self.read)
        self.run(lambda: self.require_bridge().load(),done)

    def measure(self):
        def done(sequence):
            self.measuring = True
            self.notice.set('正在测量压力场景 60 秒；可自由移动开火，暂停暂时屏蔽。' if self.stress else
                            '正在测量当前弹幕 60 秒；射击和暂停暂时屏蔽，避免提前击败当前阶段。')
            self.log(f'测量命令 {sequence} 已提交。无敌调试须已开启；整个区间不进行 JTAG 读取。')
            self.root.after(62000,lambda:self.finish_measure(sequence))
        self.run(lambda:self.require_bridge().command(7),done)

    def show_status(self, status):
        self.last_status = status
        runtime, presentation = status.get('runtime',{}),status.get('presentation',{})
        state = presentation.get('state',0)
        phase = max(0,min(7,presentation.get('boss_phase',1)-1))
        label = STATES[state] if state < len(STATES) else str(state)
        self.summary.set(f'{label} | {"压力测试" if self.stress else NAMES[phase]} | 生命 {status.get("lives",0)} | '
                         f'分数 {status.get("score",0)} | FPS {status.get("fps_x100",0)/100:.2f} | '
                         f'绘制 {runtime.get("render_us",0)/1000:.2f} ms | 错误 0x{status.get("error",0):04X}')
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
    parser.add_argument('--stress',action='store_true',help='Use the dedicated invincible stress firmware')
    args = parser.parse_args()
    root = tk.Tk()
    LunariaWindow(root,args.elf,args.assets,args.stress)
    root.mainloop()


if __name__ == '__main__': main()

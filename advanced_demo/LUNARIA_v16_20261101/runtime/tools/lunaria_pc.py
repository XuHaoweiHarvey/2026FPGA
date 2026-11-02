"""Interactive PC viewer of the same C simulation, commands and art as the board.
Uses only Python's standard library and the included Windows x64 DLL.
"""
import argparse
import ctypes as ct
from pathlib import Path
import os
import time
import tkinter as tk
from tkinter import ttk

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FOLDER = Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT if (ROOT/'lunaria_pc.dll').exists() else ROOT/'output/lunaria')))
NAMES = ('环形 / 自机狙','螺旋','向日葵','花瓣','五角星 / 多边形','星形叠层','加速 / 激光','组合符卡')
KEYS = {'Up':1,'Down':2,'Left':4,'Right':8,'space':16,'z':16,'Z':16,'p':32,'P':32}

class Engine:
    def __init__(self, folder=DEFAULT_FOLDER, name='lunaria_pc.dll'):
        self.folder = Path(folder)
        self.dll = ct.CDLL(str((self.folder/name).resolve()))
        self.dll.pc_init.argtypes = [ct.POINTER(ct.c_uint32)]*2
        self.dll.pc_configure.argtypes = [ct.c_uint32]*4
        self.dll.pc_tick.argtypes = [ct.c_uint32]
        self.dll.pc_phase.argtypes = [ct.c_uint32]
        self.dll.pc_status.argtypes = [ct.POINTER(ct.c_uint32)]
        self.dll.pc_io_counts.argtypes = [ct.POINTER(ct.c_uint32)]
        self.dll.pc_pixels.restype = ct.POINTER(ct.c_uint8)
        self.dll.pc_commands.restype = ct.POINTER(ct.c_uint32)
        self.dll.pc_bullet_hash.restype = ct.c_uint32
        arrays = [(ct.c_uint32*(640*480)).from_buffer_copy((self.folder/(asset+'.argb')).read_bytes())
                  for asset in ('background','atlas')]
        self.dll.pc_init(*arrays)

    def status(self):
        values = (ct.c_uint32*16)()
        self.dll.pc_status(values)
        return list(values)

    def commands(self):
        return ct.string_at(self.dll.pc_commands(),self.dll.pc_command_count()*32)

    def pixels(self):
        return ct.string_at(self.dll.pc_pixels(),640*480*3)

class Preview:
    def __init__(self, root, folder=DEFAULT_FOLDER, schedule=True):
        self.root, self.engine, self.schedule = root, Engine(folder), schedule
        self.keys = set()
        self.timer = None
        self.closed = False
        self.limit = tk.StringVar(value='256')
        self.spin = tk.BooleanVar(value=False)
        self.invincible = tk.BooleanVar(value=False)
        self.opacity = tk.StringVar(value='255')
        self.phase = tk.StringVar(value=NAMES[0])
        self.message = tk.StringVar(value='方向键移动 · 空格/Z 射击 · P 暂停。电脑与板端使用同一套弹幕和素材。')
        root.title('LUNARIA — 电脑与板端同源预览')
        frame = ttk.Frame(root,padding=10); frame.pack(fill='both',expand=True)
        controls = ttk.Frame(frame); controls.pack(fill='x')
        ttk.Label(controls,text='敌弹上限 64–4096').grid(row=0,column=0,sticky='w')
        ttk.Combobox(controls,textvariable=self.limit,values=(64,128,256,512,1024,2048,3072,4096),width=12).grid(row=1,column=0,padx=(0,8))
        ttk.Checkbutton(controls,text='扩张时旋转',variable=self.spin).grid(row=1,column=1,padx=5)
        ttk.Checkbutton(controls,text='无敌调试',variable=self.invincible).grid(row=1,column=2,padx=5)
        ttk.Label(controls,text='Alpha 0–255').grid(row=0,column=3)
        ttk.Entry(controls,textvariable=self.opacity,width=7).grid(row=1,column=3,padx=5)
        ttk.Button(controls,text='应用',command=self.apply_settings).grid(row=1,column=4,padx=5)
        actions = ttk.Frame(frame); actions.pack(fill='x',pady=8)
        ttk.Button(actions,text='开始 / 重开战役',command=self.start).pack(side='left')
        ttk.Combobox(actions,textvariable=self.phase,values=NAMES,state='readonly',width=20).pack(side='left',padx=8)
        ttk.Button(actions,text='预览此阶段',command=self.practice).pack(side='left')
        self.canvas = tk.Canvas(frame,width=640,height=480,highlightthickness=0)
        self.canvas.pack()
        self.item = self.canvas.create_image(0,0,anchor='nw')
        ttk.Label(frame,textvariable=self.message,wraplength=640).pack(fill='x',pady=(8,0))
        self.status_text = tk.StringVar()
        ttk.Label(frame,textvariable=self.status_text).pack(fill='x')
        root.bind('<KeyPress>',self.key_down); root.bind('<KeyRelease>',self.key_up)
        root.bind('<FocusOut>',lambda event:self.keys.clear())
        self.canvas.bind('<Button-1>',lambda event:self.canvas.focus_set())
        root.protocol('WM_DELETE_WINDOW',self.close)
        self.frame_ms = time.perf_counter(); self.frame_count=0; self.fps=0
        self.draw()
        if schedule: self.timer = root.after(16,self.frame)

    def apply_settings(self):
        try:
            limit, opacity = int(self.limit.get()), int(self.opacity.get())
            if not 64 <= limit <= 4096 or not 0 <= opacity <= 255: raise ValueError
        except ValueError:
            self.message.set('敌弹上限须为 64–4096 的整数；Alpha 须为 0–255 的整数。')
            return False
        assert self.engine.dll.pc_configure(limit,int(self.spin.get()),opacity,int(self.invincible.get()))
        self.message.set(f'已应用上限 {limit}；当前弹幕与峰值已重置。实际发射数随图案变化。')
        self.canvas.focus_set()
        return True

    def start(self):
        if self.apply_settings(): self.engine.dll.pc_begin()

    def practice(self):
        if self.apply_settings(): self.engine.dll.pc_phase(NAMES.index(self.phase.get()))

    def key_down(self,event):
        if self.root.focus_get() == self.canvas and event.keysym in KEYS:
            self.keys.add(event.keysym); return 'break'

    def key_up(self,event):
        self.keys.discard(event.keysym)

    def draw(self):
        self.engine.dll.pc_draw()
        self.photo = tk.PhotoImage(data=b'P6\n640 480\n255\n'+self.engine.pixels(),format='PPM')
        self.canvas.itemconfigure(self.item,image=self.photo)
        s = self.engine.status()
        self.status_text.set(f'{NAMES[s[2]]} | 子弹 {s[5]} / 上限 {s[8]} | 可见 {s[6]} | 峰值 {s[7]} | 生命 {s[3]} | 预览 FPS {self.fps:.1f}')

    def frame(self):
        if self.closed: return
        started=time.perf_counter(); buttons=0
        for key in self.keys: buttons |= KEYS[key]
        self.engine.dll.pc_tick(buttons)
        self.draw()
        self.frame_count += 1
        if started-self.frame_ms >= 1:
            self.fps=self.frame_count/(started-self.frame_ms); self.frame_count=0; self.frame_ms=started
        if self.schedule:
            self.timer=self.root.after(max(1,16-int((time.perf_counter()-started)*1000)),self.frame)

    def close(self):
        self.closed=True
        if self.timer: self.root.after_cancel(self.timer)
        self.root.destroy()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder',type=Path,default=DEFAULT_FOLDER)
    args=parser.parse_args()
    root=tk.Tk(); Preview(root,args.folder); root.mainloop()

if __name__=='__main__': main()

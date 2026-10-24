"""Small Windows debug window for the resident Ti60 game firmware."""

from datetime import datetime
import json
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, ttk

from game_debug_bridge import DebugBridge, DEFAULT_ELF, DEFAULT_IDE, PHASES
import keyboard_uart


class DebugWindow:
    def __init__(self, root):
        self.root, self.bridge = root, None
        self.events = queue.Queue()
        self.busy = self.measuring = self.closing = False
        self.rows = []
        self.uart_stop = threading.Event()
        self.uart_thread = None
        self.uart_port = None
        self.last_status = {}
        root.title("Ti60 常驻游戏调试")
        root.geometry("960x760")
        root.minsize(840, 660)
        box = ttk.Frame(root, padding=12)
        box.pack(fill="both", expand=True)
        self.elf = tk.StringVar(value=str(DEFAULT_ELF))
        self.ide = tk.StringVar(value=str(DEFAULT_IDE))
        ttk.Label(box, text="游戏 ELF").grid(row=0, column=0, sticky="w")
        ttk.Entry(box, textvariable=self.elf, width=80).grid(row=0, column=1, columnspan=5, sticky="ew")
        ttk.Button(box, text="选择", command=self.choose_elf).grid(row=0, column=6)
        ttk.Label(box, text="RISC-V IDE").grid(row=1, column=0, sticky="w")
        ttk.Entry(box, textvariable=self.ide).grid(row=1, column=1, columnspan=6, sticky="ew")
        actions = ttk.Frame(box)
        actions.grid(row=2, column=0, columnspan=7, sticky="w", pady=8)
        for label, command in (("连接 / 读取", self.connect), ("断开", self.disconnect),
                               ("加载并运行 ELF", self.load), ("读取状态", self.read),
                               ("导出日志", self.export)):
            ttk.Button(actions, text=label, command=command).pack(side="left", padx=3)
        controls = ttk.LabelFrame(box, text="板上操作：不重新烧录", padding=8)
        controls.grid(row=3, column=0, columnspan=7, sticky="ew")
        for label, command in (("重开", 1), ("暂停", 2), ("继续", 3),
                               ("一键自测", 5), ("进入游戏", 6)):
            ttk.Button(controls, text=label, command=lambda c=command: self.send(c)).pack(side="left", padx=4)
        ttk.Button(controls, text="连续测量 60 秒", command=self.measure).pack(side="left", padx=10)
        options = ttk.LabelFrame(box, text="运行参数（修改后点击应用）", padding=8)
        options.grid(row=4, column=0, columnspan=7, sticky="ew", pady=8)
        self.delay, self.interval, self.cap, self.alpha = [tk.StringVar(value=v) for v in ("3000", "900", "48", "225")]
        self.invincible = tk.BooleanVar(value=False)
        for i, (label, variable) in enumerate((("自动重开 ms（0 关闭）", self.delay),
                                              ("敌弹间隔 ms", self.interval),
                                              ("敌机上限 1–48", self.cap),
                                              ("子弹 Alpha 0–255", self.alpha))):
            ttk.Label(options, text=label).grid(row=0, column=i)
            ttk.Entry(options, textvariable=variable, width=18).grid(row=1, column=i, padx=5)
        ttk.Checkbutton(options, text="无敌调试", variable=self.invincible).grid(row=1, column=4, padx=8)
        ttk.Button(options, text="应用", command=self.apply).grid(row=1, column=5, padx=8)
        uart = ttk.LabelFrame(box, text="键盘串口（WASD / 方向键移动，空格射击，P 暂停）", padding=8)
        uart.grid(row=5, column=0, columnspan=7, sticky="ew")
        self.port = tk.StringVar(value="")
        self.ports = ttk.Combobox(uart, textvariable=self.port, width=14, state="readonly")
        self.ports.pack(side="left", padx=4)
        self.refresh_uart_button = ttk.Button(uart, text="刷新串口", command=self.refresh_ports)
        self.refresh_uart_button.pack(side="left", padx=4)
        self.start_uart_button = ttk.Button(uart, text="开始发送", command=self.start_uart)
        self.start_uart_button.pack(side="left", padx=4)
        self.stop_uart_button = ttk.Button(uart, text="停止发送", command=self.stop_uart, state="disabled")
        self.stop_uart_button.pack(side="left", padx=4)
        self.uart_label = tk.StringVar(value="未发送；切换串口前先停止发送")
        ttk.Label(uart, textvariable=self.uart_label, wraplength=410).pack(side="left", padx=8)
        self.uart_rx_label = tk.StringVar(value="板端尚未核对；电脑发送成功不代表板卡已接收")
        ttk.Label(box, textvariable=self.uart_rx_label, wraplength=900).grid(
            row=6, column=0, columnspan=7, sticky="w", pady=(4, 0))
        self.summary = tk.StringVar(value="先结束 IDE 的 Debug，再连接。连接只读取；加载需点击“加载并运行 ELF”。")
        ttk.Label(box, textvariable=self.summary, wraplength=900).grid(row=7, column=0, columnspan=7, sticky="w", pady=8)
        self.notice = tk.StringVar(value="JTAG 读取会暂停 CPU，普通读数仅用于调试。连续测量期间不读取、不发命令。")
        ttk.Label(box, textvariable=self.notice, wraplength=900, foreground="#9b5700").grid(row=8, column=0, columnspan=7, sticky="w")
        self.output = tk.Text(box, height=15, wrap="word")
        self.output.grid(row=9, column=0, columnspan=7, sticky="nsew", pady=8)
        box.columnconfigure(1, weight=1)
        box.rowconfigure(9, weight=1)
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(100, self.pump)
        root.after(250, self.refresh_ports)

    def log(self, message, data=None):
        record = {"time": datetime.now().isoformat(timespec="seconds"), "message": message}
        if data is not None:
            record["data"] = data
        self.rows.append(record)
        self.output.insert("end", f'{record["time"]}  {message}\n')
        self.output.see("end")

    def run(self, function, done=None):
        if self.busy or self.measuring:
            self.log("正在执行操作或连续测量，请等待")
            return
        self.busy = True
        def work():
            try:
                self.events.put(("done", (function(), done)))
            except Exception as error:
                self.events.put(("error", str(error)))
        threading.Thread(target=work, daemon=True).start()

    def pump(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "done":
                    self.busy = False
                    result, callback = value
                    if callback:
                        callback(result)
                elif kind == "error":
                    self.busy = False
                    self.log(value)
                    if self.bridge and not self.bridge.matched and "板上运行程序与所选 ELF 不一致" in value:
                        self.summary.set("JTAG 已连接；新 ELF 尚未加载。请点击“加载并运行 ELF”。")
                    else:
                        self.summary.set("操作未完成，详情见日志")
                elif kind == "uart":
                    if isinstance(value, tuple):
                        label, message = value
                        self.uart_label.set(label)
                        self.log(message)
                    else:
                        self.log(value)
                elif kind == "uart_started":
                    if not self.uart_stop.is_set():
                        self.uart_label.set(f"电脑正在向 {value} 发送；板端接收待核对")
                    self.log(f"已打开 {value} 并开始发送；这仅代表电脑端发送，板端接收需读取状态确认。Esc 可停止。")
                elif kind == "uart_stopped":
                    port, failed = value
                    self.uart_port = None
                    self.set_uart_controls(False)
                    if not failed:
                        self.uart_label.set(f"{port} 已停止并关闭；可以选择其他串口")
                    self.log(f"{port} 键盘发送已停止；读取状态可核对板上接收计数")
        except queue.Empty:
            pass
        if not self.closing:
            self.root.after(100, self.pump)

    def choose_elf(self):
        if self.bridge:
            self.log("更换 ELF 前先断开 JTAG")
            return
        path = filedialog.askopenfilename(filetypes=[("RISC-V ELF", "*.elf")])
        if path:
            self.elf.set(path)

    def connect(self):
        if self.bridge:
            return self.read()
        elf, ide = self.elf.get(), self.ide.get()
        def work():
            bridge = DebugBridge(elf, ide)
            bridge.connect()
            self.bridge = bridge
            return bridge.snapshot(verify=True)
        self.run(work, self.show_status)

    def disconnect(self):
        def work():
            if self.bridge:
                self.bridge.close()
                self.bridge = None
        self.run(work, lambda _: self.log("JTAG 已断开，CPU 保留操作前的运行状态"))

    def require_bridge(self):
        if not self.bridge:
            raise RuntimeError("请先连接 JTAG")
        return self.bridge

    def load(self):
        if self.busy or self.measuring:
            self.log("正在执行操作或连续测量，请等待")
            return
        self.summary.set("正在检查安全加载条件、等待绘图结束，然后加载并校验 ELF……")
        self.log("开始加载 ELF；首次加载无需先暂停游戏，请等待操作结束。")
        def work():
            bridge = self.require_bridge()
            bridge.load()
        def done(_):
            self.log("ELF 已加载，从 _start 运行。初始化需要时间，稍后读取状态。")
            self.summary.set("ELF 已加载并启动；正在初始化素材，请稍候读取状态。")
            self.root.after(2000, self.read)
        self.run(work, done)

    def read(self):
        self.run(lambda: self.require_bridge().snapshot(), self.show_status)

    def send(self, command, options=None):
        def done(sequence):
            self.log(f"已提交命令 {command}，序号 {sequence}；等待板上确认")
            self.root.after(700, lambda: self.read_ack(sequence))
        self.run(lambda: self.require_bridge().command(command, options), done)

    def read_ack(self, sequence):
        def done(status):
            self.show_status(status)
            if status.get("acknowledged_sequence") != sequence:
                self.log("命令尚未确认，请稍后点击读取状态；不会自动重复执行")
            elif status.get("command_result"):
                self.log(f'板上拒绝命令，代码 0x{status["command_result"]:04x}')
            else:
                self.log(f"板上已确认命令 {sequence}")
        if not self.measuring:
            self.run(lambda: self.require_bridge().snapshot(), done)

    def apply(self):
        try:
            values = (int(self.delay.get()), int(self.interval.get()), int(self.cap.get()),
                      int(self.invincible.get()), int(self.alpha.get()))
        except ValueError:
            return self.log("参数必须填写整数")
        self.send(4, values)

    def measure(self):
        # Firmware owns the 60-second clock; host performs no JTAG operations in between.
        def done(sequence):
            self.measuring = True
            self.notice.set("正在连续测量 60 秒：禁止读取、调参和重开。结束后会读取板上结果。")
            self.log(f"已提交 60 秒测量命令 {sequence}；期间 P 键暂停被屏蔽，移动和射击仍可使用。")
            self.root.after(62000, lambda: self.finish_measure(sequence))
        self.run(lambda: self.require_bridge().command(7), done)

    def finish_measure(self, sequence):
        self.measuring = False
        def done(status):
            self.show_status(status)
            if status.get("acknowledged_sequence") != sequence or status.get("command_result"):
                return self.log("测量未启动，请检查状态；需在游戏运行时启动")
            if status.get("measurement_state") != 2:
                return self.log("测量未完整结束；检查故障/暂停/当前状态")
            elapsed = status["measurement_elapsed_ms"]
            fps = status["measurement_frames"] * 1000 / max(elapsed, 1)
            self.log(f'板上测量：{elapsed} ms，平均 {fps:.2f} FPS，'
                     f'最低秒窗 {status["measurement_min_fps_x100"]/100:.2f} FPS，'
                     f'精灵范围 {status["measurement_min_sprites"]}–{status["measurement_max_sprites"]}，'
                     f'underflow {status["measurement_underflows"]}，missed {status["measurement_missed"]}')
        self.run(lambda: self.require_bridge().snapshot(), done)
        self.notice.set("普通 JTAG 读取会影响运行。测量结果来自固件保存的独立 60 秒区间；日志保留原始计数。")

    def show_status(self, status):
        self.last_status = status
        phase = PHASES.get(status.get("phase"), str(status.get("phase")))
        self.summary.set(f'{phase} | 分数 {status.get("score")} | 生命 {status.get("lives")} | '
                         f'FPS {status.get("fps_x100", 0)/100:.2f} | '
                         f'精灵 {status.get("active_sprites")}/峰值 {status.get("max_active_sprites")} | '
                         f'错误 0x{status.get("error", 0):04x}')
        self.uart_rx_label.set(
            f'最近板端快照：累计接收 {status.get("uart_accepted", 0)} 帧，按键 0x{status.get("buttons",0):02x}；'
            '连续读取确认计数增长，累计值不代表当前串口连通')
        self.log("状态 " + json.dumps(status, ensure_ascii=False), status)
        if status.get("legacy_read_only"):
            self.log("当前为旧 ELF，只读状态。要使用重开/自测/调参，请选择并加载新的常驻 ELF。")
        if status.get("partial_publication"):
            self.log("读取时固件正在发布状态，字段可能跨帧；请再次读取。")
        result = status.get("self_test_result", 0)
        if result:
            self.log(f"自测通过位 0x{result & 0xffff:x}，失败位 0x{result >> 16:x}（1 FILL / 2 Key / 4 Alpha / 8 Swap）")

    def refresh_ports(self):
        if self.uart_port is not None:
            return self.log(f"当前正在使用 {self.uart_port}；请先停止发送，再刷新或切换串口")
        try:
            api = keyboard_uart.win_api()
            import ctypes
            ports = []
            for number in range(1, 257):
                name = f"COM{number}"
                target = ctypes.create_unicode_buffer(1024)
                if api.QueryDosDeviceW(name, target, len(target)):
                    ports.append(name)
            self.ports["values"] = ports
            selected = self.port.get().strip().upper()
            if selected not in ports:
                self.port.set("")
            if ports:
                self.uart_label.set("已发现 " + ", ".join(ports) + "；请选择板卡 UART 对应的 COM 口")
                self.log("可用串口：" + ", ".join(ports) + "。请按设备管理器/插拔前后变化选择板卡 UART。")
            else:
                self.port.set("")
                self.uart_label.set("未发现 COM 口；检查 USB-UART 连接/驱动后刷新")
                self.log("未发现 COM1–COM256；检查板卡 USB-UART 接口、数据线和 Windows 设备管理器。")
        except Exception as error:
            self.uart_label.set("串口列表读取失败")
            self.log(str(error))

    def start_uart(self):
        if self.uart_port is not None or (self.uart_thread and self.uart_thread.is_alive()):
            return self.log(f"当前正在使用 {self.uart_port}；请先停止发送，再切换串口")
        port = self.port.get().strip().upper()
        if len(port) <= 3 or port[:3] != "COM" or not port[3:].isdigit():
            self.uart_label.set("请先刷新并选择有效 COM 口")
            return self.log("当前串口不是有效 COM 口。点击“刷新串口”，再从列表选择设备管理器中对应板卡 UART 的 COMn；不要输入普通字符。")
        self.uart_stop.clear()
        self.uart_port = port
        self.port.set(port)
        self.set_uart_controls(True)
        self.uart_label.set(f"正在打开 {port}……")
        def work():
            handle = api = None
            sequence = 0
            failed = False
            try:
                api = keyboard_uart.win_api()
                handle = keyboard_uart.open_port(api, port, 115200)
                self.events.put(("uart_started", port))
                while not self.uart_stop.is_set():
                    buttons, escape = keyboard_uart.read_keys(api)
                    if escape:
                        break
                    keyboard_uart.write_frame(api, handle, sequence, buttons)
                    sequence = (sequence + 1) & 255
                    self.uart_stop.wait(0.02)
            except Exception as error:
                failed = True
                winerror = getattr(error, "winerror", None)
                if winerror == 2:
                    message = f"打不开 {port}：Windows 找不到此串口。重新刷新列表，并确认设备管理器里的板卡 UART COM 号。"
                    label = "所选 COM 不存在；刷新后重选"
                elif winerror == 5:
                    message = f"打不开 {port}：串口被其他程序占用。关闭串口终端/其他发送器后重试。"
                    label = "串口被占用"
                else:
                    message = f"{port} 打开或发送失败：{error}"
                    label = f"{port} 发送失败"
                self.events.put(("uart", (label, message)))
            finally:
                if handle is not None:
                    try:
                        keyboard_uart.write_frame(api, handle, sequence, 0)
                    except OSError:
                        pass
                    api.CloseHandle(handle)
                self.events.put(("uart_stopped", (port, failed)))
        self.uart_thread = threading.Thread(target=work, daemon=True)
        self.uart_thread.start()

    def stop_uart(self):
        self.uart_stop.set()
        if self.uart_port is not None:
            self.uart_label.set(f"正在停止 {self.uart_port}，关闭后可切换串口……")

    def set_uart_controls(self, sending):
        self.ports.configure(state="disabled" if sending else "readonly")
        for button in (self.refresh_uart_button, self.start_uart_button):
            button.configure(state="disabled" if sending else "normal")
        self.stop_uart_button.configure(state="normal" if sending else "disabled")

    def export(self):
        path = filedialog.asksaveasfilename(defaultextension=".json", initialfile="ti60-game-debug.json")
        if path:
            log = ""
            if self.bridge and self.bridge.log_path:
                log = self.bridge.log_path.read_text(encoding="utf8", errors="replace")
            Path(path).write_text(json.dumps({"events": self.rows, "openocd_log": log},
                                            ensure_ascii=False, indent=2), encoding="utf8")
            self.log("日志已导出：" + path)

    def close(self):
        if self.busy:
            return self.log("请等待当前 JTAG 操作完成再关闭")
        self.stop_uart()
        if self.uart_thread:
            self.uart_thread.join(timeout=2)
        if self.bridge:
            self.bridge.close()
        self.closing = True
        self.root.destroy()


def main():
    root = tk.Tk()
    DebugWindow(root)
    root.mainloop()


if __name__ == "__main__":
    main()

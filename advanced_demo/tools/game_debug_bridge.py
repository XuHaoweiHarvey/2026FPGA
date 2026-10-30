"""Resident game debug ABI over the bundled OpenOCD Tcl socket (stdlib only)."""

from contextlib import contextmanager
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_IDE = Path("D:/Efinity/efinity-riscv-ide-2026.1")
DEFAULT_ELF = ROOT / "software/interactive_demo/build/game/survival_game.elf"
CONTROL_MAGIC, STATUS_MAGIC = 0x47444331, 0x47445331
STRESS_MAGIC = 0x47535431
PRESENTATION_FIELDS = ("magic publication scale display_x display_y display_width display_height "
                       "showcase state boss_phase boss_moving first_boundary last_boundary "
                       "presentation_intervals missing_boundaries max_boundary_gap").split()
STRESS_STATUS_FIELDS = ("magic version enemies enemy_bullets rendered_enemies rendered_enemy_bullets "
                        "measurement_min_enemies measurement_max_enemies "
                        "measurement_min_enemy_bullets measurement_max_enemy_bullets "
                        "measurement_enemies measurement_enemy_bullets").split()
RUNTIME_FIELDS = ("magic publication campaign_stage campaign_result boss_hp "
                  "render_us frame_us max_render_us max_frame_us over_budget_frames "
                  "measurement_max_render_us measurement_max_frame_us measurement_over_budget_frames "
                  "background_pixels background_rectangles sprite_pixels glyph_blits stress_mode "
                  "measurement_display_frames measurement_repeated_frames "
                  "measurement_writer_throttle_cycles_lo measurement_writer_throttle_cycles_hi "
                  "measurement_writer_bursts measurement_reader_ar_stall_cycles_lo "
                  "measurement_reader_ar_stall_cycles_hi measurement_reader_r_stall_cycles_lo "
                  "measurement_reader_r_stall_cycles_hi measurement_commands "
                  "command_submit_us command_wait_us measurement_command_submit_us "
                  "measurement_command_wait_us measurement_path_diagnostics").split()
BUILD_CONFIG_FIELDS = ("magic version fullscreen view_x view_y view_width view_height "
                       "pixel_scale flash_enabled team_sprites path_diagnostics submit_timing "
                       "require_queue enemy_limit enemy_bullet_limit output_width output_height").split()
LEGACY_RUNTIME_FIELDS = ("magic publication campaign_stage campaign_result boss_hp "
                         "render_us frame_us max_render_us max_frame_us over_budget_frames "
                         "measurement_max_render_us measurement_max_frame_us measurement_over_budget_frames "
                         "background_pixels background_rectangles sprite_pixels glyph_blits stress_mode "
                         "measurement_display_frames measurement_repeated_frames").split()
STATUS_FIELDS = (
    "magic version acknowledged_sequence phase error frame score lives "
    "active_sprites max_active_sprites fps_x100 command_delta swap_delta "
    "underflow_delta missed_delta uart_accepted uart_bad_crc buttons player_x player_y "
    "auto_restart_ms enemy_fire_interval_ms enemy_limit invincible_mode dropped_ms "
    "hardware_error reader_error cpu_ddr_error cpu_ddr_status sprite_status asset_status "
    "self_test_result command_result publication "
    "measurement_state measurement_elapsed_ms measurement_frames measurement_swaps "
    "measurement_min_fps_x100 measurement_min_sprites measurement_max_sprites "
    "measurement_underflows measurement_missed raw_commands raw_swaps raw_underflows raw_missed "
    "buffer_status front_base back_base wave uart_bad_version uart_bad_flags uart_stale uart_timeout_releases"
).split()
LEGACY_FIELDS = (
    "magic phase error frame score lives active_sprites max_active_sprites fps_x100 "
    "command_delta swap_delta underflow_delta missed_delta uart_accepted uart_bad_crc "
    "uart_bad_version uart_bad_flags uart_stale uart_timeout_releases buttons player_x "
    "player_y sprite_status asset_status"
).split()
PHASES = {1: "初始化", 2: "检查素材", 3: "检查图集", 4: "游戏中", 5: "暂停",
          6: "GAME OVER", 7: "自测中", 8: "自测结果", 255: "故障"}
RAM_START, RAM_END = 0xF9000000, 0xF900FC00
APB = 0xF8100000


def tcl_word(value):
    text = str(value)
    return '"' + "".join("\\" + c if c in '\\$[]"{}' else
                         "\\n" if c == "\n" else "\\r" if c == "\r" else c
                         for c in text) + '"'


class ElfImage:
    """Read ELF32 sections/symbols without relying on stale map addresses."""

    def __init__(self, path):
        self.path = Path(path).resolve()
        self.data = self.path.read_bytes()
        if self.data[:7] != b"\x7fELF\x01\x01\x01":
            raise ValueError("需要小端 ELF32 文件")
        if struct.unpack_from("<H", self.data, 18)[0] != 243:
            raise ValueError("ELF 不是 RISC-V 程序")
        self.entry = struct.unpack_from("<I", self.data, 24)[0]
        self.load_segments = []
        offset = struct.unpack_from("<I", self.data, 32)[0]
        width, count = struct.unpack_from("<HH", self.data, 46)
        sections = [struct.unpack_from("<10I", self.data, offset + i * width)
                    for i in range(count)]
        self.symbols, self.code = {}, []
        for section in sections:
            _, kind, flags, address, start, size, link, _, _, stride = section
            if flags & 4 and size:
                if not RAM_START <= address < address + size <= RAM_END:
                    raise ValueError("代码超出板上 RAM")
                self.code.append((address, self.data[start:start+size]))
            if kind == 2:
                strings = sections[link]
                names = self.data[strings[4]:strings[4]+strings[5]]
                for pos in range(start, start + size, stride):
                    name, value, sym_size, _, _, index = struct.unpack_from("<IIIBBH", self.data, pos)
                    if name and index:
                        end = names.find(b"\0", name)
                        self.symbols[names[name:end].decode("utf8")] = (value, sym_size)
        if not RAM_START <= self.entry < RAM_END or not self.code:
            raise ValueError("ELF 没有可用的板上入口/代码")
        # Never let an explicit load write DDR or OpenOCD's reserved workspace.
        phoff = struct.unpack_from("<I", self.data, 28)[0]
        phsize, phcount = struct.unpack_from("<HH", self.data, 42)
        for i in range(phcount):
            kind, file_offset, va, pa, filesize, memsize, _, _ = struct.unpack_from("<8I", self.data, phoff+i*phsize)
            if kind == 1:
                self.load_segments.append((va, file_offset, filesize))
            if kind == 1 and (not RAM_START <= va < va+memsize <= RAM_END or
                              not RAM_START <= pa < pa+memsize <= RAM_END):
                raise ValueError("ELF 加载段超出 RAM 或占用 OpenOCD 工作区")

    def symbol(self, name, size=0):
        address, actual_size = self.symbols.get(name, (0, 0))
        if not RAM_START <= address < RAM_END or actual_size < size:
            raise ValueError(f"ELF 缺少或不匹配符号 {name}")
        return address

    def symbol_u32(self, name, word_offset=0):
        if word_offset < 0:
            raise ValueError("ELF 符号偏移不能为负数")
        address = self.symbol(name, (word_offset + 1) * 4) + word_offset * 4
        for start, offset, size in self.load_segments:
            if start <= address and address + 4 <= start + size:
                return struct.unpack_from("<I", self.data, offset + address - start)[0]
        raise ValueError(f"ELF 符号没有文件初值 {name}")


def inspection_config(root=ROOT):
    """Use the verified Titanium setup, removing its IDE-only initial halt."""
    target = root / "software/apb_reg_test/openocd/debug_ti.cfg"
    text = target.read_text(encoding="utf8")
    text, removed = re.subn(r"(?m)^[ \t]*halt[ \t]*$", "    # Desktop: preserve initial run state", text)
    if not removed:
        raise ValueError("OpenOCD 目标配置已变化，需要复核")
    # No RUN_SMP_APP variable is ever provided by this launcher.
    return text


class DebugBridge:
    LOAD_TIMEOUT_SECONDS = 10
    LOAD_POLL_SECONDS = 0.02
    LOAD_CPU_RUN_SECONDS = 0.05

    def __init__(self, elf=DEFAULT_ELF, ide=DEFAULT_IDE):
        self.image = ElfImage(elf)
        self.ide = Path(ide)
        self.process = self.sock = self.temp = self.log_file = None
        self.log_path = None
        self.matched = False
        self.halts = 0
        self.resume_blocked = False

    def connect(self):
        executable = self.ide / "openocd/bin/openocd.exe"
        if not executable.is_file():
            raise FileNotFoundError(f"找不到 {executable}")
        # Reserve an ephemeral loopback port; startup errors are surfaced below.
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        self.temp = tempfile.TemporaryDirectory(prefix="fpga-game-debug-")
        folder = Path(self.temp.name)
        target = folder / "target.cfg"
        target.write_text(inspection_config(), encoding="utf8")
        self.log_path = folder / "openocd.log"
        self.log_file = self.log_path.open("w", encoding="utf8")
        command = [str(executable), "-c", f"bindto 127.0.0.1; tcl_port {port}; gdb_port disabled; telnet_port disabled",
                   "-c", "set bsp_loc " + tcl_word((ROOT / "embedded_sw/soc_control").as_posix()),
                   "-f", str(ROOT / "software/apb_reg_test/openocd/ftdi_ti.cfg"), "-f", str(target)]
        self.process = subprocess.Popen(command, cwd=ROOT, stdout=self.log_file,
                                        stderr=subprocess.STDOUT,
                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.process.poll() is None:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=0.3)
                self.sock.settimeout(8)
                return
            except OSError:
                time.sleep(0.1)
        log = self.log_path.read_text(encoding="utf8", errors="replace")
        self.close()
        raise RuntimeError("JTAG 连接失败。先结束 IDE 的 Debug/OpenOCD，会占用同一通道。\n" + log[-4000:])

    def rpc(self, script):
        if self.sock is None:
            raise RuntimeError("请先连接 JTAG")
        # All scripts are generated locally. catch makes Jim Tcl errors explicit.
        wrapper = "set _gd_code [catch {" + script + "} _gd_result]; format \"%d\\n%s\" $_gd_code $_gd_result"
        self.sock.sendall(wrapper.encode("utf8") + b"\x1a")
        response = bytearray()
        while b"\x1a" not in response:
            part = self.sock.recv(65536)
            if not part:
                raise ConnectionError("OpenOCD 已断开")
            response.extend(part)
        code, _, result = bytes(response).split(b"\x1a", 1)[0].decode("utf8", errors="replace").partition("\n")
        if code != "0":
            raise RuntimeError("OpenOCD: " + result)
        return result.strip()

    def state(self):
        return self.rpc("set _gd_target [target current]; $_gd_target curstate")

    @contextmanager
    def halted(self):
        state = self.state()
        if state not in ("running", "halted"):
            raise RuntimeError("CPU 状态不可用: " + state)
        running = state == "running"
        try:
            if running:
                self.halts += 1
                self.rpc("halt; wait_halt 2000")
            yield running
        finally:
            if running and not self.resume_blocked and self.state() == "halted":
                self.rpc("resume")

    def read_words(self, address, count):
        result = self.rpc(f"mem2array _gd_mem 32 {address:#x} {count}; "
                          f"set _gd_values {{}}; for {{set _gd_i 0}} {{$_gd_i < {count}}} "
                          "{incr _gd_i} {lappend _gd_values $_gd_mem($_gd_i)}; set _gd_values")
        words = [int(v, 0) & 0xFFFFFFFF for v in result.split()]
        if len(words) != count:
            raise RuntimeError("JTAG 读回长度不匹配")
        return words

    def runtime_layout(self):
        symbol = self.image.symbols.get("g_game_runtime")
        if not symbol:
            return None
        address, size = symbol
        if size >= 4 * len(RUNTIME_FIELDS):
            return address, RUNTIME_FIELDS, False
        if size >= 4 * len(LEGACY_RUNTIME_FIELDS):
            return address, LEGACY_RUNTIME_FIELDS, True
        return None

    def stress_limits(self):
        if "g_game_stress_limits" not in self.image.symbols:
            return None
        values = [self.image.symbol_u32("g_game_stress_limits", i) for i in range(4)]
        if values[:2] != [STRESS_MAGIC, 1] or not (1 <= values[2] <= 48 and 1 <= values[3] <= 4096):
            raise RuntimeError("压力调参 ELF 的容量信息不正确")
        self.image.symbol("g_game_stress_request", 8)
        self.image.symbol("g_game_stress_status", 4*len(STRESS_STATUS_FIELDS))
        return {"enemies": values[2], "enemy_bullets": values[3]}

    def verify_code(self):
        for address, data in self.image.code:
            for start in range(0, len(data), 1024):
                chunk = data[start:start+1024]
                count = (len(chunk)+3)//4
                actual = struct.pack("<" + "I"*count, *self.read_words(address+start, count))
                if actual[:len(chunk)] != chunk:
                    self.matched = False
                    raise RuntimeError("板上运行程序与所选 ELF 不一致。请选择已加载的 ELF，或显式点击“加载并运行”。")
        self.matched = True

    def snapshot(self, verify=False):
        with self.halted() as running:
            if verify or not self.matched:
                self.verify_code()
            if "g_debug_status" in self.image.symbols:
                address = self.image.symbol("g_debug_status", 4*len(STATUS_FIELDS))
                values = self.read_words(address, len(STATUS_FIELDS))
                status = dict(zip(STATUS_FIELDS, values))
                if status["magic"] != STATUS_MAGIC or status["version"] != 1:
                    raise RuntimeError("调试固件尚未初始化或 ABI 不匹配")
                if status["publication"] & 1:
                    status["partial_publication"] = True
                fault_addr = self.image.symbol("g_debug_first_fault", 4*len(STATUS_FIELDS))
                first = self.read_words(fault_addr, len(STATUS_FIELDS))
                if first[0] == STATUS_MAGIC:
                    status["first_fault"] = dict(zip(STATUS_FIELDS, first))
                layout = self.runtime_layout()
                if layout:
                    runtime_address, runtime_fields, legacy_runtime = layout
                    runtime = self.read_words(runtime_address, len(runtime_fields))
                    if runtime[0] == 0x47525431:
                        status["runtime"] = dict(zip(runtime_fields, runtime))
                        if legacy_runtime:
                            status["runtime_abi_legacy"] = True
                        if runtime[1] & 1:
                            status["partial_runtime"] = True
                config_symbol = self.image.symbols.get("g_game_build_config")
                if config_symbol and config_symbol[1] >= 4 * len(BUILD_CONFIG_FIELDS):
                    config_address = self.image.symbol("g_game_build_config",
                                                       4 * len(BUILD_CONFIG_FIELDS))
                    status["build_config"] = dict(zip(BUILD_CONFIG_FIELDS,
                                                      self.read_words(config_address,
                                                                      len(BUILD_CONFIG_FIELDS))))
                marker = self.image.symbols.get("g_game_measurement_complete")
                if marker and marker[1] >= 4:
                    status["measurement_complete"] = bool(
                        self.read_words(self.image.symbol("g_game_measurement_complete", 4), 1)[0])
                status["render_options"] = {
                    "window_hud_cache": bool(self.image.symbol_u32("g_game_window_hud_cache"))
                    if "g_game_window_hud_cache" in self.image.symbols else False
                }
                limits = self.stress_limits()
                marker = self.image.symbols.get("g_game_presentation")
                if marker and marker[1] >= 4 * len(PRESENTATION_FIELDS):
                    values = self.read_words(self.image.symbol("g_game_presentation", 4*len(PRESENTATION_FIELDS)),
                                             len(PRESENTATION_FIELDS))
                    if values[0] == 0x47505231:
                        status["presentation"] = dict(zip(PRESENTATION_FIELDS, values))
                        status["partial_presentation"] = bool(values[1] & 1)
                status["showcase_available"] = ("g_game_showcase_available" in self.image.symbols and
                    self.image.symbol_u32("g_game_showcase_available") == 1)
                if limits:
                    status["stress_limits"] = limits
                    values = self.read_words(self.image.symbol("g_game_stress_status",
                                             4*len(STRESS_STATUS_FIELDS)), len(STRESS_STATUS_FIELDS))
                    if values[:2] == [STRESS_MAGIC, 1]:
                        status["stress_load"] = dict(zip(STRESS_STATUS_FIELDS, values))
            else:
                values = self.read_words(self.image.symbol("g_game_result", 96), 24)
                status = dict(zip(LEGACY_FIELDS, values))
                if status["magic"] != 0x53555256:
                    raise RuntimeError("旧游戏状态未初始化")
                status["legacy_read_only"] = True
            hardware = self.read_words(APB, 2)
            status["hardware_id"], status["hardware_version"] = hardware
            status["hardware_optimizations"] = {
                "alpha_stream": hardware[1] in (0x00090000, 0x000A0000, 0x000B0000),
                "enemy_bullet_source_cache": hardware[1] in (0x000A0000, 0x000B0000),
                "display_scale2": hardware[1] == 0x000B0000,
            }
            status["cpu_was_running"] = running
            status["jtag_halts"] = self.halts
            status["measurement_disturbed"] = True
            status["host_monotonic"] = time.monotonic()
            return status

    def command(self, command, options=None, stress=None):
        with self.halted() as running:
            if not running:
                raise RuntimeError("CPU 原本已暂停。请先在原调试器继续运行，再发送游戏命令。")
            if not self.matched:
                self.verify_code()
            address = self.image.symbol("g_debug_control", 32)
            words = self.read_words(address, 8)
            status_addr = self.image.symbol("g_debug_status", 4*len(STATUS_FIELDS))
            status = dict(zip(STATUS_FIELDS, self.read_words(status_addr, len(STATUS_FIELDS))))
            if words[0] != CONTROL_MAGIC or status["magic"] != STATUS_MAGIC or status["version"] != 1:
                raise RuntimeError("板上固件不支持调试命令")
            if words[1] != status["acknowledged_sequence"]:
                raise RuntimeError("上一条命令尚未完成，请稍后读取状态")
            if status["phase"] in (1, 2, 3):
                raise RuntimeError("固件仍在初始化，请稍后再试")
            if status["phase"] == 255:
                raise RuntimeError("固件处于故障状态；请导出日志检查首个错误")
            if status["measurement_state"] == 1:
                raise RuntimeError("60 秒测量尚未结束，不能调整负载或发送命令")
            limits = self.stress_limits()
            lunaria = ("g_lunaria_available" in self.image.symbols and
                       self.image.symbol_u32("g_lunaria_available") == 1)
            if lunaria and command not in (1, 2, 3, 4, 6, 7, 10):
                raise RuntimeError("LUNARIA 不支持原战机压力场景/自测命令，请使用专用窗口")
            if lunaria and command == 7:
                values = self.read_words(self.image.symbol("g_game_presentation",
                                         4*len(PRESENTATION_FIELDS)), len(PRESENTATION_FIELDS))
                if values[PRESENTATION_FIELDS.index("state")] != 2:
                    raise RuntimeError("LUNARIA 测量需要进入 Boss 战斗阶段")
            if command == 10 and ("g_game_showcase_available" not in self.image.symbols or
                                  self.image.symbol_u32("g_game_showcase_available") != 1):
                raise RuntimeError("当前 ELF 不含紧凑战役，请加载 game-showcase/survival_game.elf")
            if command == 9:
                if not limits:
                    raise RuntimeError("当前 ELF 不支持动态压力数量；请加载专用压力调参 ELF，v8 bit 无需重烧")
                if (stress is None or len(stress) != 2 or
                        not all(isinstance(v, int) for v in stress) or
                        not 1 <= stress[0] <= limits["enemies"] or
                        not 1 <= stress[1] <= limits["enemy_bullets"]):
                    raise ValueError(f'敌机须为 1–{limits["enemies"]}，敌弹须为 1–{limits["enemy_bullets"]}')
            if command == 7 and (status["phase"] != 4 or not status["invincible_mode"]):
                raise RuntimeError("测量前先应用无敌模式，再进入游戏；可等弹幕达到目标数量后测量")
            runtime_layout = self.runtime_layout()
            if command == 8 and runtime_layout is None:
                raise RuntimeError("这个 ELF 不支持固定压力场景，请选择新版关卡 ELF")
            if command == 7 and runtime_layout is None:
                raise RuntimeError("这个 ELF 不支持满负载测量，请选择新版关卡 ELF")
            if command == 7 and runtime_layout is not None:
                runtime_address, runtime_fields, _ = runtime_layout
                runtime = self.read_words(runtime_address, len(runtime_fields))
                if (runtime[0] != 0x47525431 or (not lunaria and (
                        not runtime[runtime_fields.index("stress_mode")] or
                        (not limits and status["enemy_limit"] != 48)))):
                    raise RuntimeError("请先点击“满负载场景”，等画面稳定后再测量 60 秒")
            sequence = (words[1] + 1) & 0xFFFFFFFF
            if options is not None:
                delay, interval, cap, invincible, alpha = options
                if not (0 <= delay <= 60000 and 150 <= interval <= 10000 and
                        1 <= cap <= 48 and invincible in (0, 1) and 0 <= alpha <= 255):
                    raise ValueError("参数范围不正确")
                for i, value in enumerate(options, 3):
                    self.rpc(f"mww {address+i*4:#x} {value:#x}")
            if command == 9:
                request = self.image.symbol("g_game_stress_request", 8)
                for i, value in enumerate(stress):
                    self.rpc(f"mww {request+i*4:#x} {value:#x}")
            self.rpc(f"mww {address+8:#x} {int(command):#x}")
            # Sequence is the commit word, always written last while halted.
            self.rpc(f"mww {address+4:#x} {sequence:#x}")
        return sequence

    def load(self):
        # Loading is explicit. Never reset FPGA, clear errors, or touch protected DDR.
        if "g_debug_control" not in self.image.symbols:
            raise RuntimeError("加载功能只接受新的常驻调试 ELF")
        deadline = time.monotonic() + self.LOAD_TIMEOUT_SECONDS
        last = None
        while True:
            retry_after_running = False
            with self.halted() as was_running:
                hardware = self.read_words(APB, 2)
                if hardware[0] != 0x4143434C or hardware[1] not in (0x00060000, 0x00070000, 0x00080000, 0x00090000, 0x000A0000, 0x000B0000):
                    raise RuntimeError("硬件 ID/版本不匹配，需要配套 advanced v6/v7/v8/v9/v10/v11 位流")
                required = (self.image.symbol_u32("g_game_required_caps")
                            if "g_game_required_caps" in self.image.symbols else 0)
                if bool(self.read_words(APB+0x40, 1)[0] & 0x4000) != (hardware[1] == 0x000B0000):
                    raise RuntimeError("硬件版本与两倍显示能力位不一致，停止加载。")
                if bool(required & 0x800) != (hardware[1] in (0x00080000, 0x00090000, 0x000A0000, 0x000B0000)):
                    raise RuntimeError("窗口读取 v8 bit 与专用窗口 ELF 必须配套；全屏/旧居中 ELF 使用原 v7 bit。")
                if hardware[1] == 0x000B0000:
                    if ("g_game_scale2_compatible" not in self.image.symbols or
                            self.image.symbol_u32("g_game_scale2_compatible") != 0x4000):
                        raise RuntimeError("v11 两倍显示需要兼容的新展示/压力 ELF；旧 ELF 使用原 v10 bit。")
                    if not self.read_words(APB+0x40, 1)[0] & 0x4000:
                        raise RuntimeError("v11 缺少两倍显示能力，停止加载。")
                if hardware[1] in (0x00090000, 0x000A0000, 0x000B0000):
                    if ("g_game_alpha_hardware_compatible" not in self.image.symbols or
                            self.image.symbol_u32("g_game_alpha_hardware_compatible") != 0x3000):
                        raise RuntimeError("v9/v10 硬件需加载修正 SPR 后的新优化 ELF；旧窗口 ELF 请配原 v8 bit。")
                    expected_features = 0x1000 if hardware[1] == 0x00090000 else 0x3000
                    if self.read_words(APB+0x40, 1)[0] & 0x3000 != expected_features:
                        raise RuntimeError("v9/v10 版本与硬件优化能力位不一致，停止加载。")
                if "g_game_required_caps" in self.image.symbols:
                    required = self.image.symbol_u32("g_game_required_caps")
                    available = self.read_words(APB+0x40, 1)[0]
                    if available & required != required:
                        label = ("中央窗口 v8 bit（显示窗口、背景和命令队列能力）" if required & 0x800
                                 else "全屏背景 bit 和命令队列 bit" if required == 0x600
                                 else "命令队列 bit")
                        raise RuntimeError("所选游戏需要" + label + "。请先重新配置本版 "
                                           "outflow/ti60f225_oob.bit，再加载 ELF；旧 v6 bit 不支持这些能力。")
                last = self._read_load_state()
                self._check_load_errors(last)
                if self._load_state_is_safe(last):
                    self._load_image()
                    return

                # An active CPU DDR session is released by the program that
                # acquired it. Briefly run the old program, then inspect again.
                cpu_owns_ddr = bool(last[2] & 1)
                if cpu_owns_ddr:
                    if not was_running:
                        raise RuntimeError("CPU 已暂停在 DDR 会话中，旧程序无法释放显存所有权。" +
                                           "请先继续运行旧程序，或重新配置位流后加载。\n" +
                                           self._load_diagnostic(last))
                    retry_after_running = True
                else:
                    # With no CPU owner, accelerator and swap traffic can
                    # drain while halted. Poll there instead of racing the
                    # next frame of the old game.
                    while time.monotonic() < deadline:
                        time.sleep(self.LOAD_POLL_SECONDS)
                        last = self._read_load_state()
                        self._check_load_errors(last)
                        if self._load_state_is_safe(last):
                            self._load_image()
                            return
            if time.monotonic() >= deadline:
                raise RuntimeError("等待安全加载边界超时；没有覆盖 RAM。\n" + self._load_diagnostic(last))
            if retry_after_running:
                # halted() restored the old CPU. Let it leave the protected
                # section, then halt it again at the next sampling point.
                time.sleep(self.LOAD_CPU_RUN_SECONDS)

    def _read_load_state(self):
        engine = self.read_words(APB+0x0C, 1)[0]
        buffers = self.read_words(APB+0x64, 1)[0]
        cpu_status, cpu_error = self.read_words(APB+0xD0, 2)
        errors = [self.read_words(APB+offset, 1)[0] for offset in (0x24, 0x78)]
        return (engine, buffers, cpu_status, cpu_error, *errors)

    @staticmethod
    def _load_state_is_safe(values):
        engine, buffers, cpu_status = values[:3]
        return not (engine & 1 or buffers & 0x24 or cpu_status & 3) and bool(buffers & 0x10)

    def _check_load_errors(self, values):
        _, _, cpu_status, cpu_error, accel_error, reader_error = values
        if cpu_error or accel_error or reader_error:
            raise RuntimeError("硬件已有粘滞错误，拒绝覆盖固件；请导出日志检查：" +
                               self._load_diagnostic(values))
        if cpu_status & 4:
            raise RuntimeError("CPU DDR 会话故障位已锁存，拒绝加载；请重新配置位流后再加载。" +
                               "不会清除该故障或覆盖 RAM。\n" + self._load_diagnostic(values))

    def _load_image(self):
        # Once RAM may have changed, no exception path may resume the old PC.
        self.resume_blocked = True
        self.matched = False
        try:
            self.rpc("load_image " + tcl_word(self.image.path.as_posix()) + " 0 elf")
            self.verify_code()
            self.rpc(f"resume {self.image.entry:#x}")
        except Exception as error:
            self.matched = False
            raise RuntimeError("ELF 加载/校验/启动失败；已禁止从旧 PC 自动恢复，请重新加载完整 ELF：" + str(error)) from error
        self.resume_blocked = False

    @staticmethod
    def _load_diagnostic(values):
        if values is None:
            return "尚未读到硬件状态"
        engine, buffers, cpu_status, cpu_error, accel_error, reader_error = values
        return (f"engine=0x{engine:08x} (busy={bool(engine & 1)}), "
                f"buffers=0x{buffers:08x} (front_valid={bool(buffers & 0x10)}, "
                f"swap_pending={bool(buffers & 4)}, writer_owned={bool(buffers & 0x20)}), "
                f"cpu_ddr_status=0x{cpu_status:08x} (session={bool(cpu_status & 1)}, "
                f"busy={bool(cpu_status & 2)}, fault={bool(cpu_status & 4)}), "
                f"cpu_ddr_error=0x{cpu_error:08x}, accel_error=0x{accel_error:08x}, "
                f"reader_error=0x{reader_error:08x}")

    def close(self):
        # Per-operation finally blocks restore running state. Disconnect issues no halt.
        if self.sock:
            try:
                self.rpc("shutdown")
            except (OSError, RuntimeError):
                pass
            self.sock.close()
            self.sock = None
        if self.process:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=2)
            self.process = None
        if self.log_file:
            self.log_file.close()
            self.log_file = None
        if self.temp:
            self.temp.cleanup()
            self.temp = None

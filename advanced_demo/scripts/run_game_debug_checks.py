"""Offline debug bridge, ABI, UI construction and real Jim Tcl checks; no board."""

from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from game_debug_bridge import (APB, CONTROL_MAGIC, DEFAULT_ELF, DEFAULT_IDE, DebugBridge,
                               ElfImage, STATUS_FIELDS, STATUS_MAGIC, RUNTIME_FIELDS,
                               LEGACY_RUNTIME_FIELDS, inspection_config, tcl_word)


class FakeBridge(DebugBridge):
    def __init__(self):
        super().__init__()
        self.cpu = "running"
        self.writes, self.calls = [], []
        self.memory = {}
        self.broken_address = None
        self.load_states = None
        for address, data in self.image.code:
            padded = data + b"\0" * ((-len(data)) % 4)
            for pos in range(0, len(padded), 4):
                self.memory[address+pos] = struct.unpack_from("<I", padded, pos)[0]
        control = self.image.symbol("g_debug_control", 32)
        for i, value in enumerate((CONTROL_MAGIC, 0, 0, 3000, 900, 48, 0, 225)):
            self.memory[control+i*4] = value
        self.set_status(magic=STATUS_MAGIC, version=1, phase=4, publication=2)
        if "g_game_runtime" in self.image.symbols:
            self.memory[self.image.symbol("g_game_runtime", 4*len(RUNTIME_FIELDS))] = 0x47525431
        self.memory.update({APB: 0x4143434C, APB+4: 0x00070000,
                            APB+0x40: 0x7FB, APB+0x64: 0x10})

    def set_status(self, **values):
        address = self.image.symbol("g_debug_status", 4*len(STATUS_FIELDS))
        for name, value in values.items():
            self.memory[address+STATUS_FIELDS.index(name)*4] = value

    def rpc(self, script):
        self.calls.append(script)
        if "curstate" in script:
            return self.cpu
        if script == "halt; wait_halt 2000":
            self.cpu = "halted"
        elif script.startswith("resume"):
            self.cpu = "running"
        elif script.startswith("mww"):
            _, address, value = script.split()
            address, value = int(address, 0), int(value, 0)
            self.memory[address] = value
            self.writes.append((address, value))
        elif script.startswith("load_image"):
            pass
        else:
            raise AssertionError("Unexpected RPC: " + script)
        return ""

    def read_words(self, address, count):
        if self.broken_address == address:
            raise OSError("injected read failure")
        return [self.memory.get(address+i*4, 0) for i in range(count)]

    def _read_load_state(self):
        if self.load_states:
            self.last_load_state = self.load_states.pop(0) if len(self.load_states) > 1 else self.load_states[0]
            return self.last_load_state
        if hasattr(self, "last_load_state"):
            return self.last_load_state
        return super()._read_load_state()


class DebugTests(unittest.TestCase):
    def test_elf_abi_matches_c(self):
        image = ElfImage(DEFAULT_ELF)
        self.assertEqual(image.symbols["g_debug_control"][1], 32)
        self.assertEqual(image.symbols["g_debug_status"][1], len(STATUS_FIELDS)*4)
        self.assertEqual(image.symbols["g_debug_first_fault"][1], len(STATUS_FIELDS)*4)
        header = (ROOT / "software/interactive_demo/game_debug_abi.h").read_text()
        body = re.search(r"typedef struct \{([^}]+)\} game_debug_status_t;", header).group(1)
        names = re.findall(r"uint32_t ([^;]+);", body)
        self.assertEqual([item.strip() for group in names for item in group.split(",")], STATUS_FIELDS)
        self.assertEqual(image.entry, image.symbols["_start"][0])

    def test_snapshot_restores_original_cpu_state(self):
        bridge = FakeBridge()
        before = dict(bridge.memory)
        status = bridge.snapshot(verify=True)
        self.assertEqual(status["phase"], 4)
        self.assertTrue(status["measurement_disturbed"])
        self.assertEqual(bridge.cpu, "running")
        self.assertEqual(before, bridge.memory)
        bridge.cpu = "halted"
        bridge.calls.clear()
        bridge.snapshot()
        self.assertEqual(bridge.cpu, "halted")
        self.assertNotIn("resume", bridge.calls)

    def test_runtime_extension_matches_c_and_reports_partial_publication(self):
        bridge = FakeBridge()
        header = (ROOT / "software/interactive_demo/game_runtime.h").read_text()
        body = re.search(r"typedef struct \{([^}]+)\} game_runtime_t;", header).group(1)
        names = re.findall(r"uint32_t ([^;]+);", body)
        self.assertEqual([item.strip() for group in names for item in group.split(",")], RUNTIME_FIELDS)
        address = bridge.image.symbol("g_game_runtime", 4*len(RUNTIME_FIELDS))
        self.assertEqual(bridge.image.symbols["g_game_runtime"][1], 4*len(RUNTIME_FIELDS))
        bridge.memory[address+4] = 3
        bridge.memory[address+4*RUNTIME_FIELDS.index("measurement_repeated_frames")] = 7
        status = bridge.snapshot()
        self.assertEqual(status["runtime"]["measurement_repeated_frames"], 7)
        self.assertTrue(status["partial_runtime"])
        bridge.image.symbols.pop("g_game_runtime")
        self.assertNotIn("runtime", bridge.snapshot()) # Existing ABI1 firmware remains readable.

    def test_previous_runtime_layout_remains_readable_and_measurable(self):
        bridge = FakeBridge()
        address, _ = bridge.image.symbols["g_game_runtime"]
        bridge.image.symbols["g_game_runtime"] = (address, 4*len(LEGACY_RUNTIME_FIELDS))
        bridge.memory[address + 4*LEGACY_RUNTIME_FIELDS.index("stress_mode")] = 1
        bridge.set_status(invincible_mode=1, enemy_limit=48)
        status = bridge.snapshot()
        self.assertTrue(status["runtime_abi_legacy"])
        self.assertEqual(status["runtime"]["stress_mode"], 1)
        self.assertEqual(bridge.command(7), 1)

    def test_campaign_cannot_be_measured_as_a_constant_stress_scene(self):
        bridge = FakeBridge()
        bridge.set_status(invincible_mode=1, enemy_limit=48)
        with self.assertRaisesRegex(RuntimeError, "满负载场景"):
            bridge.command(7)
        self.assertEqual(bridge.writes, [])
        address = bridge.image.symbol("g_game_runtime", 4*len(RUNTIME_FIELDS))
        bridge.memory[address + 4*RUNTIME_FIELDS.index("stress_mode")] = 1
        self.assertEqual(bridge.command(7), 1)
        self.assertEqual(bridge.cpu, "running")

    def test_read_error_and_wrong_elf_restore_running_cpu(self):
        bridge = FakeBridge()
        bridge.broken_address = bridge.image.code[0][0]
        with self.assertRaises(OSError):
            bridge.snapshot()
        self.assertEqual(bridge.cpu, "running")
        bridge.broken_address = None
        bridge.memory[bridge.image.code[0][0]] ^= 1
        with self.assertRaisesRegex(RuntimeError, "不一致"):
            bridge.command(1)
        self.assertEqual(bridge.cpu, "running")
        self.assertEqual(bridge.writes, [])

    def test_command_commits_sequence_last_and_waits_for_ack(self):
        bridge = FakeBridge()
        control = bridge.image.symbol("g_debug_control", 32)
        sequence = bridge.command(4, (3000, 500, 12, 1, 128))
        self.assertEqual(sequence, 1)
        self.assertEqual(bridge.writes[-1], (control+4, 1))
        self.assertEqual(bridge.writes[-2], (control+8, 4))
        self.assertEqual(len(bridge.writes), 7)
        self.assertEqual(bridge.cpu, "running")
        with self.assertRaisesRegex(RuntimeError, "尚未完成"):
            bridge.command(1)
        bridge.set_status(acknowledged_sequence=1)
        self.assertEqual(bridge.command(1), 2)

    def test_invalid_options_fault_and_halted_cpu_never_write(self):
        bridge = FakeBridge()
        with self.assertRaises(ValueError):
            bridge.command(4, (3000, 900, 49, 0, 255))
        bridge.set_status(phase=255)
        with self.assertRaisesRegex(RuntimeError, "故障"):
            bridge.command(1)
        bridge.cpu = "halted"
        with self.assertRaisesRegex(RuntimeError, "原本已暂停"):
            bridge.command(1)
        self.assertEqual(bridge.cpu, "halted")
        self.assertEqual(bridge.writes, [])

    def test_load_starts_entry_only_on_safe_matching_hardware(self):
        bridge = FakeBridge()
        bridge.load()
        self.assertIn(f"resume {bridge.image.entry:#x}", bridge.calls)
        self.assertTrue(any(call.startswith("load_image ") for call in bridge.calls))
        for offset, value in ((4, 0x00050000), (0x24, 3), (0xD4, 1)):
            bridge = FakeBridge()
            bridge.memory[APB+offset] = value
            with self.assertRaises(RuntimeError):
                bridge.load()
            self.assertFalse(any(call.startswith("load_image ") for call in bridge.calls))
            self.assertEqual(bridge.cpu, "running")

    def test_load_drains_accelerator_without_running_cpu(self):
        bridge = FakeBridge()
        bridge.load_states = [(1, 0x30, 0, 0, 0, 0), (0, 0x30, 0, 0, 0, 0),
                              (0, 0x14, 0, 0, 0, 0), (0, 0x10, 0, 0, 0, 0)]
        bridge.load()
        image_call = next(i for i, call in enumerate(bridge.calls) if call.startswith("load_image "))
        self.assertNotIn("resume", bridge.calls[:image_call])
        self.assertIn(f"resume {bridge.image.entry:#x}", bridge.calls[image_call:])
        self.assertEqual(bridge.cpu, "running")

    def test_fullscreen_elf_rejects_old_bit_before_ram_write(self):
        bridge = FakeBridge()
        self.assertEqual(bridge.image.symbol_u32("g_game_required_caps"), 0x600)
        bridge.memory[APB+0x40] = 0x1FB
        with self.assertRaisesRegex(RuntimeError, "全屏背景 bit"):
            bridge.load()
        self.assertFalse(any(call.startswith("load_image ") for call in bridge.calls))
        self.assertEqual(bridge.writes, [])
        self.assertEqual(bridge.cpu, "running")
        bridge.image.symbols.pop("g_game_required_caps")
        bridge.load()  # An old small-window ELF still works with the old bit.
        self.assertTrue(any(call.startswith("load_image ") for call in bridge.calls))

    def test_load_runs_old_cpu_only_to_release_owned_ddr(self):
        bridge = FakeBridge()
        bridge.load_states = [(0, 0x30, 1, 0, 0, 0), (0, 0x10, 0, 0, 0, 0)]
        bridge.load()
        image_call = next(i for i, call in enumerate(bridge.calls) if call.startswith("load_image "))
        self.assertIn("resume", bridge.calls[:image_call])
        self.assertIn(f"resume {bridge.image.entry:#x}", bridge.calls[image_call:])
        self.assertEqual(bridge.cpu, "running")

    def test_load_refuses_cpu_halted_inside_ddr_session_with_registers(self):
        bridge = FakeBridge()
        bridge.cpu = "halted"
        bridge.load_states = [(0, 0x30, 1, 0, 0, 0)]
        with self.assertRaisesRegex(RuntimeError, "(?s)CPU 已暂停在 DDR 会话.*cpu_ddr_status=0x00000001"):
            bridge.load()
        self.assertFalse(any(call.startswith("load_image ") for call in bridge.calls))
        self.assertEqual(bridge.cpu, "halted")

    def test_load_timeout_reports_registers_and_never_overwrites_ram(self):
        bridge = FakeBridge()
        bridge.LOAD_TIMEOUT_SECONDS = 0.004
        bridge.LOAD_POLL_SECONDS = 0.001
        bridge.load_states = [(1, 0x30, 0, 0, 0, 0)]
        with self.assertRaisesRegex(RuntimeError, "(?s)等待安全加载边界超时.*engine=0x00000001"):
            bridge.load()
        self.assertFalse(any(call.startswith("load_image ") for call in bridge.calls))
        self.assertEqual(bridge.cpu, "running")

    def test_load_rejects_latched_session_fault_with_diagnostic(self):
        bridge = FakeBridge()
        bridge.load_states = [(0, 0x10, 4, 0, 0, 0)]
        with self.assertRaisesRegex(RuntimeError, "(?s)CPU DDR 会话故障位已锁存.*fault=True"):
            bridge.load()
        self.assertFalse(any(call.startswith("load_image ") for call in bridge.calls))
        self.assertEqual(bridge.cpu, "running")

    def test_sequence_wrap_and_partial_publication(self):
        bridge = FakeBridge()
        control = bridge.image.symbol("g_debug_control", 32)
        bridge.memory[control+4] = 0xFFFFFFFF
        bridge.set_status(acknowledged_sequence=0xFFFFFFFF, publication=3)
        self.assertTrue(bridge.snapshot()["partial_publication"])
        self.assertEqual(bridge.command(1), 0)

    def test_partial_load_failure_keeps_cpu_halted(self):
        bridge = FakeBridge()
        rpc = bridge.rpc
        def failed_load(script):
            if script.startswith("load_image"):
                raise OSError("injected load failure")
            return rpc(script)
        bridge.rpc = failed_load
        with self.assertRaisesRegex(RuntimeError, "禁止从旧 PC 自动恢复"):
            bridge.load()
        self.assertEqual(bridge.cpu, "halted")
        self.assertTrue(bridge.resume_blocked)

    def test_entry_resume_failure_never_falls_back_to_old_pc(self):
        bridge = FakeBridge()
        rpc = bridge.rpc
        def failed_resume(script):
            if script.startswith("resume "):
                raise OSError("injected entry resume failure")
            return rpc(script)
        bridge.rpc = failed_resume
        with self.assertRaisesRegex(RuntimeError, "禁止从旧 PC 自动恢复"):
            bridge.load()
        self.assertNotIn("resume", bridge.calls)
        self.assertEqual(bridge.cpu, "halted")
        self.assertTrue(bridge.resume_blocked)
        self.assertFalse(bridge.matched)

    def test_old_game_remains_read_only(self):
        bridge = FakeBridge()
        bridge.image.symbols = {name: value for name, value in bridge.image.symbols.items()
                                if not name.startswith("g_debug_")}
        result = bridge.image.symbol("g_game_result", 96)
        bridge.memory[result] = 0x53555256
        bridge.memory[result+4] = 4
        status = bridge.snapshot()
        self.assertTrue(status["legacy_read_only"])
        self.assertEqual(bridge.writes, [])

    def test_real_tk_window_constructs_without_board(self):
        import tkinter as tk
        from game_debug_window import DebugWindow
        root = tk.Tk()
        root.withdraw()
        try:
            window = DebugWindow(root)
            root.update_idletasks()
            self.assertEqual(window.delay.get(), "0")
            self.assertFalse(window.measuring)
            self.assertIsNone(window.bridge)
            self.assertEqual(str(window.ports.cget("state")), "readonly")
            window.port.set("a")
            window.start_uart()
            self.assertIn("不是有效 COM 口", window.rows[-1]["message"])
        finally:
            root.destroy()

    def test_uart_locks_active_port_and_restores_controls_after_close(self):
        import tkinter as tk
        from game_debug_window import DebugWindow
        root = tk.Tk()
        root.withdraw()
        window = DebugWindow(root)
        sent = threading.Event()
        api = Mock()
        try:
            with patch.multiple("game_debug_window.keyboard_uart",
                                win_api=Mock(return_value=api),
                                open_port=Mock(return_value=123),
                                read_keys=Mock(return_value=(0, False)),
                                write_frame=Mock(side_effect=lambda *args: sent.set())):
                from game_debug_window import keyboard_uart
                window.port.set("COM13")
                window.start_uart()
                self.assertTrue(sent.wait(2), "mock sender did not start")
                window.pump()
                self.assertEqual(window.uart_port, "COM13")
                self.assertEqual(str(window.ports.cget("state")), "disabled")
                self.assertTrue(window.start_uart_button.instate(("disabled",)))
                self.assertTrue(window.refresh_uart_button.instate(("disabled",)))
                window.start_uart()
                window.refresh_ports()
                keyboard_uart.open_port.assert_called_once_with(api, "COM13", 115200)
                self.assertIn("COM13", window.rows[-1]["message"])
                label = window.uart_label.get()
                window.show_status({"uart_accepted": 123, "buttons": 4})
                self.assertEqual(window.uart_label.get(), label)
                self.assertIn("累计接收 123", window.uart_rx_label.get())
                window.stop_uart()
                window.uart_thread.join(timeout=2)
                self.assertFalse(window.uart_thread.is_alive())
                api.CloseHandle.assert_called_once_with(123)
                window.pump()
                self.assertIsNone(window.uart_port)
                self.assertEqual(str(window.ports.cget("state")), "readonly")
                self.assertFalse(window.start_uart_button.instate(("disabled",)))
                self.assertIn("COM13 已停止并关闭", window.uart_label.get())
                window.port.set("COM7")
                window.start_uart()
                window.stop_uart()
                window.uart_thread.join(timeout=2)
                self.assertEqual(keyboard_uart.open_port.call_args.args, (api, "COM7", 115200))
                window.pump()
        finally:
            window.stop_uart()
            if window.uart_thread:
                window.uart_thread.join(timeout=2)
            root.destroy()

    def test_uart_open_failure_unlocks_port_and_retains_error(self):
        import ctypes
        import tkinter as tk
        from game_debug_window import DebugWindow
        root = tk.Tk()
        root.withdraw()
        try:
            window = DebugWindow(root)
            with patch("game_debug_window.keyboard_uart.win_api", return_value=Mock()), \
                 patch("game_debug_window.keyboard_uart.open_port", side_effect=ctypes.WinError(5)):
                window.port.set("COM7")
                window.start_uart()
                window.uart_thread.join(timeout=2)
                self.assertFalse(window.uart_thread.is_alive())
                window.pump()
                self.assertIsNone(window.uart_port)
                self.assertEqual(str(window.ports.cget("state")), "readonly")
                self.assertIn("串口被占用", window.uart_label.get())
        finally:
            root.destroy()


def real_jim_check():
    with tempfile.TemporaryDirectory(prefix="game-debug-jim-") as folder_name:
        folder = Path(folder_name)
        guard, target, check = [folder / name for name in ("guard.tcl", "target.cfg", "check.tcl")]
        guard.write_text("""
set GD_CALLS {}
foreach cmd {adapter ftdi jtag target vexriscv targets poll_period init halt reset resume load_image jtag_ntrst_delay gdb_target_description} {
    if {[llength [info commands $cmd]]} {rename $cmd GD_saved_$cmd}
    proc $cmd {args} "lappend ::GD_CALLS \\[linsert \\$args 0 $cmd\\]"
}
""", encoding="utf8")
        target.write_text(inspection_config(), encoding="utf8")
        strange = "C:/folder with spaces/{file}[$not_a_variable]/game.elf"
        check.write_text("""
foreach forbidden {halt reset resume load_image} {
    foreach call $GD_CALLS {
        if {[lindex $call 0] eq $forbidden} {error "Connection changed CPU state"}
    }
}
foreach required {{adapter speed 800} {ftdi channel 1}} {
    if {[lsearch -exact $GD_CALLS $required] < 0} {error "Wrong adapter"}
}
""" + "set escaped " + tcl_word(strange) + "\n" + """
if {[string length $escaped] != 59} {error "Tcl path quoting changed"}
set _gd_code [catch {set _gd_values {}; for {set _gd_i 0} {$_gd_i < 3} {incr _gd_i} {lappend _gd_values $_gd_i}; set _gd_values} _gd_result]
if {$_gd_code != 0 || $_gd_result ne "0 1 2"} {error "RPC loop/list syntax"}
echo "PASS desktop Jim Tcl setup: no halt/reset/load, expected adapter, escaped paths, RPC list syntax"
""", encoding="utf8")
        # Keep the exact string length assertion in sync with the fixture.
        text = check.read_text(encoding="utf8").replace("!= 59", f"!= {len(strange)}")
        check.write_text(text, encoding="utf8")
        command = [str(DEFAULT_IDE / "openocd/bin/openocd.exe"), "-f", str(guard),
                   "-c", "set bsp_loc " + tcl_word((ROOT / "embedded_sw/soc_control").as_posix()),
                   "-f", str(ROOT / "software/apb_reg_test/openocd/ftdi_ti.cfg"),
                   "-f", str(target), "-f", str(check), "-c", "shutdown"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        if result.returncode or "PASS desktop Jim Tcl" not in result.stdout+result.stderr:
            raise AssertionError(result.stdout+result.stderr)
        print("PASS real OpenOCD Jim Tcl desktop config/RPC syntax (hardware calls disabled)")


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DebugTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    real_jim_check()

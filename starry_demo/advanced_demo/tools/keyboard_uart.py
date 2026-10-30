#!/usr/bin/env python3
"""Forward PC keyboard state to the advanced demo over a Windows COM port."""

import argparse
import ctypes
import sys
import time
from ctypes import wintypes

SYNC = (0xA5, 0x5A)
VERSION = 1
UP, DOWN, LEFT, RIGHT, FIRE, PAUSE = (1, 2, 4, 8, 16, 32)


def crc8(data):
    crc = 0
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def encode_frame(sequence, buttons):
    body = bytes((VERSION, sequence & 0xFF, buttons & 0x3F))
    return bytes(SYNC) + body + bytes((crc8(body),))


class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wintypes.DWORD), ("BaudRate", wintypes.DWORD),
        ("flags", wintypes.DWORD), ("wReserved", wintypes.WORD),
        ("XonLim", wintypes.WORD), ("XoffLim", wintypes.WORD),
        ("ByteSize", wintypes.BYTE), ("Parity", wintypes.BYTE),
        ("StopBits", wintypes.BYTE), ("XonChar", ctypes.c_char),
        ("XoffChar", ctypes.c_char), ("ErrorChar", ctypes.c_char),
        ("EofChar", ctypes.c_char), ("EvtChar", ctypes.c_char),
        ("wReserved1", wintypes.WORD),
    ]


class COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [(name, wintypes.DWORD) for name in (
        "ReadIntervalTimeout", "ReadTotalTimeoutMultiplier",
        "ReadTotalTimeoutConstant", "WriteTotalTimeoutMultiplier",
        "WriteTotalTimeoutConstant")]


def win_api():
    if sys.platform != "win32":
        raise RuntimeError("This keyboard sender currently requires Windows.")
    api = ctypes.WinDLL("kernel32", use_last_error=True)
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    api.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                                wintypes.HANDLE]
    api.CreateFileW.restype = wintypes.HANDLE
    api.GetCommState.argtypes = [wintypes.HANDLE, ctypes.POINTER(DCB)]
    api.GetCommState.restype = wintypes.BOOL
    api.SetCommState.argtypes = [wintypes.HANDLE, ctypes.POINTER(DCB)]
    api.SetCommState.restype = wintypes.BOOL
    api.SetCommTimeouts.argtypes = [wintypes.HANDLE, ctypes.POINTER(COMMTIMEOUTS)]
    api.SetCommTimeouts.restype = wintypes.BOOL
    api.SetupComm.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
    api.SetupComm.restype = wintypes.BOOL
    api.PurgeComm.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    api.PurgeComm.restype = wintypes.BOOL
    api.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                              ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
    api.WriteFile.restype = wintypes.BOOL
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL
    api.QueryDosDeviceW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]
    api.QueryDosDeviceW.restype = wintypes.DWORD
    user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
    user32.GetAsyncKeyState.restype = ctypes.c_short
    api.GetAsyncKeyState = user32.GetAsyncKeyState
    api._user32 = user32  # retain the DLL handle used by the function pointer
    return api


def list_ports(api):
    for number in range(1, 257):
        name = f"COM{number}"
        target = ctypes.create_unicode_buffer(1024)
        if api.QueryDosDeviceW(name, target, len(target)):
            print(f"{name}: {target.value}")


def open_port(api, name, baud):
    path = name if name.startswith("\\\\.\\") else "\\\\.\\" + name
    invalid = ctypes.c_void_p(-1).value
    handle = api.CreateFileW(path, 0x40000000, 0, None, 3, 0, None)
    if handle == invalid:
        raise ctypes.WinError(ctypes.get_last_error(), f"Cannot open {name}")

    try:
        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not api.GetCommState(handle, ctypes.byref(dcb)):
            raise ctypes.WinError(ctypes.get_last_error(), "GetCommState failed")
        dcb.BaudRate = baud
        dcb.flags = 1  # binary mode; parity, flow control, DTR and RTS disabled
        dcb.ByteSize, dcb.Parity, dcb.StopBits = 8, 0, 0
        if not api.SetCommState(handle, ctypes.byref(dcb)):
            raise ctypes.WinError(ctypes.get_last_error(), "SetCommState failed")
        if not api.SetupComm(handle, 4096, 4096):
            raise ctypes.WinError(ctypes.get_last_error(), "SetupComm failed")
        timeouts = COMMTIMEOUTS(0, 0, 0, 0, 1000)
        if not api.SetCommTimeouts(handle, ctypes.byref(timeouts)):
            raise ctypes.WinError(ctypes.get_last_error(), "SetCommTimeouts failed")
        api.PurgeComm(handle, 0x000F)
        return handle
    except Exception:
        api.CloseHandle(handle)
        raise


def read_keys(api):
    down = lambda vk: bool(api.GetAsyncKeyState(vk) & 0x8000)
    buttons = 0
    if down(ord("W")) or down(0x26):
        buttons |= UP
    if down(ord("S")) or down(0x28):
        buttons |= DOWN
    if down(ord("A")) or down(0x25):
        buttons |= LEFT
    if down(ord("D")) or down(0x27):
        buttons |= RIGHT
    if down(0x20) or down(0x11):
        buttons |= FIRE
    if down(ord("P")):
        buttons |= PAUSE
    return buttons, down(0x1B)


def write_frame(api, handle, sequence, buttons):
    frame = encode_frame(sequence, buttons)
    sent = wintypes.DWORD()
    buffer = ctypes.create_string_buffer(frame)
    if not api.WriteFile(handle, buffer, len(frame), ctypes.byref(sent), None):
        raise ctypes.WinError(ctypes.get_last_error(), "UART write failed")
    if sent.value != len(frame):
        raise OSError(f"Short UART write: {sent.value}/{len(frame)} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", nargs="?", help="COM port, for example COM7")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--rate", type=int, default=50, help="key-state frames per second")
    parser.add_argument("--list", action="store_true", help="list present COM ports")
    args = parser.parse_args()
    if not args.list and not args.port:
        parser.error("provide a COM port or use --list")
    if not 1 <= args.rate <= 200 or args.baud <= 0:
        parser.error("rate must be 1..200 Hz and baud must be positive")

    api = win_api()
    if args.list:
        list_ports(api)
        return 0

    handle = open_port(api, args.port, args.baud)
    period = 1.0 / args.rate
    sequence = 0
    last_buttons = None
    next_send = time.perf_counter()
    print(f"Sending keyboard state to {args.port} at {args.baud} baud / {args.rate} Hz.")
    print("Move: WASD or arrows | Fire: Space or Ctrl | Pause: P | Stop: Esc")
    print("Keep the board receiver running; Esc or Ctrl+C sends a release frame.")
    try:
        while True:
            buttons, escape = read_keys(api)
            if escape:
                break
            now = time.perf_counter()
            if now >= next_send:
                write_frame(api, handle, sequence, buttons)
                sequence = (sequence + 1) & 0xFF
                if buttons != last_buttons:
                    print(f"keys=0x{buttons:02X}")
                    last_buttons = buttons
                next_send = max(next_send + period, now)
            time.sleep(max(0.0, min(0.002, next_send - time.perf_counter())))
    except KeyboardInterrupt:
        pass
    finally:
        try:
            write_frame(api, handle, sequence, 0)
            time.sleep(0.02)
            write_frame(api, handle, (sequence + 1) & 0xFF, 0)
        finally:
            api.CloseHandle(handle)
    print("Sent key release; UART closed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

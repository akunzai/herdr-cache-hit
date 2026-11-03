#!/usr/bin/env python3
"""Find the coding agent running under a Windows terminal's shell.

herdr-core reports no foreground process on Windows, only the shell's pid.
Walk that pid's descendants and print {"pid", "name"} of the one agent
process found, or nothing when there is none or more than one.
"""

import json
import sys

AGENTS = {"claude.exe", "codex.exe", "agy.exe", "opencode.exe"}


def processes():
    import ctypes
    from ctypes import wintypes

    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    snap = kernel32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
    if snap in (None, wintypes.HANDLE(-1).value):
        return []
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(Entry)
        out = []
        ok = kernel32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            out.append((entry.th32ProcessID, entry.th32ParentProcessID, entry.szExeFile))
            ok = kernel32.Process32NextW(snap, ctypes.byref(entry))
        return out
    finally:
        kernel32.CloseHandle(snap)


def process_details(pid):
    """The process's working directory and argv, read from its PEB (64-bit)."""
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ntdll = ctypes.WinDLL("ntdll")
    shell32 = ctypes.WinDLL("shell32")
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.ReadProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                           ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    ntdll.NtQueryInformationProcess.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                                wintypes.ULONG, ctypes.POINTER(wintypes.ULONG)]
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
    shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    if ctypes.sizeof(ctypes.c_void_p) != 8:
        return {}
    handle = kernel32.OpenProcess(0x0410, False, pid)  # QUERY_INFORMATION | VM_READ
    if not handle:
        return {}

    def read(address, size):
        buf = ctypes.create_string_buffer(size)
        done = ctypes.c_size_t()
        if not kernel32.ReadProcessMemory(handle, ctypes.c_void_p(address), buf, size, ctypes.byref(done)) or done.value != size:
            raise OSError("ReadProcessMemory failed")
        return buf.raw

    def unicode_string(address):
        raw = read(address, 16)
        length, buffer = int.from_bytes(raw[0:2], "little"), int.from_bytes(raw[8:16], "little")
        return read(buffer, length).decode("utf-16-le") if length and buffer else ""

    try:
        info = ctypes.create_string_buffer(48)  # PROCESS_BASIC_INFORMATION
        if ntdll.NtQueryInformationProcess(handle, 0, info, 48, None) != 0:
            return {}
        peb = int.from_bytes(info.raw[8:16], "little")
        params = int.from_bytes(read(peb + 0x20, 8), "little")
        cwd = unicode_string(params + 0x38)  # CurrentDirectory.DosPath
        if len(cwd) > 3:
            cwd = cwd.rstrip("\\")
        argc = ctypes.c_int()
        line = unicode_string(params + 0x70)  # CommandLine
        argv_p = shell32.CommandLineToArgvW(line, ctypes.byref(argc)) if line else None
        argv = []
        if argv_p:
            argv = [argv_p[i] for i in range(argc.value)]
            kernel32.LocalFree(argv_p)
        return {"cwd": cwd or None, "argv": argv}
    except OSError:
        return {}
    finally:
        kernel32.CloseHandle(handle)


def agent_under(root, table):
    children = {}
    for pid, ppid, name in table:
        if pid != ppid:
            children.setdefault(ppid, []).append((pid, name))
    found, queue, seen = [], [root], {root}
    while queue:
        for pid, name in children.get(queue.pop(0), []):
            if pid in seen:
                continue
            seen.add(pid)
            if name.lower() in AGENTS:
                # A launcher shim (Scoop's codex.exe) runs the real agent under
                # the same name; the child has the agent's own folder.
                while True:
                    same = [c for c, n in children.get(pid, []) if n.lower() == name.lower()]
                    if len(same) != 1:
                        break
                    pid = same[0]
                found.append({"pid": pid, "name": name.lower()[:-4]})  # AGENTS all end in .exe
            else:  # an agent's own helpers are not separate agents
                queue.append(pid)
    return found[0] if len(found) == 1 else None


def main():
    if sys.platform != "win32":
        return 1
    agent = agent_under(int(sys.argv[1]), processes())
    if not agent:
        return 1
    agent.update(process_details(agent["pid"]))
    print(json.dumps(agent))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError):
        sys.exit(1)

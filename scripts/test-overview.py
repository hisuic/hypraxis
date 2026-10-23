#!/usr/bin/env python3
"""Exercise the real plugin in a child Hyprland; never control the parent session."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
PROBE = r"""
import os, sys, termios, tty
color, label, log = sys.argv[1:]
print('\x1b[48;2;' + color + 'm\x1b[2J\x1b[H\x1b[97m\n  ' + label +
      '\n\n  Hypraxis isolated overview test\n', end='', flush=True)
tty.setraw(sys.stdin.fileno())
with open(log, 'ab', buffering=0) as output:
    while True:
        output.write(os.read(sys.stdin.fileno(), 1024))
"""


class Session:
    def __init__(self, plugin, output):
        self.plugin = plugin.resolve(strict=True)
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.processes = []
        self.files = []
        self.instance = None
        self.compositor = None
        self.child_env = None
        self.steps = []

    def run(self, command, *, child=False, timeout=15):
        result = subprocess.run(command, env=self.child_env if child else None,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"{command[0]} failed: {result.stderr or result.stdout}")
        return result.stdout.strip()

    def ctl(self, *args):
        assert self.instance, "A child instance must be selected explicitly"
        assert self.compositor.poll() is None, "Child compositor exited"
        return self.run(["hyprctl", "-i", self.instance, *args])

    def data(self, command):
        return json.loads(self.ctl("-j", command))

    def evaluate(self, code):
        result = self.ctl("eval", code)
        if result != "ok":
            raise RuntimeError(f"Lua assertion failed: {result}\n{code}")

    def wait(self, predicate, description, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.compositor and self.compositor.poll() is not None:
                raise RuntimeError("Child compositor exited; inspect compositor.log")
            if predicate():
                return
            time.sleep(0.05)
        raise RuntimeError("Timed out: " + description)

    def status(self):
        code = """local n=hl.plugin.hypraxis_overview; if not n or not n.status then print('unloaded')
else local s=n.status(); print(table.concat({tostring(s.active),tostring(s.closing),
tostring(s.capturing),tostring(s.origin),tostring(s.id),tostring(s.x),tostring(s.y),
tostring(s.previews)},',')) end"""
        result = self.ctl("repl", code)
        if result == "unloaded":
            return None
        values = result.split(",")
        if len(values) != 8:
            raise RuntimeError("Unexpected overview status: " + result)
        keys = ("active", "closing", "capturing", "origin", "id", "x", "y", "previews")
        return {key: value == "true" if key in keys[:3] else int(value)
                for key, value in zip(keys, values)}

    def mark(self, description):
        self.steps.append(description)
        print("PASS: " + description, flush=True)
        (self.output / "results.json").write_text(json.dumps(self.steps, indent=2) + "\n")

    def spawn(self, command, name, *, child=False):
        log = (self.output / (name + ".log")).open("wb")
        self.files.append(log)
        process = subprocess.Popen(command, env=self.child_env if child else self.launch_env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append(process)
        return process

    def start(self):
        config = self.output / "config"
        config.mkdir(exist_ok=True)
        # Rebuilding the source module must never truncate a loaded ELF file.
        binary = self.plugin.read_bytes()
        digest = hashlib.sha256(binary).hexdigest()
        immutable = self.output / ("plugin-" + digest + ".so")
        if not immutable.exists():
            immutable.write_bytes(binary)
        shutil.copy2(ROOT / "tests/overview-session.lua", config / "hyprland.lua")
        shutil.copy2(ROOT / "hypraxis.lua", config / "hypraxis.lua")
        for name, target in (("hypraxis", ROOT / "hypraxis"),
                             ("hypraxis_overview.so", immutable)):
            link = config / name
            if link.is_symlink():
                link.unlink()
            elif link.exists():
                raise RuntimeError(f"Refusing to overwrite {link}")
            link.symlink_to(target)
        self.launch_env = os.environ.copy()
        self.launch_env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self.launch_env.update(HYPRLAND_NO_SD_VARS="1", HYPRLAND_NO_SD_NOTIFY="1",
                               HYPRLAND_NO_CRASHREPORTER="1")
        self.compositor = self.spawn(["Hyprland", "--config", str(config / "hyprland.lua")],
                                     "compositor")

        def discover():
            instances = json.loads(self.run(["hyprctl", "-j", "instances"]))
            child = next((entry for entry in instances
                          if entry.get("pid") == self.compositor.pid), None)
            if not child or not child.get("wl_socket"):
                return False
            self.instance = child["instance"]
            self.child_env = self.launch_env.copy()
            self.child_env["WAYLAND_DISPLAY"] = child["wl_socket"]
            return True

        self.wait(discover, "child compositor socket", 20)
        (self.output / "session.json").write_text(json.dumps({
            "pid": self.compositor.pid, "instance": self.instance,
            "socket": self.child_env["WAYLAND_DISPLAY"], "plugin_sha256": digest}, indent=2) + "\n")
        errors = self.ctl("configerrors")
        if errors:
            raise RuntimeError("Test configuration errors: " + errors)
        self.evaluate("assert(hl.plugin.hypraxis_overview, 'native plugin did not load')")
        self.mark("isolated child compositor loaded the native plugin")

    def active_id(self):
        return self.data("activeworkspace")["id"]

    def focus(self, workspace):
        self.evaluate("assert(hl.dispatch(hl.dsp.focus({workspace=" +
                      repr(str(workspace)) + ",on_current_monitor=true})).ok)")
        self.wait(lambda: self.active_id() == workspace, "focus test workspace")

    def keys(self, *names):
        command = ["wtype"]
        for name in names:
            command.extend(["-k", name])
        self.run(command, child=True)

    def open(self):
        self.run(["wtype", "-M", "logo", "-k", "space", "-m", "logo"], child=True)
        self.wait(lambda: (self.status() or {}).get("active"), "Super+Space opens overview")
        self.wait(lambda: (self.status() or {}).get("previews", 0) >= 4,
                  "workspace preview captures")

    def closed(self):
        def complete():
            status = self.status()
            return status is None or not (status["active"] or status["closing"])

        self.wait(complete, "overview close animation")
        status = self.status()
        if status:
            assert not status["closing"] and status["previews"] == 0, status

    def capture(self, name):
        self.run(["grim", str(self.output / (name + ".png"))], child=True)
        assert (self.output / (name + ".png")).stat().st_size > 1000

    def clients(self):
        return {client["address"]: {key: client[key] for key in
                ("at", "size", "workspace", "floating", "fullscreen", "pinned")}
                for client in self.data("clients")}

    def unchanged(self, baseline):
        current = self.clients()
        if current != baseline:
            (self.output / "clients-before.json").write_text(json.dumps(baseline, indent=2) + "\n")
            (self.output / "clients-after.json").write_text(json.dumps(current, indent=2) + "\n")
            raise AssertionError("Window state changed; inspect clients-before.json and clients-after.json")

    def test(self):
        for workspace, color in ((12, "34;91;121"), (2, "80;62;124"),
                                 (22, "38;112;83"), (11, "127;70;50"), (3, "93;96;42")):
            self.focus(workspace)
            title = f"Hypraxis test {workspace}"
            (self.output / f"input-{workspace}.bin").write_bytes(b"")
            self.spawn(["foot", "-c", "/dev/null", "-T", title, "-a", "hypraxis-test",
                        "python3", "-u", "-c", PROBE, color, title,
                        str(self.output / f"input-{workspace}.bin")], f"client-{workspace}", child=True)
            self.wait(lambda: any(c["title"] == title for c in self.data("clients")),
                      "map " + title)
        self.focus(12)
        time.sleep(0.2)
        baseline = self.clients()
        self.capture("desktop")
        self.open()
        self.capture("overview")
        assert self.active_id() == 12
        self.mark("Super+Space captures the five-card overview without switching workspaces")

        for key, expected in (("h", 11), ("j", 21), ("l", 12), ("k", 2), ("l", 3)):
            self.keys(key)
            self.wait(lambda: self.status()["id"] == expected, "keyboard selection " + key)
            assert self.active_id() == 12
        self.capture("selected")
        self.keys("Return")
        self.wait(lambda: self.active_id() == 3, "Enter commits selection")
        self.closed()
        self.unchanged(baseline)
        self.mark("HJKL previews preserve the origin; Enter commits exactly once")

        self.open()
        self.keys("j")
        self.wait(lambda: self.status()["id"] == 13, "vertical selection")
        self.keys("Escape")
        self.closed()
        assert self.active_id() == 3, "Escape changed the active workspace"
        self.unchanged(baseline)
        self.mark("Escape cancels without moving windows or changing the active workspace")

        self.focus(12)
        self.open()
        self.keys(*(["h", "j", "l", "k"] * 16))
        assert self.active_id() == 12
        self.capture("rapid")
        self.keys("Escape")
        self.closed()
        self.unchanged(baseline)
        self.mark("rapid repeated keyboard movement releases all preview resources on close")

        self.open()
        self.ctl("reload", "config-only")
        self.closed()
        assert self.active_id() == 12, "Reload changed the active workspace"
        self.unchanged(baseline)
        self.open()
        self.keys("Escape")
        self.closed()
        self.mark("configuration reload cancels the overlay and allows a fresh session")

        self.open()
        # Use the exact path by which the test configuration loaded this module.
        result = self.ctl("plugin", "unload", str(self.output / "config/hypraxis_overview.so"))
        if result != "ok":
            raise RuntimeError("Plugin unload failed: " + result)
        self.wait(lambda: self.status() is None, "plugin namespace removed")
        assert self.active_id() == 12, "Unload changed the active workspace"
        self.unchanged(baseline)
        self.evaluate("assert(not require('hypraxis').overview.is_open())")
        self.mark("unloading an open overview removes callbacks and keeps the child compositor alive")

        for logfile in self.output.glob("input-*.bin"):
            assert logfile.stat().st_size == 0, "Overview keyboard input reached a client: " + logfile.name
        self.mark("overview keyboard input never reached application clients")

    def cleanup(self):
        if self.instance and self.compositor.poll() is None:
            try:
                (self.output / "rolling.log").write_text(self.ctl("rollinglog"))
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
        for process in reversed(self.processes):
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=3)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
        for file in self.files:
            file.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", type=Path, default=ROOT / ".local/build/hypraxis_overview.so")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/overview-test")
    args = parser.parse_args()
    for executable in ("Hyprland", "hyprctl", "grim", "foot", "wtype", "python3"):
        if not shutil.which(executable):
            parser.error("Missing test dependency: " + executable)
    if not os.environ.get("WAYLAND_DISPLAY") or not os.environ.get("XDG_RUNTIME_DIR"):
        parser.error("Run from a Wayland session so the child compositor can use the nested backend")
    session = Session(args.plugin, args.output)
    try:
        session.start()
        session.test()
    finally:
        session.cleanup()
        print("Test artifacts: " + str(session.output), flush=True)


if __name__ == "__main__":
    main()

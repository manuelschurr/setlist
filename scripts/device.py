#!/usr/bin/env python3
"""Drive the Android test phone over adb: screenshots, UI dumps, taps by visible text.

Set SETLIST_DEVICE=host:port to the phone's adb address (for example after `adb tcpip 5555`).
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = "/opt/android-sdk/platform-tools/adb"
PACKAGE = "de.schurr.setlist"


def serial():
    if not os.environ.get("SETLIST_DEVICE"):
        sys.exit("set SETLIST_DEVICE=host:port to the phone's adb address")
    return os.environ["SETLIST_DEVICE"]


def adb(*args, capture=True, binary=False):
    out = subprocess.run([ADB, "-s", serial(), *args], capture_output=capture, check=True)
    return out.stdout if binary else out.stdout.decode(errors="replace")


def nodes():
    # uiautomator refuses to dump while anything animates (a running countdown), so retry briefly.
    for _ in range(8):
        xml = adb("exec-out", "uiautomator", "dump", "/dev/tty")
        if "<?xml" in xml:
            break
        time.sleep(0.7)
    else:
        sys.exit("uiautomator could not dump the screen (something keeps animating); use coordinates")
    xml = xml[xml.index("<?xml"): xml.rindex(">") + 1]
    for node in ET.fromstring(xml).iter("node"):
        label = node.get("text") or node.get("content-desc") or ""
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
        yield label, (x1 + x2) // 2, (y1 + y2) // 2, node


def find(label, index=0):
    matches = [(x, y) for text, x, y, _ in nodes() if text == label or (label.endswith("*") and text.startswith(label[:-1]))]
    if len(matches) <= index:
        sys.exit(f"no element labelled {label!r}")
    return matches[index]


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "connect":
        print(subprocess.run([ADB, "connect", serial()], capture_output=True, text=True).stdout.strip())
    elif cmd == "shot":
        with open(args[0], "wb") as f:
            f.write(adb("exec-out", "screencap", "-p", binary=True))
    elif cmd == "ui":
        for text, x, y, node in nodes():
            if text:
                flags = "".join(k[0] for k in ("clickable", "checked", "selected") if node.get(k) == "true")
                print(f"{x:5} {y:5} {flags:3} {text!r}")
    elif cmd == "tap":
        x, y = (int(args[0]), int(args[1])) if args[0].isdigit() else find(args[0], int(args[1]) if len(args) > 1 else 0)
        adb("shell", "input", "tap", str(x), str(y))
    elif cmd == "longpress":
        x, y = find(args[0])
        adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "800")
    elif cmd == "drag":
        x1, y1 = find(args[0])
        dy = int(args[1])
        adb("shell", "input", "draganddrop", str(x1), str(y1), str(x1), str(y1 + dy), "1500")
    elif cmd == "swipe":
        adb("shell", "input", "swipe", *args)
    elif cmd == "type":
        adb("shell", "input", "text", args[0].replace(" ", "%s"))
    elif cmd == "key":
        adb("shell", "input", "keyevent", args[0])
    elif cmd == "install":
        print(adb("install", "-r", args[0]).strip())
    elif cmd == "launch":
        adb("shell", "am", "start", "-n", f"{args[0] if args else PACKAGE}/.MainActivity")
    elif cmd == "stop":
        adb("shell", "am", "force-stop", args[0] if args else PACKAGE)
    elif cmd == "wait":
        time.sleep(float(args[0]))
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()

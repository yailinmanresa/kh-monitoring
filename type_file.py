"""Types a whole file into another window (for the lab DC in TightVNC).

Usage:  python type_file.py monitor.py
Then click inside the empty Notepad on the DC within 10 seconds.
Emergency stop: move the mouse to the top-left corner of the screen.
"""
import sys
import time

import pyautogui

if len(sys.argv) != 2:
    print("Usage: python type_file.py <file>")
    sys.exit(1)

with open(sys.argv[1], encoding="utf-8") as file:
    text = file.read()

print("=" * 60)
print(f"Typing {sys.argv[1]} ({len(text)} characters).")
print("CLICK INSIDE THE EMPTY NOTEPAD ON THE DC NOW (10 seconds)...")
print("=" * 60)
for i in range(10, 0, -1):
    print(f"{i}...")
    time.sleep(1)

print("Typing... hands off the mouse and keyboard.")
lines = text.splitlines()
for index, line in enumerate(lines):
    if line:
        pyautogui.write(line, interval=0.01)
    if index < len(lines) - 1:
        pyautogui.press("enter")
        time.sleep(0.05)

print("Done! Now save it on the DC: File > Save as > C:\\kh-monitoring > All files > " + sys.argv[1])

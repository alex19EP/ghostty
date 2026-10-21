"""Write N lines at R lines/second, like a build log. Usage: pacer.py N R"""
import sys
import time

n, rate = int(sys.argv[1]), float(sys.argv[2])
start = time.monotonic()
for i in range(n):
    sys.stdout.write(f"[{i:5d}/{n}] CC src/terminal/module_{i % 97:02d}.o -O2 -Wall done\n")
    sys.stdout.flush()
    delay = start + (i + 1) / rate - time.monotonic()
    if delay > 0:
        time.sleep(delay)

"""Draw pacman's parallel download progress bars, without downloading.

Usage: pacman_sim.py NPKGS PARALLEL MIB_PER_S [SEED [LARGE]]

LARGE packages of 0.5-1.5 GiB are mixed in among the NPKGS, like a kernel
firmware or LibreOffice upgrade, so some bars keep moving for a long time.

Reproduces the escape sequences of pacman 7.1's multibar UI
(src/pacman/callback.c): one bar per active download, redrawn in place
at most every 200 ms each, plus a "Total" bar below them. The cursor
jumps between bars with CSI n F / CSI n E, so many lines change between
two rendered frames.
"""
import os
import random
import sys
import time

UPDATE_SPEED_MS = 200
TICK_S = 0.01  # how often libcurl reports progress, roughly

npkgs, parallel, mib_s = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
large = int(sys.argv[5]) if len(sys.argv) > 5 else 0
cols = os.get_terminal_size(sys.stdout.fileno()).columns
out = sys.stdout


def now_ms():
    return int(time.monotonic() * 1000)


STEMS = ["linux", "linux-headers", "linux-firmware-nvidia", "mesa", "lib32-mesa",
         "vulkan-radeon", "gtk4", "glib2", "systemd", "systemd-libs", "python",
         "python-gobject", "orca", "at-spi2-core", "speech-dispatcher", "brltty",
         "firefox", "thunderbird", "libreoffice-fresh", "qt6-base", "qt6-webengine",
         "llvm-libs", "clang", "gcc", "gcc-libs", "glibc", "zig", "rust", "go",
         "ffmpeg", "gstreamer", "pipewire", "wireplumber", "mutter", "gnome-shell"]


def package_name(i):
    stem = STEMS[i % len(STEMS)] + ("" if i < len(STEMS) else f"-extra{i // len(STEMS)}")
    return f"{stem}-{rng.randint(1, 30)}.{rng.randint(0, 20)}.{rng.randint(0, 9)}-1-x86_64.pkg.tar.zst"


def humanize(n):
    labels = ["B", "KiB", "MiB", "GiB", "TiB"]
    val = float(n)
    for label in labels[:-1]:
        if -2048.0 <= val <= 2048.0:
            return val, label
        val /= 1024.0
    return val, labels[-1]


def clean(name):
    for ext in (".pkg", ".db", ".files"):
        p = name.find(ext)
        if p >= 0:
            return name[:p]
    return name


class Bar:
    def __init__(self, filename, total_size=0, howmany=0):
        self.filename = filename
        self.total_size = total_size
        self.howmany = howmany
        self.downloaded = 0
        self.xfered = 0
        self.sync_xfered = 0
        self.sync_time = 0
        self.init_time = now_ms()
        self.rate = 0.0
        self.eta = 0
        self.completed = False


def fill_progress(percent, proglen):
    hashlen = proglen - 8 if proglen > 8 else 0
    hashes = percent * hashlen // 100
    if hashlen > 0:
        out.write(" [" + "#" * hashes + "-" * (hashlen - hashes) + "]")
    if proglen >= 5:
        out.write(f" {percent:3d}%")
    out.write("\r")


def draw(bar):
    percent = bar.sync_xfered * 100 // bar.total_size if bar.total_size else 100
    eta_s = int(bar.eta)
    eta_h, eta_s = divmod(eta_s, 3600)
    eta_m, eta_s = divmod(eta_s, 60)
    fname = clean(bar.filename)
    if bar.howmany > 0:
        digits = len(str(bar.howmany))
        fname = f"{fname} ({bar.downloaded:{digits}d}/{bar.howmany:{digits}d})"
    infolen = max(cols * 6 // 10, 50)
    filenamelen = infolen - 30
    padwid = filenamelen - len(fname)
    if padwid < 0:
        fname = fname[:filenamelen - 3] + "..."
        padwid = 0
    rate_h, rate_l = humanize(bar.rate)
    xfer_h, xfer_l = humanize(bar.sync_xfered)
    out.write(f" {fname}{'':<{padwid}} ")
    if rate_h < 9.995:
        out.write(f"{xfer_h:6.1f} {xfer_l:>3s}  {rate_h:4.2f} {rate_l:>3s}/s ")
    elif rate_h < 99.95:
        out.write(f"{xfer_h:6.1f} {xfer_l:>3s}  {rate_h:4.1f} {rate_l:>3s}/s ")
    else:
        out.write(f"{xfer_h:6.1f} {xfer_l:>3s}  {rate_h:4.0f} {rate_l:>3s}/s ")
    if eta_h == 0:
        out.write(f"{eta_m:02d}:{eta_s:02d}")
    elif eta_h == 1 and eta_m < 40:
        out.write(f"{eta_m + 60:02d}:{eta_s:02d}")
    else:
        out.write("--:--")
    fill_progress(percent, cols - infolen)


def update_stats(bar):
    t = now_ms()
    dt = t - bar.sync_time
    if dt < UPDATE_SPEED_MS:
        return False
    chunk = bar.xfered - bar.sync_xfered
    bar.sync_xfered = bar.xfered
    bar.sync_time = t
    bar.rate = (chunk * 1000 / dt + 2 * bar.rate) / 3
    bar.eta = (bar.total_size - bar.sync_xfered) / bar.rate if bar.rate > 0 else 2**32 - 1
    return True


def finalstats(bar):
    bar.xfered = bar.sync_xfered = bar.total_size
    dt = max(now_ms() - bar.init_time, 1)
    bar.rate = bar.total_size * 1000 / dt
    bar.eta = (dt + 500) // 1000


active = []
cursor_lineno = 0


def goto_bar(n):
    global cursor_lineno
    if n > cursor_lineno:
        out.write(f"\x1b[{n - cursor_lineno}E")
    elif n < cursor_lineno:
        out.write(f"\x1b[{cursor_lineno - n}F")
    cursor_lineno = n


def move_end():
    goto_bar(len(active))


# Package sizes: mostly small, a few large, like a real -Syu.
sizes = [int(min(max(rng.lognormvariate(14.0, 1.6), 20_000), 400 * 2**20)) for _ in range(npkgs)]
for i in rng.sample(range(npkgs), min(large, npkgs)):
    sizes[i] = rng.randint(512, 1536) * 2**20
names = [package_name(i) for i in range(npkgs)]
total = Bar("Total", sum(sizes), npkgs)
pending = list(range(npkgs))
sizes_by_bar = {}

out.write("\x1b[?25l:: Retrieving packages...\n")
out.flush()


def init_download():
    global cursor_lineno
    i = pending.pop(0)
    bar = Bar(names[i])
    sizes_by_bar[id(bar)] = sizes[i]
    # pacman moves to the end before counting the new download.
    move_end()
    active.append(bar)
    # The new bar's line goes below the old ones, then Total is redrawn.
    out.write(f" {clean(bar.filename)}\n")
    cursor_lineno += 1
    draw(total)
    out.write("\n")
    cursor_lineno += 1


def complete(bar):
    global cursor_lineno
    total.downloaded += 1
    bar.completed = True
    bar.total_size = sizes_by_bar[id(bar)]
    finalstats(bar)
    index = active.index(bar)
    if index != 0:
        # move_completed_up: swap with the top bar.
        top = active[0]
        active[0], active[index] = bar, top
        goto_bar(index)
        draw(top)
        index = 0
    goto_bar(index)
    draw(bar)
    out.flush()
    while active and active[0].completed:
        active.pop(0)
        cursor_lineno -= 1


while pending and len(active) < parallel:
    init_download()
out.flush()

last = time.monotonic()
while active:
    time.sleep(TICK_S)
    t = time.monotonic()
    dt, last = t - last, t
    # The running downloads share the bandwidth.
    per_download = mib_s * 2**20 / max(1, sum(not b.completed for b in active))
    for bar in list(active):
        if bar.completed:
            continue
        size = sizes_by_bar[id(bar)]
        new = min(size, bar.xfered + int(per_download * dt * rng.uniform(0.5, 1.5)))
        chunk = new - bar.xfered
        bar.xfered = new
        bar.total_size = size
        if new >= size:
            total.xfered += chunk
            complete(bar)
            continue
        if update_stats(bar):
            goto_bar(active.index(bar))
            draw(bar)
        total.xfered += chunk
        if update_stats(total):
            move_end()
            draw(total)
        out.flush()
    while pending and sum(not b.completed for b in active) < parallel:
        init_download()
        out.flush()

move_end()
finalstats(total)
draw(total)
out.write("\n\x1b[?25h")
out.flush()

//! This benchmark tests the performance of building the accessibility
//! text snapshot of a viewport (`a11y.text.build`).
//!
//! This matters because the GTK apprt walks the viewport on every
//! rendered frame while an AT client (Orca) is attached, and it does so
//! while holding `renderer_state.mutex`, so like `ScreenClone` this is
//! a lock holder that directly impacts IO throughput.
//!
//! `probe` measures a snapshot and comparison. The other modes measure
//! the work of a changed snapshot, with optional OSC 8 and regex links.
//!
//! Hyperlink GObject construction and AT-SPI traffic require a live GTK
//! app and bus and are outside the scope of this benchmark.
const A11yText = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const terminalpkg = @import("../terminal/main.zig");
const a11y = @import("../a11y/main.zig");
const urlpkg = @import("../config/url.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const log = std.log.scoped(.@"a11y-text-bench");

opts: Options,
alloc: Allocator,
terminal: Terminal,
/// Retained buffers for the current and previous viewport snapshots.
scratch: a11y.text.Snapshot = .{},
previous: a11y.text.Snapshot = .{},
/// The ranges the rebuild modes collect, mirroring the surface's links
/// and style runs.
sink: Sink,
/// Compiled link patterns. Only the regex modes have any.
links: []LinkConfig,
/// Regex matches per row, mirroring `regex_links` on the surface.
regex_links: a11y.text.RegexLinkCache = .{},

pub const Options = struct {
    /// The type of snapshot work to perform.
    mode: Mode = .text,

    /// Multiplier on the number of iterations each step runs. This is
    /// useful to make a benchmark run long enough for profiling.
    loops: u32 = 1,

    /// The size of the terminal. The snapshot walk is proportional to
    /// the viewport cell count, so this is the primary scaling knob.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// The data to read as a filepath. If this is "-" then we will read
    /// stdin. If this is unset, we synthesize a viewport containing
    /// styled text, wide characters, OSC 8 hyperlinks and bare URLs so
    /// that every mode has something to find. The time to read this is
    /// not part of the benchmark.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Baseline: iterate the same viewport rows without building
    /// anything. Isolates iteration overhead from the snapshot work.
    noop,

    /// Build a snapshot and compare it with the previous one.
    probe,

    /// Build a snapshot and collect text styles.
    text,

    /// Collect both text styles and OSC 8 links.
    links,

    /// `links`, then the configured link regexes over the built text,
    /// with every row's matches thrown away first. This is a changed frame
    /// on a current GTK with a default config in which every row changed.
    regex,

    /// `regex` with the per-row match cache kept from the previous
    /// iteration, so no row changed and no pattern runs: the floor a
    /// frame pays when only a few rows did.
    regex_cached,
};

/// A stand-in for `Surface`'s derived link config.
/// `RegexLinkCache.apply` only requires a `regex` field.
const LinkConfig = struct {
    regex: oni.Regex,
};

/// Collects the ranges the walk discovers. The GTK sink additionally
/// dups each URI and constructs a hyperlink GObject; this keeps the URI
/// borrowed so it measures the walk rather than GObject churn.
const Sink = struct {
    alloc: Allocator,
    links: std.ArrayList(Link) = .empty,
    style_runs: std.ArrayList(StyleRun) = .empty,

    const Link = struct {
        start_cp: usize,
        end_cp: usize,
        uri: []const u8,
    };

    const StyleRun = struct {
        start_cp: usize,
        end_cp: usize,
        style: terminalpkg.Style,
    };

    fn deinit(self: *Sink) void {
        self.links.deinit(self.alloc);
        self.style_runs.deinit(self.alloc);
    }

    fn reset(self: *Sink) void {
        self.links.clearRetainingCapacity();
        self.style_runs.clearRetainingCapacity();
    }

    pub fn commitLink(self: *Sink, start_cp: usize, end_cp: usize, uri: []const u8) void {
        if (start_cp >= end_cp) return;
        self.links.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
            .uri = uri,
        }) catch {};
    }

    pub fn commitStyleRun(
        self: *Sink,
        start_cp: usize,
        end_cp: usize,
        style: terminalpkg.Style,
    ) void {
        self.style_runs.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
            .style = style,
        }) catch {};
    }

    pub fn committedLinkCount(self: *Sink) usize {
        return self.links.items.len;
    }

    pub fn linkOverlaps(self: *Sink, start_cp: usize, end_cp: usize, limit: usize) bool {
        const n = @min(limit, self.links.items.len);
        for (self.links.items[0..n]) |existing| {
            if (start_cp < existing.end_cp and
                end_cp > existing.start_cp) return true;
        }
        return false;
    }
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*A11yText {
    const ptr = try alloc.create(A11yText);
    errdefer alloc.destroy(ptr);

    // Only the regex modes need compiled patterns. `global.init` has
    // already initialized oniguruma by the time we get here.
    const links: []LinkConfig = links: {
        if (opts.mode != .regex and opts.mode != .regex_cached) break :links &.{};
        const buf = try alloc.alloc(LinkConfig, 1);
        errdefer alloc.free(buf);
        buf[0] = .{ .regex = try oni.Regex.init(
            urlpkg.regex,
            .{},
            oni.Encoding.utf8,
            oni.Syntax.default,
            null,
        ) };
        break :links buf;
    };
    errdefer if (links.len > 0) {
        for (links) |*link| link.regex.deinit();
        alloc.free(links);
    };

    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
        .sink = .{ .alloc = alloc },
        .links = links,
    };

    return ptr;
}

pub fn destroy(self: *A11yText, alloc: Allocator) void {
    self.regex_links.deinit(alloc);
    for (self.links) |*link| link.regex.deinit();
    if (self.links.len > 0) alloc.free(self.links);
    self.sink.deinit();
    self.scratch.deinit(alloc);
    self.previous.deinit(alloc);
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *A11yText) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .probe => stepProbe,
            .text => stepText,
            .links => stepLinks,
            .regex => stepRegex,
            .regex_cached => stepRegexCached,
        },
        .setupFn = setup,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    // Always reset our terminal state
    self.terminal.fullReset();

    const data_f: ?std.Io.File = options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };

    if (data_f) |f| {
        defer f.close(global.io());

        var stream = self.terminal.vtStream();
        defer stream.deinit();

        var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var f_reader = f.reader(global.io(), &read_buf);
        const r = &f_reader.interface;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&buf) catch {
                log.warn("error reading data file err={?}", .{f_reader.err});
                return error.BenchmarkFailed;
            };
            if (n == 0) break; // EOF reached
            stream.nextSlice(buf[0..n]);
        }
    } else {
        // No data file: synthesize a viewport that exercises every branch
        // of the walk: a styled run, double-width cells, an OSC 8
        // hyperlink, a bare URL for the regex pass, an interior blank gap
        // and trailing blanks.
        var s = self.terminal.vtStream();
        defer s.deinit();
        for (0..self.terminal.rows) |i| {
            if (i > 0) s.nextSlice("\r\n");
            s.nextSlice("\x1b[38;2;200;100;50mstyled\x1b[0m plain ");
            s.nextSlice("日本語 wide   gap ");
            s.nextSlice("\x1b]8;;https://example.com/anchor\x1b\\osc8 link\x1b]8;;\x1b\\");
            s.nextSlice(" see https://ghostty.org/docs");
        }
    }

    // Reference snapshot for `probe` mode, built out here so the timed
    // loop measures only the probe itself.
    a11y.text.build(
        self.alloc,
        &self.previous,
        self.terminal.screens.active,
    ) catch |err| {
        log.warn("error building probe snapshot err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Iterations per step. The walk is proportional to the viewport cell
/// count, so this is far lower than the cheap per-call benchmarks.
fn iterations(self: *const A11yText) u64 {
    return 100 * @as(u64, self.opts.loops);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        const screen: *terminalpkg.Screen = self.terminal.screens.active;
        const pages = &screen.pages;
        const tl_pin = pages.getTopLeft(.viewport);
        var row_it = tl_pin.rowIterator(.right_down, null);
        var row_idx: usize = 0;
        while (row_idx < pages.rows) : (row_idx += 1) {
            const pin = row_it.next() orelse continue;
            const cells = pin.cells(.all);
            std.mem.doNotOptimizeAway(cells.len);
        }
    }
}

/// Measures the snapshot work for a frame whose text did not change.
fn stepProbe(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        try self.buildSnapshot();
        std.mem.doNotOptimizeAway(self.scratch.eql(&self.previous));
    }
}

fn stepText(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, false, .none);
}

fn stepLinks(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, true, .none);
}

fn stepRegex(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, true, .cold);
}

fn stepRegexCached(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, true, .warm);
}

/// Whether a rebuild runs the link regexes, and with what cached.
const RegexPass = enum {
    none,
    /// No row's matches known: every row changed.
    cold,
    /// The previous iteration's matches kept: no row changed.
    warm,
};

fn buildSnapshot(self: *A11yText) Benchmark.Error!void {
    a11y.text.build(
        self.alloc,
        &self.scratch,
        self.terminal.screens.active,
    ) catch |err| {
        log.warn("error building a11y text err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Measures a changed frame, including its ranges and optional regex pass.
fn stepBuild(
    ptr: *anyopaque,
    comptime track_links: bool,
    comptime regex_pass: RegexPass,
) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        self.sink.reset();
        try self.buildSnapshot();
        a11y.text.collectRanges(&self.scratch, &self.sink, track_links);

        switch (regex_pass) {
            .none => {},
            .cold, .warm => {
                if (regex_pass == .cold) self.regex_links.deinit(self.alloc);
                self.regex_links.apply(
                    self.alloc,
                    self.scratch.text.items,
                    self.links,
                    &self.sink,
                );
            },
        }

        std.mem.doNotOptimizeAway(self.scratch.text.items.len);
        std.mem.doNotOptimizeAway(self.scratch.widths.items.len);
        std.mem.doNotOptimizeAway(self.sink.links.items.len);
        std.mem.doNotOptimizeAway(self.sink.style_runs.items.len);
    }
}

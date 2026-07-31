//! This benchmark tests the performance of building the accessibility
//! text snapshot of a viewport (`apprt.a11y_text.build`).
//!
//! This matters because the GTK apprt rebuilds this snapshot on every
//! rendered frame while an AT client (Orca) is attached, and it does so
//! while holding `renderer_state.mutex` — so like `ScreenClone`, this is
//! a lock holder that directly impacts IO throughput. The `regex` mode in
//! particular runs every configured link pattern over the entire viewport
//! text, still under that lock.
//!
//! What this does NOT measure: constructing the `GtkAccessibleHyperlink`
//! GObjects that the real sink creates per link, or the AT-SPI D-Bus
//! traffic that follows. Those need a live GTK app and bus, so the
//! numbers here are a floor on the real per-frame cost, not the whole of
//! it.
const A11yText = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const terminalpkg = @import("../terminal/main.zig");
const a11y_text = @import("../apprt/a11y_text.zig");
const urlpkg = @import("../config/url.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const log = std.log.scoped(.@"a11y-text-bench");

opts: Options,
terminal: Terminal,
sink: Sink,
links: []LinkConfig,
/// Retained scratch + reference snapshot for `probe` mode, mirroring
/// `ax_probe_buf` and `ax_last_snapshot` on the GTK surface.
probe_buf: std.ArrayList(u8) = .empty,
probe_snapshot: std.ArrayList(u8) = .empty,

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
    /// styled text, OSC 8 hyperlinks, and bare URLs so that the link
    /// modes have something to find. The time to read this is not part
    /// of the benchmark.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Baseline: iterate the same viewport rows without building
    /// anything. Isolates iteration overhead from the snapshot work.
    noop,

    /// The per-frame change probe: text into a retained scratch buffer
    /// with a null sink, then a memcmp against the previous snapshot. No
    /// allocation, no link lookups, no style runs, no regex. This is what
    /// an *unchanged* frame costs once the change gate is in place, and
    /// it is the number that matters most — most frames don't change.
    probe,

    /// Build the text buffer and style runs, no link tracking. This is
    /// what runs on GTK older than 4.22, where the Hypertext interface
    /// isn't available.
    text,

    /// Build with OSC 8 link tracking enabled during the cell walk.
    links,

    /// Build with link tracking, then run the configured link regexes
    /// over the resulting buffer. This is the full per-frame cost on a
    /// current GTK with a default config.
    regex,
};

/// A stand-in for `Surface`'s derived link config. `matchRegexLinks`
/// only requires a `regex` field.
const LinkConfig = struct {
    regex: oni.Regex,
};

/// Collects the ranges the walk discovers. The GTK sink additionally
/// dups each URI and constructs a hyperlink GObject; we deliberately
/// keep the URI slice borrowed so this measures the walk rather than
/// GObject churn (see the file doc comment).
const Sink = struct {
    alloc: Allocator,
    links: std.ArrayList(Link) = .empty,
    style_runs: std.ArrayList(StyleRun) = .empty,

    const Link = struct {
        start_cp: c_uint,
        end_cp: c_uint,
        uri: []const u8,
    };

    const StyleRun = struct {
        start_cp: c_uint,
        end_cp: c_uint,
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

    pub fn commitLink(
        self: *Sink,
        start_cp: c_uint,
        end_cp: c_uint,
        uri: []const u8,
    ) void {
        if (start_cp >= end_cp) return;
        self.links.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
            .uri = uri,
        }) catch {};
    }

    pub fn commitStyleRun(
        self: *Sink,
        start_cp: c_uint,
        end_cp: c_uint,
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

    pub fn linkOverlaps(
        self: *Sink,
        start_cp: c_uint,
        end_cp: c_uint,
        limit: usize,
    ) bool {
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

    // Only the regex mode needs compiled patterns. `global.init` has
    // already initialized oniguruma by the time we get here.
    const links: []LinkConfig = links: {
        if (opts.mode != .regex) break :links &.{};
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
    errdefer if (links.len > 0) alloc.free(links);

    ptr.* = .{
        .opts = opts,
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
    for (self.links) |*link| link.regex.deinit();
    if (self.links.len > 0) alloc.free(self.links);
    self.probe_buf.deinit(alloc);
    self.probe_snapshot.deinit(alloc);
    self.sink.deinit();
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
        },
        .setupFn = setup,
        .teardownFn = teardown,
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
        // of the walk — a styled run, an OSC 8 hyperlink, a bare URL for
        // the regex pass, and trailing blanks.
        var s = self.terminal.vtStream();
        defer s.deinit();
        for (0..self.terminal.rows) |i| {
            if (i > 0) s.nextSlice("\r\n");
            s.nextSlice("\x1b[38;2;200;100;50mstyled\x1b[0m plain ");
            s.nextSlice("\x1b]8;;https://example.com/anchor\x1b\\osc8 link\x1b]8;;\x1b\\");
            s.nextSlice(" see https://ghostty.org/docs for more");
        }
    }

    // Reference snapshot for `probe` mode, built out here so the timed
    // loop measures only the probe itself.
    const alloc = self.sink.alloc;
    self.probe_snapshot.clearRetainingCapacity();
    var null_sink: a11y_text.NullSink = .{};
    _ = a11y_text.build(
        alloc,
        &self.probe_snapshot,
        self.terminal.screens.active,
        &null_sink,
        .{ .track_links = false },
    ) catch |err| {
        log.warn("error building probe snapshot err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));
    _ = self;
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

/// Models `axProbeChanged`: retained scratch buffer, text only, null
/// sink, then the memcmp against the last notified snapshot. This is the
/// gate that lets an unchanged frame skip the rebuild entirely.
fn stepProbe(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));
    const alloc = self.sink.alloc;

    for (0..iterations(self)) |_| {
        self.probe_buf.clearRetainingCapacity();

        var null_sink: a11y_text.NullSink = .{};
        const result = a11y_text.build(
            alloc,
            &self.probe_buf,
            self.terminal.screens.active,
            &null_sink,
            .{ .track_links = false },
        ) catch |err| {
            log.warn("error probing a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };

        const changed = !std.mem.eql(
            u8,
            self.probe_snapshot.items,
            self.probe_buf.items,
        );

        std.mem.doNotOptimizeAway(changed);
        std.mem.doNotOptimizeAway(result.cp_count);
    }
}

fn stepText(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, false, false);
}

fn stepLinks(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, true, false);
}

fn stepRegex(ptr: *anyopaque) Benchmark.Error!void {
    return stepBuild(ptr, true, true);
}

/// Mirrors what `axRefreshCache` does per rendered frame: a fresh buffer,
/// the viewport walk, the optional regex pass, and the final NUL-
/// terminated dup that gets cached. The allocation churn is intentional
/// — the real path pays it on every frame.
fn stepBuild(
    ptr: *anyopaque,
    comptime track_links: bool,
    comptime match_regex: bool,
) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));
    const alloc = self.sink.alloc;

    for (0..iterations(self)) |_| {
        self.sink.reset();

        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(alloc);

        const result = a11y_text.build(
            alloc,
            &buffer,
            self.terminal.screens.active,
            &self.sink,
            .{ .track_links = track_links },
        ) catch |err| {
            log.warn("error building a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };

        if (match_regex) a11y_text.matchRegexLinks(
            buffer.items,
            self.links,
            &self.sink,
        );

        const text = alloc.dupeZ(u8, buffer.items) catch |err| {
            log.warn("error duplicating a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };
        defer alloc.free(text);

        std.mem.doNotOptimizeAway(result.cp_count);
        std.mem.doNotOptimizeAway(text.len);
        std.mem.doNotOptimizeAway(self.sink.links.items.len);
        std.mem.doNotOptimizeAway(self.sink.style_runs.items.len);
    }
}

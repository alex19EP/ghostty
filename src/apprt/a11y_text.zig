//! Builds the flat UTF-8 text snapshot of a terminal viewport that
//! accessibility clients (AT-SPI on Linux) read.
//!
//! This lives outside of any single apprt implementation so the viewport
//! walk can be unit tested and benchmarked without standing up a live GTK
//! surface and an AT-SPI bus. `src/benchmark/A11yText.zig` drives it
//! directly; `apprt/gtk/class/surface.zig` drives it under the renderer
//! mutex on every rendered frame while an AT client is attached.
//!
//! IMPORTANT: every offset produced here that is destined for an AT client
//! is in UTF-8 *codepoints*, not bytes. `Result.cursor_byte` is the one
//! exception and is explicitly named as such; convert it with
//! `a11y_offsets.utf8CpCount` before handing it out. `a11y_offsets` is the
//! companion module that navigates the snapshot this one builds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const terminal_hyperlink = @import("../terminal/hyperlink.zig");
const offsets = @import("a11y_offsets.zig");

// Offsets handed to AT clients are in codepoints; `a11y_offsets` owns
// that arithmetic and the tests for it.
const utf8CpLen = offsets.utf8CpLen;

const log = std.log.scoped(.a11y_text);

pub const Options = struct {
    /// Whether to collect link ranges during the walk. Callers skip this
    /// when the runtime can't expose hyperlinks at all (e.g. GTK older
    /// than 4.22, where the Hypertext interface isn't registered), so we
    /// don't pay for hyperlink lookups nothing will read.
    track_links: bool = true,
};

pub const Result = struct {
    /// Byte offset into the built buffer where the caret sits, or null if
    /// the cursor row wasn't part of the viewport. Callers anchor a null
    /// at end-of-text.
    cursor_byte: ?c_uint,

    /// Total codepoints appended to the buffer by this walk.
    cp_count: c_uint,
};

/// The sink receives the link and style ranges discovered during the walk.
/// It is taken as `anytype` so the GTK apprt can commit straight into its
/// `GtkAccessibleHyperlink` reuse machinery while the benchmark collects
/// into plain lists. Required methods:
///
///   fn commitLink(self, start_cp: c_uint, end_cp: c_uint, uri: []const u8) void
///   fn commitStyleRun(self, start_cp: c_uint, end_cp: c_uint, style: terminal.Style) void
///   fn committedLinkCount(self) usize
///   fn linkOverlaps(self, start_cp: c_uint, end_cp: c_uint, limit: usize) bool
///
/// `uri` passed to `commitLink` is borrowed from page memory and is only
/// valid for the duration of the call — the sink must copy it if it wants
/// to keep it. Sinks are expected to swallow their own allocation
/// failures: a dropped link degrades to "announced as plain text", which
/// is strictly better than failing the whole snapshot.
///
/// `linkOverlaps` only considers the first `limit` committed links, which
/// lets `matchRegexLinks` dedup against the OSC 8 ranges from the cell
/// walk without also matching against regex hits from its own pass.
///
/// A sink that discards everything. Use with `track_links = false` when
/// you only want the text — e.g. the per-frame change probe, which needs
/// to know whether the viewport text moved without paying for link
/// lookups, style runs, or hyperlink objects.
pub const NullSink = struct {
    pub fn commitLink(_: *NullSink, _: c_uint, _: c_uint, _: []const u8) void {}
    pub fn commitStyleRun(_: *NullSink, _: c_uint, _: c_uint, _: terminal.Style) void {}
    pub fn committedLinkCount(_: *NullSink) usize {
        return 0;
    }
    pub fn linkOverlaps(_: *NullSink, _: c_uint, _: c_uint, _: usize) bool {
        return false;
    }
};

/// Walk the viewport of `screen`, appending its text to `buffer`.
///
/// The caller must hold the renderer mutex for the duration of this call:
/// we read live page memory, and `uri` slices handed to the sink point
/// directly into it.
pub fn build(
    alloc: Allocator,
    buffer: *std.ArrayList(u8),
    screen: *terminal.Screen,
    sink: anytype,
    opts: Options,
) Allocator.Error!Result {
    const pages = &screen.pages;
    const viewport_rows: usize = pages.rows;

    const cursor = screen.cursor;
    var cursor_offset: ?c_uint = null;

    // Codepoint counter tracked alongside `buffer.items.len`. Used to
    // report AT-SPI-compliant codepoint offsets for links and style runs.
    // Separate from the byte `cursor_offset` above, which is converted
    // once by the caller.
    var cp_count: c_uint = 0;

    const track_links = opts.track_links;

    // Currently-open run inside a single row. Closed and committed at the
    // end of the row, on link-id transition, or on an interrupting blank
    // cell. `uri` is a slice borrowed from `page.memory`.
    var cur_link: ?struct {
        id: terminal_hyperlink.Id,
        start_cp: c_uint,
        uri: []const u8,
    } = null;

    // Currently-open non-default style run. Closed and committed at any
    // boundary where the next emitted codepoint's style differs (different
    // styled cell, blank-cell gap, `\n`, EOF). Coalesces identical adjacent
    // cells into a single run — a viewport of mostly-default text collapses
    // to zero runs and a fully-styled viewport collapses to roughly one run
    // per contiguous SGR region per row (typical case: tens per viewport,
    // not per cell).
    const OpenRun = struct {
        start_cp: c_uint,
        style: terminal.Style,
    };
    var cur_style: ?OpenRun = null;
    const closeStyle = struct {
        fn f(
            sink_inner: anytype,
            cur: *?OpenRun,
            end_cp: c_uint,
        ) void {
            const cs = cur.* orelse return;
            if (end_cp > cs.start_cp) {
                sink_inner.commitStyleRun(cs.start_cp, end_cp, cs.style);
            }
            cur.* = null;
        }
    }.f;

    const tl_pin = pages.getTopLeft(.viewport);
    var row_it = tl_pin.rowIterator(.right_down, null);
    var row_idx: usize = 0;
    while (row_idx < viewport_rows) : (row_idx += 1) {
        if (row_idx > 0) {
            // `\n` is a default-styled gap — close any open run before
            // advancing `cp_count` past it.
            closeStyle(sink, &cur_style, cp_count);
            try buffer.append(alloc, '\n');
            cp_count += 1;
        }

        const pin = row_it.next() orelse continue;
        const is_cursor_row = row_idx == cursor.y;
        const row_start: c_uint = @intCast(buffer.items.len);
        if (is_cursor_row) cursor_offset = row_start;

        const cells = pin.cells(.all);
        const page = pin.node.page();

        // Accumulate empty cells so runs of trailing empties drop off the
        // end of the row, but intermediate gaps still get emitted as
        // spaces to preserve column positions. This matches what
        // `ScreenFormatter` does for non-trailing blanks.
        var blank_cells: usize = 0;
        // Pending cursor position when the cursor lands on a blank cell:
        // index into the current blank run where the cursor sits. Resolved
        // to an absolute buffer offset either when the blanks flush (=
        // `buffer.items.len + idx`, inside the about-to-be-emitted space
        // run) or at end-of-row when the blanks get eaten as trailing (=
        // `buffer.items.len`, i.e. end of emitted text).
        var cursor_blank_idx: ?usize = null;
        for (0..cells.len) |col| {
            const cell = &cells[col];

            // Record cursor byte position before writing the cell at
            // cursor.x, so the offset points AT that cell. For blank cells
            // we defer: capture the blank-run index and resolve on flush
            // or end-of-row.
            if (is_cursor_row and col == cursor.x) {
                if (cell.hasText()) {
                    cursor_offset = @intCast(buffer.items.len);
                } else {
                    cursor_blank_idx = blank_cells;
                }
            }

            switch (cell.wide) {
                .spacer_tail, .spacer_head => continue,
                .narrow, .wide => {},
            }

            if (!cell.hasText()) {
                blank_cells += 1;
                // A blank interrupts any open link run — the same OSC 8
                // escape can bridge whitespace visually, but splitting
                // runs on blanks gives Orca a cleaner per-word
                // announcement and matches how a sighted user perceives
                // the link region.
                if (track_links) if (cur_link) |cl| {
                    sink.commitLink(cl.start_cp, cp_count, cl.uri);
                    cur_link = null;
                };
                continue;
            }

            // Flush accumulated blanks as spaces. Each space is one
            // codepoint and carries the default style; close any open
            // styled run before the gap.
            if (blank_cells > 0) {
                closeStyle(sink, &cur_style, cp_count);
                // Resolve a cursor that landed inside this blank run to
                // its column within the about-to-be-emitted spaces.
                if (cursor_blank_idx) |idx| {
                    cursor_offset = @intCast(buffer.items.len + idx);
                    cursor_blank_idx = null;
                }
                try buffer.appendNTimes(alloc, ' ', blank_cells);
                cp_count += @intCast(blank_cells);
                blank_cells = 0;
            }

            // Resolve this cell's style from its page. Cells that took the
            // `!hasText()` branch above are never seen here, so content_tag
            // is codepoint / codepoint_grapheme; `hasStyling()` is the
            // default_id gate (0 → default).
            const cell_style: terminal.Style = if (cell.hasStyling())
                page.styles.get(page.memory, cell.style_id).*
            else
                .{};

            // Transition the style run: continue if identical to the open
            // run, otherwise close and (if non-default) open a new one at
            // the current cp_count.
            const cell_default = cell_style.default();
            if (cur_style) |cs| {
                if (!cs.style.eql(cell_style)) {
                    closeStyle(sink, &cur_style, cp_count);
                    if (!cell_default) cur_style = .{
                        .start_cp = cp_count,
                        .style = cell_style,
                    };
                }
            } else if (!cell_default) {
                cur_style = .{
                    .start_cp = cp_count,
                    .style = cell_style,
                };
            }

            // Determine the link on this cell BEFORE writing, so a new
            // run's start_cp matches where this cell's codepoints land in
            // the buffer.
            var cell_link: ?struct {
                id: terminal_hyperlink.Id,
                uri: []const u8,
            } = null;
            if (track_links and cell.hyperlink) {
                if (page.lookupHyperlink(cell)) |lid| {
                    const entry = page.hyperlink_set.get(page.memory, lid);
                    cell_link = .{
                        .id = lid,
                        .uri = entry.uri.slice(page.memory),
                    };
                }
            }

            // Transition: close current run if the link changed or ended.
            // Link ids are unique only within a page, but rows don't
            // straddle pages and we also close on row boundaries, so
            // same-id across cells within a row is a valid continuity
            // check.
            if (cur_link) |cl| {
                const continues = if (cell_link) |nl| nl.id == cl.id else false;
                if (!continues) {
                    sink.commitLink(cl.start_cp, cp_count, cl.uri);
                    cur_link = null;
                }
            }
            if (cur_link == null) {
                if (cell_link) |nl| cur_link = .{
                    .id = nl.id,
                    .start_cp = cp_count,
                    .uri = nl.uri,
                };
            }

            var ubuf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint(), &ubuf) catch {
                try buffer.append(alloc, '?');
                cp_count += 1;
                continue;
            };
            try buffer.appendSlice(alloc, ubuf[0..n]);
            cp_count += 1;

            if (cell.hasGrapheme()) {
                if (pin.grapheme(cell)) |graphemes| {
                    for (graphemes) |cp| {
                        const gn = std.unicode.utf8Encode(cp, &ubuf) catch continue;
                        try buffer.appendSlice(alloc, ubuf[0..gn]);
                        cp_count += 1;
                    }
                }
            }
        }

        // If cursor.x is past the last column we emitted (trailing blanks,
        // or cursor beyond row end), anchor to end-of-row.
        if (is_cursor_row and cursor.x >= cells.len) {
            cursor_offset = @intCast(buffer.items.len);
        }

        // Cursor landed inside a blank run that never flushed — those cells
        // are trailing and got eaten. Anchor to the end of emitted text on
        // this row.
        if (cursor_blank_idx != null) {
            cursor_offset = @intCast(buffer.items.len);
            cursor_blank_idx = null;
        }

        // End of row: close any open link. Links don't span '\n' in the
        // accessibility view — each visual line becomes its own navigable
        // Hyperlink.
        if (track_links) if (cur_link) |cl| {
            sink.commitLink(cl.start_cp, cp_count, cl.uri);
            cur_link = null;
        };
    }

    // Close any style run still open at end-of-viewport.
    closeStyle(sink, &cur_style, cp_count);

    return .{
        .cursor_byte = cursor_offset,
        .cp_count = cp_count,
    };
}

/// Scan already-built viewport `text` for configured regex links (bare
/// URLs, user-configured patterns) and commit each non-overlapping hit to
/// `sink`.
///
/// Run this after `build` so the OSC 8 ranges from the cell walk are
/// already committed and we can dedup overlapping regex matches against
/// them: when a regex match overlaps an OSC 8 link, the OSC 8 link wins
/// (its URI is explicit and authoritative; the regex is a guess).
///
/// Blind users can't "hover" to reveal a link, so every configured pattern
/// is matched regardless of its `highlight` mode — the highlight gate
/// (`hover`, `always_mods`, etc.) exists for visual cue purposes on
/// sighted flows, not for whether a region is semantically a link.
///
/// `link_cfgs` is any slice whose elements expose a `regex` field with
/// oniguruma's `search` interface; it's `anytype` so callers can pass their
/// own derived-config type without making it public. The caller must keep
/// those regex objects alive for the duration of this call — for the GTK
/// apprt that means holding the renderer mutex, since the config they live
/// in is swapped under it.
pub fn matchRegexLinks(
    text: []const u8,
    link_cfgs: anytype,
    sink: anytype,
) void {
    if (text.len == 0) return;
    if (link_cfgs.len == 0) return;

    // Snapshot the OSC 8 range set before emitting any regex hits, so we
    // only check new regex matches against OSC 8 links — not against
    // earlier regex matches from the same refresh. If two configured
    // regexes both fire on the same span, both land; Orca's
    // `_adjust_for_links` merely announces "link" per hit, which is no
    // worse than a duplicated OSC 8 scenario.
    const osc8_end = sink.committedLinkCount();

    for (link_cfgs) |*link_cfg| {
        // Incrementally track byte → codepoint position through `text` so
        // regex offset conversion is O(n) across all matches for this
        // regex, not O(k·n). Resets per configured regex (byte_offset
        // rewinds).
        var scan_byte: usize = 0;
        var scan_cp: c_uint = 0;

        var byte_offset: usize = 0;
        while (byte_offset < text.len) {
            var region = link_cfg.regex.search(
                text[byte_offset..],
                .{},
            ) catch |err| switch (err) {
                error.Mismatch => break,
                else => {
                    log.warn(
                        "ax regex search failed: {}",
                        .{err},
                    );
                    break;
                },
            };
            defer region.deinit();

            const rel_start: usize = @intCast(region.starts()[0]);
            const rel_end: usize = @intCast(region.ends()[0]);
            const abs_start = byte_offset + rel_start;
            const abs_end = byte_offset + rel_end;

            // Guard against zero-width matches looping forever (`a*` etc).
            byte_offset = if (abs_end > byte_offset)
                abs_end
            else
                byte_offset + 1;

            if (abs_end <= abs_start) continue;

            // URL regex shouldn't match newlines, but if a user-supplied
            // regex crosses one we clip to the first '\n' so the hyperlink
            // stays on a single visual row — matches the per-row splitting
            // we apply to OSC 8 runs during the cell walk.
            var clipped_end = abs_end;
            for (text[abs_start..abs_end], 0..) |b, i| {
                if (b == '\n') {
                    clipped_end = abs_start + i;
                    break;
                }
            }
            if (clipped_end <= abs_start) continue;

            // Advance the cp cursor to abs_start, recording cp_start, then
            // to clipped_end for cp_end. Since regex matches within one
            // config are in byte order, `scan_byte` is monotonic.
            while (scan_byte < abs_start) {
                scan_cp += 1;
                scan_byte += utf8CpLen(text[scan_byte]);
            }
            const cp_start = scan_cp;
            while (scan_byte < clipped_end) {
                scan_cp += 1;
                scan_byte += utf8CpLen(text[scan_byte]);
            }
            const cp_end = scan_cp;

            if (sink.linkOverlaps(cp_start, cp_end, osc8_end)) continue;

            sink.commitLink(
                cp_start,
                cp_end,
                text[abs_start..clipped_end],
            );
        }
    }
}

const testing = std.testing;

/// Collects committed ranges so tests can assert on them. Mirrors the
/// contract the GTK surface implements.
const TestSink = struct {
    alloc: Allocator,
    links: std.ArrayList(Link) = .empty,
    style_runs: std.ArrayList(Range) = .empty,

    const Link = struct {
        start_cp: c_uint,
        end_cp: c_uint,
        uri: []const u8,
    };

    const Range = struct {
        start_cp: c_uint,
        end_cp: c_uint,
    };

    fn deinit(self: *TestSink) void {
        for (self.links.items) |l| self.alloc.free(l.uri);
        self.links.deinit(self.alloc);
        self.style_runs.deinit(self.alloc);
    }

    pub fn commitLink(
        self: *TestSink,
        start_cp: c_uint,
        end_cp: c_uint,
        uri: []const u8,
    ) void {
        if (start_cp >= end_cp) return;
        const owned = self.alloc.dupe(u8, uri) catch return;
        self.links.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
            .uri = owned,
        }) catch {};
    }

    pub fn commitStyleRun(
        self: *TestSink,
        start_cp: c_uint,
        end_cp: c_uint,
        style: terminal.Style,
    ) void {
        _ = style;
        self.style_runs.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
        }) catch {};
    }

    pub fn committedLinkCount(self: *TestSink) usize {
        return self.links.items.len;
    }

    pub fn linkOverlaps(
        self: *TestSink,
        start_cp: c_uint,
        end_cp: c_uint,
        limit: usize,
    ) bool {
        const n = @min(limit, self.links.items.len);
        for (self.links.items[0..n]) |e| {
            if (start_cp < e.end_cp and end_cp > e.start_cp) return true;
        }
        return false;
    }
};

test "a11y text: rows joined by newline, trailing blanks trimmed" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hello");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("world");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    const result = try build(alloc, &buffer, t.screens.active, &sink, .{});

    // Row 2 is empty, so it contributes its leading '\n' and nothing else.
    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
    try testing.expectEqual(@as(c_uint, 12), result.cp_count);
}

test "a11y text: intermediate blanks preserved as spaces" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{});
    try testing.expectEqualStrings("ab   cd", buffer.items);
}

test "a11y text: cursor anchors past trailing blanks" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("hi");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("abc");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    const result = try build(alloc, &buffer, t.screens.active, &sink, .{});

    // "hi\nabc" — the cursor sits on the blank after "abc", which is
    // trailing, so it anchors at end-of-text.
    try testing.expectEqualStrings("hi\nabc", buffer.items);
    try testing.expectEqual(@as(c_uint, 6), result.cursor_byte.?);
}

test "a11y text: OSC 8 link offsets are codepoints, not bytes" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);

    // A multi-byte prefix makes byte and codepoint offsets diverge: "→→"
    // is 2 codepoints but 6 bytes. If the walk ever reports bytes, the
    // start offset below reads 6 instead of 2.
    try t.printString("→→");
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("link");
    t.screens.active.endHyperlink();

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("→→link", buffer.items);
    try testing.expectEqual(@as(usize, 1), sink.links.items.len);
    const link = sink.links.items[0];
    try testing.expectEqual(@as(c_uint, 2), link.start_cp);
    try testing.expectEqual(@as(c_uint, 6), link.end_cp);
    try testing.expectEqualStrings("https://example.com", link.uri);
}

test "a11y text: track_links=false skips link collection" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("link");
    t.screens.active.endHyperlink();

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{ .track_links = false });

    try testing.expectEqualStrings("link", buffer.items);
    try testing.expectEqual(@as(usize, 0), sink.links.items.len);
}

test "a11y text: links close at row boundaries" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 4, .rows = 2 });
    defer t.deinit(alloc);

    // Soft-wraps across both rows; each visual row must become its own
    // link so AT clients get one navigable range per line.
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("abcdefgh");
    t.screens.active.endHyperlink();

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("abcd\nefgh", buffer.items);
    try testing.expectEqual(@as(usize, 2), sink.links.items.len);
    try testing.expectEqual(@as(c_uint, 0), sink.links.items[0].start_cp);
    try testing.expectEqual(@as(c_uint, 4), sink.links.items[0].end_cp);
    try testing.expectEqual(@as(c_uint, 5), sink.links.items[1].start_cp);
    try testing.expectEqual(@as(c_uint, 9), sink.links.items[1].end_cp);
}

test "a11y text: style runs coalesce and close at gaps" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);

    t.screens.active.cursor.style = .{ .flags = .{ .bold = true } };
    try t.screens.active.manualStyleUpdate();
    try t.printString("bold");
    t.screens.active.cursor.style = .{};
    try t.screens.active.manualStyleUpdate();
    try t.printString(" plain");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("bold plain", buffer.items);
    // The four bold cells collapse into one run; the plain tail emits none.
    try testing.expectEqual(@as(usize, 1), sink.style_runs.items.len);
    try testing.expectEqual(@as(c_uint, 0), sink.style_runs.items[0].start_cp);
    try testing.expectEqual(@as(c_uint, 4), sink.style_runs.items[0].end_cp);
}

test "a11y text: NullSink probe yields the same text as a full build" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    t.screens.active.cursor.style = .{ .flags = .{ .bold = true } };
    try t.screens.active.manualStyleUpdate();
    try t.printString("styled");
    t.screens.active.cursor.style = .{};
    try t.screens.active.manualStyleUpdate();
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("link");
    t.screens.active.endHyperlink();

    // The per-frame change probe drops links and style runs to stay cheap.
    // It is only a valid gate if the text it produces is byte-identical to
    // what the real rebuild would produce.
    var full_sink: TestSink = .{ .alloc = alloc };
    defer full_sink.deinit();
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    const full_result = try build(alloc, &full, t.screens.active, &full_sink, .{});

    var null_sink: NullSink = .{};
    var probe: std.ArrayList(u8) = .empty;
    defer probe.deinit(alloc);
    const probe_result = try build(
        alloc,
        &probe,
        t.screens.active,
        &null_sink,
        .{ .track_links = false },
    );

    try testing.expectEqualStrings(full.items, probe.items);
    try testing.expectEqual(full_result.cp_count, probe_result.cp_count);
    try testing.expectEqual(full_result.cursor_byte, probe_result.cursor_byte);

    // Sanity: the full build really did find the things the probe skips,
    // so this isn't comparing two empty runs.
    try testing.expectEqual(@as(usize, 1), full_sink.links.items.len);
    try testing.expectEqual(@as(usize, 1), full_sink.style_runs.items.len);
}

test "a11y text: regex links dedup against OSC 8 ranges" {
    const oni = @import("oniguruma");
    const url = @import("../config/url.zig");

    try oni.testing.ensureInit();

    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 60, .rows = 1 });
    defer t.deinit(alloc);

    // The OSC 8 anchor text is itself a bare URL, so the regex pass would
    // re-report it if dedup were broken.
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("https://example.com");
    t.screens.active.endHyperlink();
    try t.printString(" https://ghostty.org");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);

    _ = try build(alloc, &buffer, t.screens.active, &sink, .{});
    try testing.expectEqual(@as(usize, 1), sink.links.items.len);

    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();
    // Must be `var`: oniguruma's `search` takes a mutable `*Regex`, which
    // is also why the real caller holds a mutable slice of link configs.
    var cfgs = [_]struct { regex: oni.Regex }{.{ .regex = re }};

    matchRegexLinks(buffer.items, &cfgs, &sink);

    // The OSC 8 range survives; only the trailing bare URL is added.
    try testing.expectEqual(@as(usize, 2), sink.links.items.len);
    try testing.expectEqual(@as(c_uint, 20), sink.links.items[1].start_cp);
    try testing.expectEqualStrings("https://ghostty.org", sink.links.items[1].uri);
}

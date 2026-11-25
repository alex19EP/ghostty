//! The text of a terminal viewport as accessibility clients read it:
//! one line per row, with the width of each character and the caret.
//! The text comes from the plain-text formatter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const terminal_hyperlink = @import("../terminal/hyperlink.zig");
const formatter = terminal.formatter;
const unicode = @import("../unicode/main.zig");
const offsets = @import("offsets.zig");

const log = std.log.scoped(.a11y_text);

/// One viewport snapshot. `build` reuses its buffers.
pub const Snapshot = struct {
    /// One line per viewport row.
    text: std.ArrayList(u8) = .empty,

    /// Columns covered by each codepoint of `text`; see
    /// `offsets.CellWidths`. A newline covers 0.
    widths: std.ArrayList(u8) = .empty,

    /// The caret, as a codepoint offset. The end of the text when the
    /// cursor is outside the viewport.
    caret: offsets.CodepointOffset = 0,

    /// Kept only to reuse its memory.
    pin_map: formatter.PinMap.Map = .empty,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.widths.deinit(alloc);
        self.pin_map.deinit(alloc);
        self.* = undefined;
    }

    pub fn cellWidths(self: *const Snapshot) offsets.CellWidths {
        return .{ .per_cp = self.widths.items };
    }

    /// Compares the text, geometry and caret.
    pub fn eql(self: *const Snapshot, other: *const Snapshot) bool {
        return self.caret == other.caret and
            std.mem.eql(u8, self.text.items, other.text.items) and
            std.mem.eql(u8, self.widths.items, other.widths.items);
    }
};

/// Build the snapshot of the viewport of `screen` into `snap`,
/// replacing what it held.
pub fn build(
    alloc: Allocator,
    snap: *Snapshot,
    screen: *const terminal.Screen,
) Allocator.Error!void {
    snap.text.clearRetainingCapacity();
    snap.widths.clearRetainingCapacity();
    snap.pin_map.clearRetainingCapacity();
    snap.caret = 0;

    const pages = &screen.pages;
    const viewport_rows: usize = pages.rows;

    {
        // Keep spaces printed at the end of a row, such as the one after
        // a prompt, so that typing a space changes the text. Empty cells
        // are still dropped.
        var f: formatter.PageListFormatter = .init(pages, .{
            .emit = .plain,
            .trim = false,
        });
        f.top_left = pages.getTopLeft(.viewport);
        f.bottom_right = pages.getBottomRight(.viewport);
        f.pin_map = .{ .alloc = alloc, .map = &snap.pin_map };

        var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &snap.text);
        defer snap.text = aw.toArrayList();
        f.format(&aw.writer) catch return error.OutOfMemory;
    }

    // The formatter drops blank rows at the bottom. Add them back so that
    // line N of the text is row N of the viewport.
    const newlines = std.mem.countScalar(u8, snap.text.items, '\n');
    if (newlines + 1 < viewport_rows) {
        try snap.text.appendNTimes(alloc, '\n', viewport_rows - 1 - newlines);
    }

    try recordWidths(alloc, snap);
    snap.caret = caretOffset(snap, screen);
}

/// Fill `snap.widths` from the cells the formatter mapped each byte to.
fn recordWidths(alloc: Allocator, snap: *Snapshot) Allocator.Error!void {
    const text = snap.text.items;
    const map = &snap.pin_map;

    try snap.widths.ensureTotalCapacity(alloc, text.len);

    // Later codepoints of a grapheme map to the same cell as the first
    // one, and cover no columns.
    var prev: ?terminal.Pin = null;

    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        defer i += len;

        if (text[i] == '\n') {
            snap.widths.appendAssumeCapacity(0);
            prev = null;
            continue;
        }

        const pin = map.get(i) orelse {
            snap.widths.appendAssumeCapacity(1);
            prev = null;
            continue;
        };

        if (prev) |p| if (p.eql(pin)) {
            snap.widths.appendAssumeCapacity(0);
            continue;
        };
        prev = pin;

        // The formatter skips the spacer cell after a wide character.
        const wide = pin.rowAndCell().cell.wide == .wide;
        snap.widths.appendAssumeCapacity(if (wide) 2 else 1);
    }
}

/// The codepoint under the cursor. Past the end of its row, the end of
/// that row.
fn caretOffset(snap: *const Snapshot, screen: *const terminal.Screen) offsets.CodepointOffset {
    const text = snap.text.items;
    const widths = snap.widths.items;
    const cp_count = widths.len;

    const pin = if (screen.caret_mode)
        (screen.caret_pin orelse return cp_count).*
    else
        screen.cursor.page_pin.*;
    const pt = screen.pages.pointFromPin(.viewport, pin) orelse return cp_count;
    const cursor = pt.coord();
    if (cursor.y >= screen.pages.rows) return cp_count;

    var cp: usize = 0;
    var byte: usize = 0;
    var row: usize = 0;
    while (row < cursor.y) : (cp += 1) {
        if (byte >= text.len) return cp_count;
        if (text[byte] == '\n') row += 1;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }

    var col: usize = 0;
    while (byte < text.len and text[byte] != '\n') : (cp += 1) {
        const w = widths[cp];
        if (w > 0 and cursor.x < col + w) return cp;
        col += w;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }
    return cp;
}

/// Collect style and OSC 8 ranges from the cells used to build this
/// snapshot. Use the same codepoint indices as the text and widths.
/// Call before releasing the renderer mutex, since pins refer to live pages.
pub fn collectRanges(snap: *const Snapshot, sink: anytype, track_links: bool) void {
    var style_run: ?StyleRun = null;
    var link_run: ?struct {
        node: formatter.PinMap.Node,
        id: terminal_hyperlink.Id,
        start: offsets.CodepointOffset,
        uri: []const u8,
    } = null;

    var byte: offsets.ByteOffset = 0;
    for (snap.widths.items, 0..) |width, cp| {
        const first = snap.text.items[byte];
        const pin = if (first == '\n') null else snap.pin_map.get(byte);
        byte += unicode.utf8.cpLen(first);
        // Combining marks share the text cell's style and link.
        if (first != '\n' and width == 0) continue;

        const cell = if (pin) |p| p.rowAndCell().cell else null;
        const page = if (pin) |p| p.node.page() else null;
        const style: terminal.Style = if (cell != null and cell.?.hasText() and cell.?.hasStyling())
            page.?.styles.get(page.?.memory, cell.?.style_id).*
        else
            .{};
        const same_style = if (style_run) |run| run.style.eql(style) else style.default();
        if (!same_style) {
            closeStyle(sink, &style_run, cp);
            if (!style.default()) style_run = .{ .start_cp = cp, .style = style };
        }

        if (track_links) {
            const id = if (cell != null and cell.?.hasText() and cell.?.hyperlink)
                page.?.lookupHyperlink(cell.?)
            else
                null;
            if (link_run) |run| {
                if (id == null or id.? != run.id or pin.?.node != run.node) {
                    sink.commitLink(run.start, cp, run.uri);
                    link_run = null;
                }
            }
            if (link_run == null) if (id) |link_id| {
                link_run = .{
                    .node = pin.?.node,
                    .id = link_id,
                    .start = cp,
                    .uri = page.?.hyperlink_set.get(page.?.memory, link_id).uri.slice(page.?.memory),
                };
            };
        }
    }

    const end = snap.widths.items.len;
    closeStyle(sink, &style_run, end);
    if (link_run) |run| sink.commitLink(run.start, end, run.uri);
}

/// A style run that has been opened but not yet committed.
const StyleRun = struct {
    start_cp: usize,
    style: terminal.Style,
};

/// Commit the open style run, if any, as ending at `end_cp`.
fn closeStyle(sink: anytype, cur: *?StyleRun, end_cp: usize) void {
    const run = cur.* orelse return;
    if (end_cp > run.start_cp) sink.commitStyleRun(run.start_cp, end_cp, run.style);
    cur.* = null;
}

/// Configured regex links (bare URLs, user patterns) in already-built
/// viewport text, matched one row at a time and cached by row text, so a
/// refresh only runs the patterns on rows it hasn't seen.
///
/// The cache is what keeps this affordable. The default URL/path regex
/// gets slower than linear in row width on long runs of path characters
/// such as progress bars: a 383x87 viewport of pacman downloads took
/// ~67 ms per rebuild against 0.3 ms for a build log, and with a rebuild
/// on every changed frame that kept the main thread busy and every AT
/// client waiting on it. Keyed by text rather than row index, so output
/// that scrolls still hits.
///
/// Per row and not over the whole viewport because links never span rows
/// here: each visual line is its own range, as with OSC 8. A user pattern
/// that would match across a line break matches each row on its own.
///
/// Every pattern is matched regardless of its `highlight` mode, which
/// depends on a mouse a screen reader user doesn't have. The caller
/// decides when links are worth finding: the GTK surface only looks in
/// caret mode.
pub const RegexLinkCache = struct {
    /// Row text to its matches, from the last `apply`. Keys and values
    /// are owned.
    rows: Rows = .empty,

    /// The patterns `rows` was matched with. A different slice means the
    /// config changed: the new one is built before the old one is freed,
    /// so it can never reuse its address.
    cfgs_ptr: ?*const anyopaque = null,
    cfgs_len: usize = 0,

    const Rows = std.StringHashMapUnmanaged([]const RowMatch);

    /// One hit, relative to the start of its row.
    const RowMatch = struct {
        start_byte: u32,
        end_byte: u32,
        start_cp: u32,
        end_cp: u32,
    };

    pub fn deinit(self: *RegexLinkCache, alloc: Allocator) void {
        freeRows(&self.rows, alloc);
        self.rows.deinit(alloc);
        self.* = .{};
    }

    /// Commit each hit in `text` that doesn't overlap an OSC 8 link to
    /// `sink`. Run this after `collectRanges`, so the OSC 8 ranges are
    /// already committed: when the two overlap the OSC 8 link wins, since
    /// its URI is explicit and the regex is a guess.
    ///
    /// `link_cfgs` is any slice whose elements have a `regex` field with
    /// oniguruma's `search` interface. This does not need the renderer
    /// mutex: it reads only `text` and the regexes, and the caller keeps
    /// those alive. Allocation failure drops links, which degrades to
    /// plain text.
    pub fn apply(
        self: *RegexLinkCache,
        alloc: Allocator,
        text: []const u8,
        link_cfgs: anytype,
        sink: anytype,
    ) void {
        // Through the first element, so a pointer to an array works too.
        const cfgs_ptr: ?*const anyopaque = if (link_cfgs.len > 0) @ptrCast(&link_cfgs[0]) else null;
        if (cfgs_ptr != self.cfgs_ptr or link_cfgs.len != self.cfgs_len) {
            freeRows(&self.rows, alloc);
            self.cfgs_ptr = cfgs_ptr;
            self.cfgs_len = link_cfgs.len;
        }
        if (link_cfgs.len == 0) return;

        // Only dedup against the OSC 8 links. Two configured regexes that
        // both match a span both land, which announces no worse than a
        // duplicated OSC 8 link would.
        const osc8_end = sink.committedLinkCount();

        // Rows seen this time move over from `rows` as they are reached;
        // whatever is left in `rows` afterwards is gone from the viewport.
        var next: Rows = .empty;
        defer {
            freeRows(&self.rows, alloc);
            self.rows.deinit(alloc);
            self.rows = next;
        }

        var scratch: std.ArrayList(RowMatch) = .empty;
        defer scratch.deinit(alloc);

        var row_cp: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |row| {
            // The row and its `\n`. The last row has none, but nothing
            // follows it.
            defer row_cp += unicode.utf8.cpCount(row) + 1;
            if (row.len == 0) continue;

            const matches = self.rowMatches(alloc, &next, row, link_cfgs, &scratch);
            for (matches) |m| {
                const start = row_cp + m.start_cp;
                const end = row_cp + m.end_cp;
                if (sink.linkOverlaps(start, end, osc8_end)) continue;
                sink.commitLink(start, end, row[m.start_byte..m.end_byte]);
            }
        }
    }

    /// `row`'s matches: from this refresh if the row appeared already,
    /// else from the last one, else found now. The result is valid until
    /// the next call.
    fn rowMatches(
        self: *RegexLinkCache,
        alloc: Allocator,
        next: *Rows,
        row: []const u8,
        link_cfgs: anytype,
        scratch: *std.ArrayList(RowMatch),
    ) []const RowMatch {
        if (next.get(row)) |matches| return matches;
        if (self.rows.fetchRemove(row)) |kv| {
            next.putNoClobber(alloc, kv.key, kv.value) catch {
                // Still correct, just uncached: hand back a copy that
                // outlives the entry.
                scratch.clearRetainingCapacity();
                scratch.appendSlice(alloc, kv.value) catch {};
                alloc.free(kv.key);
                alloc.free(kv.value);
                return scratch.items;
            };
            return kv.value;
        }

        scratch.clearRetainingCapacity();
        matchRow(alloc, row, link_cfgs, scratch);
        const key = alloc.dupe(u8, row) catch return scratch.items;
        const value = alloc.dupe(RowMatch, scratch.items) catch {
            alloc.free(key);
            return scratch.items;
        };
        next.putNoClobber(alloc, key, value) catch {
            alloc.free(key);
            alloc.free(value);
            return scratch.items;
        };
        return value;
    }

    /// Run every pattern over one row, appending the hits to `out`.
    fn matchRow(
        alloc: Allocator,
        row: []const u8,
        link_cfgs: anytype,
        out: *std.ArrayList(RowMatch),
    ) void {
        for (link_cfgs) |*link_cfg| {
            // Matches arrive in byte order, so the byte-to-codepoint
            // conversion advances monotonically instead of rescanning
            // from the start for every match.
            var scan_byte: usize = 0;
            var scan_cp: usize = 0;

            var byte_offset: usize = 0;
            while (byte_offset < row.len) {
                var region = link_cfg.regex.search(
                    row[byte_offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => {
                        log.warn("regex link search failed: {}", .{err});
                        break;
                    },
                };
                defer region.deinit();

                const abs_start = byte_offset + @as(usize, @intCast(region.starts()[0]));
                const abs_end = byte_offset + @as(usize, @intCast(region.ends()[0]));

                // Step past a zero-width match, or `a*` loops forever.
                byte_offset = if (abs_end > byte_offset) abs_end else byte_offset + 1;
                if (abs_end <= abs_start) continue;

                while (scan_byte < abs_start) : (scan_cp += 1) {
                    scan_byte += unicode.utf8.cpLen(row[scan_byte]);
                }
                const cp_start = scan_cp;
                while (scan_byte < abs_end) : (scan_cp += 1) {
                    scan_byte += unicode.utf8.cpLen(row[scan_byte]);
                }

                out.append(alloc, .{
                    .start_byte = @intCast(abs_start),
                    .end_byte = @intCast(abs_end),
                    .start_cp = @intCast(cp_start),
                    .end_cp = @intCast(scan_cp),
                }) catch return;
            }
        }
    }

    fn freeRows(rows: *Rows, alloc: Allocator) void {
        var it = rows.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        rows.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn testBuild(t: *terminal.Terminal, snap: *Snapshot) !void {
    try build(testing.allocator, snap, t.screens.active);
    try testing.expectEqual(
        unicode.utf8.cpCount(snap.text.items),
        snap.widths.items.len,
    );
}

test "a11y text: rows joined by newline, trailing blanks trimmed" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hello");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("world");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // Row 3 is blank but still has a line.
    try testing.expectEqualStrings("hello\nworld\n", snap.text.items);
}

test "a11y text: printed trailing spaces are text" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // A prompt, and a space typed after a word at the end of the line.
    try t.printString("$ ls ");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("$ ls ", snap.text.items);
    try testing.expectEqual(5, snap.caret);
}

test "a11y text: every viewport row has a line, even blank ones" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(2, 1);
    try t.printString("mid");
    t.setCursorPos(5, 3);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("\nmid\n\n\n", snap.text.items);
    try testing.expectEqual(snap.widths.items.len, snap.caret);
}

test "a11y text: widths report the columns each codepoint covers" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("wide 日本語 tail");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // The last 0 is the newline before row 2.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
        snap.widths.items,
    );

    // 't' of "tail" is codepoint 9 but column 12.
    const text = snap.text.items;
    const t_byte = std.mem.indexOf(u8, text, "tail").?;
    const cp_idx = unicode.utf8.cpCount(text[0..t_byte]);
    try testing.expectEqual(9, cp_idx);
    try testing.expectEqual(12, offsets.cpToGrid(text, snap.cellWidths(), cp_idx).col);
}

test "a11y text: combining marks cover no columns" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 'e' and a combining acute accent: two codepoints in one cell.
    try t.printString("e\u{0301}x");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("e\u{0301}x", snap.text.items);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 1 }, snap.widths.items);
}

test "a11y text: intermediate blanks preserved as spaces" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab   cd", snap.text.items);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1 }, snap.widths.items);
}

test "a11y text: cursor anchors past trailing blanks" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hi");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("abc");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // The cursor is after "abc": the end of its row, not of the text.
    try testing.expectEqualStrings("hi\nabc\n", snap.text.items);
    try testing.expectEqual(6, snap.caret);
}

test "a11y text: cursor inside an interior blank run lands on its column" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 7);
    try t.printString("cd");
    // On the second of the four spaces.
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab    cd", snap.text.items);
    try testing.expectEqual(3, snap.caret);
}

test "a11y text: cursor on a wide character's spacer lands on the character" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 日 covers columns 2 and 3. The cursor is on column 3.
    try t.printString("ab日cd");
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab日cd", snap.text.items);
    try testing.expectEqual(2, snap.caret);
}

test "a11y text: the caret follows the cursor's row when scrolled back" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // "1" and "2" scroll into history.
    for (0..5) |i| {
        if (i > 0) {
            t.carriageReturn();
            try t.linefeed();
        }
        try t.print('1' + @as(u21, @intCast(i)));
    }

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);

    try testBuild(&t, &snap);
    try testing.expectEqualStrings("3\n4\n5", snap.text.items);
    try testing.expectEqual(5, snap.caret);

    // The cursor's row is now below the viewport. Counting rows from the
    // top of the active area would put the caret after "4".
    t.scrollViewport(.{ .delta = -1 });
    try testBuild(&t, &snap);
    try testing.expectEqualStrings("2\n3\n4", snap.text.items);
    try testing.expectEqual(snap.widths.items.len, snap.caret);
}

test "a11y text: rebuilding into a used snapshot replaces it" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("first");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    t.eraseDisplay(.complete, false);
    t.setCursorPos(1, 1);
    try t.printString("2nd");
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("2nd\n", snap.text.items);
}

test "a11y text: cursor on text after an interior blank run" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");
    // Park the cursor on 'c', right after the never-written gap. That gap
    // is still pending when the walk reaches 'c', so a cursor recorded
    // without it lands at the start of the gap instead.
    t.setCursorPos(1, 6);

    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);

    try testing.expectEqualStrings("ab   cd", buffer.text.items);
    try testing.expectEqual(5, buffer.caret);
}

test "a11y text: caret mode reports the caret, not the terminal cursor" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("first");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("second");

    const screen = t.screens.active;
    try screen.enterCaretMode();
    screen.moveCaret(.up, null);

    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, screen);

    // The terminal cursor is still after "second", but the caret moved up
    // a row. Moving the caret emits no selection change, so the reported
    // caret offset is the only thing that tells a client it moved.
    try testing.expectEqualStrings("first\nsecond", buffer.text.items);
    const caret_pt = screen.pages.pointFromPin(.viewport, screen.caret_pin.?.*).?;
    try testing.expectEqual(0, caret_pt.viewport.y);
    try testing.expectEqual(caret_pt.viewport.x, buffer.caret);
}

/// Collects committed ranges so tests can assert on them, following the
/// contract the GTK surface implements.
const TestSink = struct {
    alloc: std.mem.Allocator,
    links: std.ArrayList(Link) = .empty,
    style_runs: std.ArrayList(Range) = .empty,

    const Link = struct {
        start_cp: usize,
        end_cp: usize,
        uri: []const u8,
    };

    const Range = struct {
        start_cp: usize,
        end_cp: usize,
    };

    fn deinit(self: *TestSink) void {
        for (self.links.items) |l| self.alloc.free(l.uri);
        self.links.deinit(self.alloc);
        self.style_runs.deinit(self.alloc);
    }

    pub fn commitLink(self: *TestSink, start_cp: usize, end_cp: usize, uri: []const u8) void {
        if (start_cp >= end_cp) return;
        const owned = self.alloc.dupe(u8, uri) catch return;
        self.links.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
            .uri = owned,
        }) catch self.alloc.free(owned);
    }

    pub fn commitStyleRun(self: *TestSink, start_cp: usize, end_cp: usize, _: terminal.Style) void {
        self.style_runs.append(self.alloc, .{
            .start_cp = start_cp,
            .end_cp = end_cp,
        }) catch {};
    }

    pub fn committedLinkCount(self: *TestSink) usize {
        return self.links.items.len;
    }

    pub fn linkOverlaps(self: *TestSink, start_cp: usize, end_cp: usize, limit: usize) bool {
        const n = @min(limit, self.links.items.len);
        for (self.links.items[0..n]) |e| {
            if (start_cp < e.end_cp and end_cp > e.start_cp) return true;
        }
        return false;
    }
};

test "a11y text: OSC 8 link offsets are codepoints, not bytes" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);

    // A multi-byte prefix makes byte and codepoint offsets diverge: the
    // two arrows are 2 codepoints but 6 bytes. If the walk ever reports
    // bytes, the start offset below reads 6 instead of 2.
    try t.printString("\u{2192}\u{2192}");
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("link");
    t.screens.active.endHyperlink();

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);
    collectRanges(&buffer, &sink, true);

    try testing.expectEqualStrings("\u{2192}\u{2192}link", buffer.text.items);
    try testing.expectEqual(1, sink.links.items.len);
    const link = sink.links.items[0];
    try testing.expectEqual(2, link.start_cp);
    try testing.expectEqual(6, link.end_cp);
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
    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);
    collectRanges(&buffer, &sink, false);

    try testing.expectEqualStrings("link", buffer.text.items);
    try testing.expectEqual(0, sink.links.items.len);
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
    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);
    collectRanges(&buffer, &sink, true);

    try testing.expectEqualStrings("abcd\nefgh", buffer.text.items);
    try testing.expectEqual(2, sink.links.items.len);
    try testing.expectEqual(0, sink.links.items[0].start_cp);
    try testing.expectEqual(4, sink.links.items[0].end_cp);
    try testing.expectEqual(5, sink.links.items[1].start_cp);
    try testing.expectEqual(9, sink.links.items[1].end_cp);
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
    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);
    collectRanges(&buffer, &sink, true);

    try testing.expectEqualStrings("bold plain", buffer.text.items);
    // The four bold cells collapse into one run; the plain tail emits none.
    try testing.expectEqual(1, sink.style_runs.items.len);
    try testing.expectEqual(0, sink.style_runs.items[0].start_cp);
    try testing.expectEqual(4, sink.style_runs.items[0].end_cp);
}

test "a11y text: collecting ranges does not change the text" {
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

    // The per-frame change probe walks without a sink to stay cheap. Ranges must not change the snapshot.
    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var full: Snapshot = .{};
    defer full.deinit(alloc);
    try build(alloc, &full, t.screens.active);
    collectRanges(&full, &sink, true);

    var probe: Snapshot = .{};
    defer probe.deinit(alloc);
    try build(alloc, &probe, t.screens.active);

    try testing.expectEqualStrings(full.text.items, probe.text.items);
    try testing.expectEqual(full.widths.items.len, probe.widths.items.len);
    try testing.expectEqual(full.caret, probe.caret);

    // The full walk really did find what the probe skips, so this isn't
    // comparing two empty runs.
    try testing.expectEqual(1, sink.links.items.len);
    try testing.expectEqual(1, sink.style_runs.items.len);
}

test "a11y text: regex links dedup against OSC 8 ranges" {
    const oni = @import("oniguruma");
    const url = @import("../config/url.zig");

    try oni.testing.ensureInit();

    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 60, .rows = 1 });
    defer t.deinit(alloc);

    // The OSC 8 anchor text is itself a bare URL, so the regex pass would
    // report it again if dedup were broken.
    try t.screens.active.startHyperlink("https://example.com", null);
    try t.printString("https://example.com");
    t.screens.active.endHyperlink();
    try t.printString(" https://ghostty.org");

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var buffer: Snapshot = .{};
    defer buffer.deinit(alloc);

    try build(alloc, &buffer, t.screens.active);
    collectRanges(&buffer, &sink, true);
    try testing.expectEqual(1, sink.links.items.len);

    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();
    // `var`: oniguruma's `search` takes a mutable `*Regex`.
    var cfgs = [_]struct { regex: oni.Regex }{.{ .regex = re }};

    var cache: RegexLinkCache = .{};
    defer cache.deinit(alloc);
    cache.apply(alloc, buffer.text.items, &cfgs, &sink);

    // The OSC 8 range survives; only the trailing bare URL is added.
    try testing.expectEqual(2, sink.links.items.len);
    try testing.expectEqual(20, sink.links.items[1].start_cp);
    try testing.expectEqualStrings("https://ghostty.org", sink.links.items[1].uri);
}

/// A pattern that finds `needle` and counts how often it is run, standing
/// in for an `oni.Regex` in `RegexLinkCache` tests.
const CountingRegex = struct {
    needle: []const u8,
    searches: usize = 0,

    const Region = struct {
        start: [1]c_int,
        end: [1]c_int,

        fn starts(self: *const Region) []const c_int {
            return &self.start;
        }

        fn ends(self: *const Region) []const c_int {
            return &self.end;
        }

        fn deinit(_: *Region) void {}
    };

    fn search(self: *CountingRegex, s: []const u8, _: anytype) error{ Mismatch, Failed }!Region {
        self.searches += 1;
        const i = std.mem.indexOf(u8, s, self.needle) orelse return error.Mismatch;
        return .{
            .start = .{@intCast(i)},
            .end = .{@intCast(i + self.needle.len)},
        };
    }
};

const CountingCfg = struct { regex: CountingRegex };

/// Run `cache` over `text` into a fresh sink and return the link starts.
fn applyStarts(
    cache: *RegexLinkCache,
    text: []const u8,
    cfgs: []CountingCfg,
    out: []usize,
) !usize {
    var sink: TestSink = .{ .alloc = testing.allocator };
    defer sink.deinit();
    cache.apply(testing.allocator, text, cfgs, &sink);
    for (sink.links.items, 0..) |l, i| {
        try testing.expectEqual(l.start_cp + 4, l.end_cp);
        try testing.expectEqualStrings("link", l.uri);
        out[i] = l.start_cp;
    }
    return sink.links.items.len;
}

test "a11y text: regex links are found per row, in codepoint offsets" {
    const oni = @import("oniguruma");
    const url = @import("../config/url.zig");

    try oni.testing.ensureInit();

    const alloc = testing.allocator;
    var re = try oni.Regex.init(url.regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();
    var cfgs = [_]struct { regex: oni.Regex }{.{ .regex = re }};

    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var cache: RegexLinkCache = .{};
    defer cache.deinit(alloc);

    // "é" is two bytes and "€" three, one codepoint each.
    cache.apply(alloc, "é https://a.org\n€€ https://b.org x", &cfgs, &sink);

    try testing.expectEqual(2, sink.links.items.len);
    try testing.expectEqual(2, sink.links.items[0].start_cp);
    try testing.expectEqual(15, sink.links.items[0].end_cp);
    try testing.expectEqualStrings("https://a.org", sink.links.items[0].uri);
    // Row 1 starts after 15 codepoints and the `\n`.
    try testing.expectEqual(16 + 3, sink.links.items[1].start_cp);
    try testing.expectEqualStrings("https://b.org", sink.links.items[1].uri);
}

test "a11y text: regex links only rerun on rows that changed" {
    var cfgs = [_]CountingCfg{.{ .regex = .{ .needle = "link" } }};
    var cache: RegexLinkCache = .{};
    defer cache.deinit(testing.allocator);
    var starts: [4]usize = undefined;

    // Every row ends in its hit, so each row searched is one search.
    try testing.expectEqual(2, try applyStarts(&cache, "a link\nb link", &cfgs, &starts));
    try testing.expectEqual(2, cfgs[0].regex.searches);
    try testing.expectEqualSlices(usize, &.{ 2, 9 }, starts[0..2]);

    // Unchanged: nothing runs, the same links come back.
    cfgs[0].regex.searches = 0;
    try testing.expectEqual(2, try applyStarts(&cache, "a link\nb link", &cfgs, &starts));
    try testing.expectEqual(0, cfgs[0].regex.searches);
    try testing.expectEqualSlices(usize, &.{ 2, 9 }, starts[0..2]);

    // One row changed.
    try testing.expectEqual(2, try applyStarts(&cache, "a link\nccc link", &cfgs, &starts));
    try testing.expectEqual(1, cfgs[0].regex.searches);
    try testing.expectEqualSlices(usize, &.{ 2, 11 }, starts[0..2]);

    // Scrolled by a row: the surviving row is found by its text and gets
    // its new offset.
    cfgs[0].regex.searches = 0;
    try testing.expectEqual(2, try applyStarts(&cache, "ccc link\nd link", &cfgs, &starts));
    try testing.expectEqual(1, cfgs[0].regex.searches);
    try testing.expectEqualSlices(usize, &.{ 4, 11 }, starts[0..2]);

    // A row repeated within one refresh is matched once.
    cfgs[0].regex.searches = 0;
    try testing.expectEqual(3, try applyStarts(&cache, "e link\ne link\ne link", &cfgs, &starts));
    try testing.expectEqual(1, cfgs[0].regex.searches);
    try testing.expectEqualSlices(usize, &.{ 2, 9, 16 }, starts[0..3]);

    // Rows that left the viewport were dropped, not kept forever.
    try testing.expectEqual(1, cache.rows.count());
}

test "a11y text: regex link cache starts over when the patterns change" {
    var cfgs_a = [_]CountingCfg{.{ .regex = .{ .needle = "link" } }};
    var cfgs_b = [_]CountingCfg{.{ .regex = .{ .needle = "link" } }};
    var cache: RegexLinkCache = .{};
    defer cache.deinit(testing.allocator);
    var starts: [1]usize = undefined;

    _ = try applyStarts(&cache, "a link", &cfgs_a, &starts);
    _ = try applyStarts(&cache, "a link", &cfgs_b, &starts);
    try testing.expectEqual(1, cfgs_b[0].regex.searches);

    // No patterns at all: nothing matches and nothing stale survives.
    _ = try applyStarts(&cache, "a link", cfgs_b[0..0], &starts);
    try testing.expectEqual(0, cache.rows.count());
}

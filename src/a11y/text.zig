//! Builds the flat UTF-8 text snapshot of a terminal viewport that
//! accessibility clients (AT-SPI on Linux) read.
//!
//! This lives outside of any apprt implementation so the viewport walk
//! can be unit tested and benchmarked without standing up a live GTK
//! surface and an AT-SPI bus. `src/benchmark/A11yText.zig` drives it
//! directly; `apprt/gtk/class/surface_a11y.zig` drives it under the
//! renderer mutex on every rendered frame while an AT client is attached.
//!
//! The snapshot is a plain grid render: one line per viewport row, rows
//! joined by `\n`, trailing blanks on a row dropped and interior blanks
//! kept as spaces so columns still line up. `offsets.zig` is the
//! companion module that navigates the result.
//!
//! IMPORTANT: every offset produced here that is destined for an AT
//! client is in UTF-8 *codepoints*, not bytes. `Result.cursor_byte` is
//! the one exception and is explicitly named as such; convert it with
//! `unicode.utf8.cpCount` before handing it out.

const std = @import("std");
const terminal = @import("../terminal/main.zig");
const terminal_hyperlink = @import("../terminal/hyperlink.zig");
const unicode = @import("../unicode/main.zig");
const offsets = @import("offsets.zig");

const log = std.log.scoped(.a11y_text);

pub const Options = struct {
    /// Whether `buildWithSink` looks up OSC 8 hyperlinks during the
    /// walk. Callers skip it when the runtime cannot expose hyperlinks at
    /// all (GTK older than 4.22, where the Hypertext interface isn't
    /// registered), so nothing pays for lookups nothing will read.
    track_links: bool = true,

    /// Where to record how many columns each emitted codepoint occupies
    /// (`offsets.CellWidths`). One byte is written per codepoint
    /// appended to the text, so the two stay index-aligned: 2 for a
    /// double-width cell, 0 for a combining mark that shares its base
    /// character's cell, 1 otherwise.
    ///
    /// This is the only place the mapping is knowable: the cell walk is
    /// what sees `cell.wide`, and the text alone cannot be re-measured
    /// afterwards without guessing at the terminal's grapheme-width
    /// method. Callers that only need the text (the per-frame change
    /// probe, the benchmark) leave it null and pay nothing.
    ///
    /// Like the text, this stream is appended to, not cleared, so a
    /// caller reusing a buffer must clear it or the widths drift out of
    /// alignment with the text built by this call.
    widths: ?*std.Io.Writer = null,
};

pub const Result = struct {
    /// Byte offset of the cursor, counted from the first byte this walk
    /// writes, or null if the cursor row wasn't part of the viewport.
    /// Callers anchor a null at end-of-text. A caller that starts from
    /// an empty buffer (all of them do) can read this as a buffer
    /// offset directly.
    cursor_byte: ?usize,

    /// Total codepoints appended to the buffer by this walk.
    cp_count: usize,
};

/// The snapshot under construction: the text, the per-codepoint column
/// widths that must stay index-aligned with it, and the running codepoint
/// count.
///
/// Every append goes through here so the three cannot drift apart. They
/// used to be advanced by hand at each append site, which is four places
/// that all had to agree, and a drift silently shifts every column lookup
/// after the offending codepoint. That is the failure mode that put a routed
/// caret inside the character to the left of the one it named.
const Snapshot = struct {
    text: *std.Io.Writer,
    widths: ?*std.Io.Writer,
    cp_count: usize = 0,
    /// Bytes written to `text` so far. Tracked here rather than asked of
    /// the writer, because a writer has no stream position: `Writer.end`
    /// is an index into its internal buffer and resets when a draining
    /// implementation flushes.
    bytes: usize = 0,

    /// Byte offset of the next codepoint to be appended.
    fn end(self: Snapshot) usize {
        return self.bytes;
    }

    /// Append `n` copies of an ASCII byte, each occupying `columns`
    /// screen columns.
    fn addAscii(
        self: *Snapshot,
        byte: u8,
        columns: u8,
        n: usize,
    ) std.Io.Writer.Error!void {
        try self.text.splatByteAll(byte, n);
        self.bytes += n;
        try self.advance(columns, n);
    }

    /// Append one character: a base codepoint occupying `columns` screen
    /// columns, plus any combining marks that share its cell.
    fn addCharacter(
        self: *Snapshot,
        base: u21,
        graphemes: ?[]const u21,
        columns: u8,
    ) std.Io.Writer.Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(base, &buf) catch {
            // Shouldn't happen, since the terminal stores validated
            // scalars, but if one does reach us it still has to occupy
            // its cell,
            // or every offset after it shifts. Its combining marks go
            // with it; they have nothing left to combine with.
            return self.addAscii('?', columns, 1);
        };
        try self.text.writeAll(buf[0..n]);
        self.bytes += n;
        try self.advance(columns, 1);

        for (graphemes orelse return) |cp| {
            const gn = std.unicode.utf8Encode(cp, &buf) catch continue;
            try self.text.writeAll(buf[0..gn]);
            self.bytes += gn;
            // Part of the base character's cell: extra codepoints, no
            // extra columns.
            try self.advance(0, 1);
        }
    }

    fn advance(self: *Snapshot, columns: u8, n: usize) std.Io.Writer.Error!void {
        if (self.widths) |w| try w.splatByteAll(columns, n);
        self.cp_count += n;
    }
};

/// A sink that discards every range. `build` walks with one, and because
/// `buildWithSink` checks for it at comptime, that walk does no style or
/// hyperlink lookups at all: the per-frame change probe needs to know
/// whether the text moved, not what it looks like.
pub const NullSink = struct {
    pub fn commitLink(_: *NullSink, _: usize, _: usize, _: []const u8) void {}
    pub fn commitStyleRun(_: *NullSink, _: usize, _: usize, _: terminal.Style) void {}
    pub fn committedLinkCount(_: *NullSink) usize {
        return 0;
    }
    pub fn linkOverlaps(_: *NullSink, _: usize, _: usize, _: usize) bool {
        return false;
    }
};

/// Walk the viewport of `screen` and write its text to `writer`, without
/// collecting link or style ranges.
///
/// The stream is appended to, not cleared, so callers reusing a buffer
/// must clear it themselves.
pub fn build(
    writer: *std.Io.Writer,
    screen: *terminal.Screen,
    opts: Options,
) std.Io.Writer.Error!Result {
    var sink: NullSink = .{};
    return buildWithSink(writer, screen, &sink, opts);
}

/// Like `build`, but also report the ranges the walk discovers to `sink`.
/// Required methods, all offsets in codepoints:
///
///   fn commitLink(self, start_cp: usize, end_cp: usize, uri: []const u8) void
///   fn commitStyleRun(self, start_cp: usize, end_cp: usize, style: terminal.Style) void
///   fn committedLinkCount(self) usize
///   fn linkOverlaps(self, start_cp: usize, end_cp: usize, limit: usize) bool
///
/// `uri` is borrowed from page memory and only valid for the duration of
/// the call, so a sink that keeps it must copy it. Sinks swallow their own
/// allocation failures: a dropped link degrades to plain text, which is
/// better than failing the whole snapshot. The last two methods exist for
/// `matchRegexLinks`.
///
/// Style runs cover maximal spans of identically styled, non-default
/// codepoints; gaps between them (blanks, row separators) are default.
/// Links close at blanks and at row ends, so each visual line of a link
/// becomes its own navigable range.
///
/// The caller must hold the renderer mutex: this reads live page memory.
pub fn buildWithSink(
    writer: *std.Io.Writer,
    screen: *terminal.Screen,
    sink: anytype,
    opts: Options,
) std.Io.Writer.Error!Result {
    const pages = &screen.pages;
    const viewport_rows: usize = pages.rows;

    // Comptime, so the text-only walk is the same code it was before
    // ranges existed rather than paying for lookups it throws away.
    const collect = @TypeOf(sink) != *NullSink;
    const track_links = collect and opts.track_links;

    var snap: Snapshot = .{
        .text = writer,
        .widths = opts.widths,
    };

    // The link run open on the current row. `id` is only unique within a
    // page, which is enough: rows don't straddle pages and runs close at
    // row ends. `uri` is borrowed from page memory.
    var cur_link: ?struct {
        id: terminal_hyperlink.Id,
        start_cp: usize,
        uri: []const u8,
    } = null;

    // The non-default style run open at the current codepoint. Identical
    // adjacent cells coalesce, so a mostly-default viewport produces no
    // runs and a styled one roughly one per SGR region per row.
    var cur_style: ?StyleRun = null;

    // The position the AT-SPI caret reports. In caret mode the user is
    // driving the keyboard caret and the terminal cursor is irrelevant to
    // them, so the caret is what an assistive client has to be told about:
    // navigating without selecting emits no selection change, so this is
    // the only signal that anything moved. Outside caret mode the two are
    // the same. Null when the caret has scrolled out of the viewport.
    const cursor: ?struct { x: usize, y: usize } = cursor: {
        if (screen.caret_mode) {
            const pin = screen.caret_pin orelse break :cursor null;
            const pt = pages.pointFromPin(.viewport, pin.*) orelse
                break :cursor null;
            break :cursor .{ .x = pt.viewport.x, .y = pt.viewport.y };
        }
        break :cursor .{ .x = screen.cursor.x, .y = screen.cursor.y };
    };

    // Where the AT-SPI caret belongs. Null until the walk reaches the
    // cursor's row, and still null afterwards if that row never came out
    // of the iterator or the cursor is not in the viewport at all.
    var cursor_byte: ?usize = null;
    const cursor_x = if (cursor) |c| c.x else 0;

    const tl_pin = pages.getTopLeft(.viewport);
    var row_it = tl_pin.rowIterator(.right_down, null);
    var row_idx: usize = 0;
    while (row_idx < viewport_rows) : (row_idx += 1) {
        if (row_idx > 0) {
            // A row separator, not a cell: it occupies no column, and
            // column math never crosses it. It is default-styled.
            if (collect) closeStyle(sink, &cur_style, snap.cp_count);
            try snap.addAscii('\n', 0, 1);
        }

        const pin = row_it.next() orelse continue;
        const is_cursor_row = if (cursor) |c| row_idx == c.y else false;

        const cells = pin.cells(.all);
        const page = pin.node.page();

        // A cursor on the tail half of a wide character belongs to the
        // character itself, which occupies the preceding column. A spacer
        // has no text and is skipped without accumulating a blank, so
        // leaving it to the deferred blank-run path below would never
        // resolve it and the caret would fall through to end-of-row.
        // `spacer_head` is deliberately not folded in: its wide character
        // lives on the *next* row, so end-of-row is the right answer there.
        const row_cursor_x = if (is_cursor_row and
            cursor_x > 0 and
            cursor_x < cells.len and
            cells[cursor_x].wide == .spacer_tail)
            cursor_x - 1
        else
            cursor_x;

        // Accumulate empty cells so runs of trailing empties drop off the
        // end of the row, but intermediate gaps still get emitted as
        // spaces to preserve column positions. This matches what
        // `ScreenFormatter` does for non-trailing blanks.
        var blank_cells: usize = 0;
        // Pending cursor position when the cursor lands on a blank cell:
        // index into the current blank run where the cursor sits.
        // Resolved to an absolute byte offset either when the blanks
        // flush (inside the about-to-be-emitted space run) or at
        // end-of-row when the blanks get eaten as trailing (= end of the
        // emitted text).
        var cursor_blank_idx: ?usize = null;
        for (0..cells.len) |col| {
            const cell = &cells[col];

            // Record the cursor position before writing the cell at
            // `cursor_x`, so the offset points AT that cell. For blank
            // cells we defer: capture the blank-run index and resolve on
            // flush or end-of-row.
            if (is_cursor_row and col == row_cursor_x) {
                if (cell.hasText()) {
                    cursor_byte = snap.end();
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
                // A blank splits a link run. One OSC 8 escape can bridge
                // whitespace visually, but per-word ranges announce more
                // cleanly and match what a sighted user perceives.
                if (track_links) if (cur_link) |cl| {
                    sink.commitLink(cl.start_cp, snap.cp_count, cl.uri);
                    cur_link = null;
                };
                continue;
            }

            // Flush accumulated blanks as spaces, one column each. Spaces
            // are default-styled, so they end any open style run.
            if (blank_cells > 0) {
                if (collect) closeStyle(sink, &cur_style, snap.cp_count);
                // Resolve a cursor that landed inside this blank run to
                // its column within the about-to-be-emitted spaces.
                if (cursor_blank_idx) |idx| {
                    cursor_byte = snap.end() + idx;
                    cursor_blank_idx = null;
                }
                try snap.addAscii(' ', 1, blank_cells);
                blank_cells = 0;
            }

            if (collect) {
                // Cells without text took the branch above, so this one
                // carries a codepoint; `hasStyling` is false for the
                // default style.
                const style: terminal.Style = if (cell.hasStyling())
                    page.styles.get(page.memory, cell.style_id).*
                else
                    .{};
                const same = if (cur_style) |cs| cs.style.eql(style) else style.default();
                if (!same) {
                    closeStyle(sink, &cur_style, snap.cp_count);
                    if (!style.default()) cur_style = .{
                        .start_cp = snap.cp_count,
                        .style = style,
                    };
                }
            }

            if (track_links) {
                // Resolve this cell's link before writing it, so a run
                // that opens here starts at this cell's first codepoint.
                const cell_link: ?terminal_hyperlink.Id = if (cell.hyperlink)
                    page.lookupHyperlink(cell)
                else
                    null;
                if (cur_link) |cl| {
                    if (cell_link == null or cell_link.? != cl.id) {
                        sink.commitLink(cl.start_cp, snap.cp_count, cl.uri);
                        cur_link = null;
                    }
                }
                if (cur_link == null) if (cell_link) |id| {
                    cur_link = .{
                        .id = id,
                        .start_cp = snap.cp_count,
                        .uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory),
                    };
                };
            }

            // Columns this cell covers on screen. `.wide` cells are
            // followed by a `.spacer_tail` that the switch above skipped,
            // so the character is one codepoint standing in for two
            // columns, which is the whole reason widths cannot be recovered from
            // the text later.
            const cell_columns: u8 = if (cell.wide == .wide) 2 else 1;

            try snap.addCharacter(
                cell.codepoint(),
                if (cell.hasGrapheme()) pin.grapheme(cell) else null,
                cell_columns,
            );
        }

        // If the cursor is past the last column we emitted (trailing
        // blanks, or a cursor beyond the row end), anchor to end-of-row.
        if (is_cursor_row and row_cursor_x >= cells.len) {
            cursor_byte = snap.end();
        }

        // The cursor landed inside a blank run that never flushed, so those
        // cells are trailing and got eaten. Anchor to the end of the text
        // emitted on this row.
        if (cursor_blank_idx != null) {
            cursor_byte = snap.end();
            cursor_blank_idx = null;
        }

        // Links don't span rows: each visual line is its own range.
        if (track_links) if (cur_link) |cl| {
            sink.commitLink(cl.start_cp, snap.cp_count, cl.uri);
            cur_link = null;
        };
    }

    if (collect) closeStyle(sink, &cur_style, snap.cp_count);

    return .{
        .cursor_byte = cursor_byte,
        .cp_count = snap.cp_count,
    };
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

/// Scan already-built viewport `text` for configured regex links (bare
/// URLs, user patterns) and commit each hit that doesn't overlap an OSC 8
/// link to `sink`.
///
/// Run this after `buildWithSink`, so the OSC 8 ranges are already
/// committed: when the two overlap the OSC 8 link wins, since its URI is
/// explicit and the regex is a guess. Every pattern is matched regardless
/// of its `highlight` mode. That gate decides when a sighted user sees a
/// cue, not whether a region is a link, and a screen reader user cannot
/// hover to reveal one.
///
/// `link_cfgs` is any slice whose elements have a `regex` field with
/// oniguruma's `search` interface. This does not need the renderer mutex:
/// it reads only `text` and the regexes, and the caller keeps those alive.
pub fn matchRegexLinks(
    text: []const u8,
    link_cfgs: anytype,
    sink: anytype,
) void {
    if (text.len == 0 or link_cfgs.len == 0) return;

    // Only dedup against the OSC 8 links. Two configured regexes that
    // both match a span both land, which announces no worse than a
    // duplicated OSC 8 link would.
    const osc8_end = sink.committedLinkCount();

    for (link_cfgs) |*link_cfg| {
        // Matches arrive in byte order, so the byte-to-codepoint
        // conversion advances monotonically instead of rescanning from
        // the start for every match.
        var scan_byte: usize = 0;
        var scan_cp: usize = 0;

        var byte_offset: usize = 0;
        while (byte_offset < text.len) {
            var region = link_cfg.regex.search(
                text[byte_offset..],
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

            // A user regex may cross a row; clip at the newline so the
            // link stays on one visual row like OSC 8 runs do.
            const clipped_end = if (std.mem.indexOfScalar(u8, text[abs_start..abs_end], '\n')) |i|
                abs_start + i
            else
                abs_end;
            if (clipped_end <= abs_start) continue;

            while (scan_byte < abs_start) : (scan_cp += 1) {
                scan_byte += unicode.utf8.cpLen(text[scan_byte]);
            }
            const cp_start = scan_cp;
            while (scan_byte < clipped_end) : (scan_cp += 1) {
                scan_byte += unicode.utf8.cpLen(text[scan_byte]);
            }
            const cp_end = scan_cp;

            if (sink.linkOverlaps(cp_start, cp_end, osc8_end)) continue;
            sink.commitLink(cp_start, cp_end, text[abs_start..clipped_end]);
        }
    }
}

const testing = std.testing;

test "a11y text: rows joined by newline, trailing blanks trimmed" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hello");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("world");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    // Row 2 is empty, so it contributes its leading '\n' and nothing else.
    try testing.expectEqualStrings("hello\nworld\n", buffer.written());
    try testing.expectEqual(12, result.cp_count);
}

test "a11y text: widths report the columns each codepoint covers" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    // Three double-width characters between narrow ones. The wide cells
    // each get a spacer the walk skips, so the text is one codepoint per
    // character while the row is 5 + 6 + 5 columns wide.
    try t.printString("wide 日本語 tail");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    var widths: std.Io.Writer.Allocating = .init(alloc);
    defer widths.deinit();

    const result = try build(
        &buffer.writer,
        t.screens.active,
        .{ .widths = &widths.writer },
    );

    // One width per codepoint, or every lookup past the drift is wrong.
    try testing.expectEqual(result.cp_count, widths.written().len);

    // "wide " then 日本語 then " tail", plus the row separator.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
        widths.written(),
    );

    // The payoff: 't' of "tail" is codepoint 9 but column 12. Reading the
    // codepoint index as a column is what put a routed caret three cells
    // to the left, inside 語.
    const t_byte = std.mem.indexOf(u8, buffer.written(), "tail").?;
    const cp_idx = unicode.utf8.cpCount(buffer.written()[0..t_byte]);
    try testing.expectEqual(9, cp_idx);
    try testing.expectEqual(
        12,
        offsets.cpToGrid(buffer.written(), .{ .per_cp = widths.written() }, cp_idx).col,
    );
}

test "a11y text: recording widths does not change the text" {
    // The per-frame change probe builds without widths and compares the
    // result against the last notified snapshot, which was built *with*
    // them. That gate is only valid if the two paths agree byte for byte.
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("héllo 日本語");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("  spaced  out");

    var with: std.Io.Writer.Allocating = .init(alloc);
    defer with.deinit();
    var widths: std.Io.Writer.Allocating = .init(alloc);
    defer widths.deinit();
    const with_result = try build(
        &with.writer,
        t.screens.active,
        .{ .widths = &widths.writer },
    );

    var without: std.Io.Writer.Allocating = .init(alloc);
    defer without.deinit();
    const without_result = try build(&without.writer, t.screens.active, .{});

    try testing.expectEqualStrings(with.written(), without.written());
    try testing.expectEqual(with_result.cp_count, without_result.cp_count);
    try testing.expectEqual(with_result.cursor_byte, without_result.cursor_byte);
}

test "a11y text: intermediate blanks preserved as spaces" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try build(&buffer.writer, t.screens.active, .{});
    try testing.expectEqualStrings("ab   cd", buffer.written());
}

test "a11y text: cursor anchors past trailing blanks" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("hi");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("abc");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    // "hi\nabc", with the cursor on the blank after "abc". That is
    // trailing, so it anchors at end-of-text.
    try testing.expectEqualStrings("hi\nabc", buffer.written());
    try testing.expectEqual(6, result.cursor_byte.?);
}

test "a11y text: cursor inside an interior blank run lands on its column" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 7);
    try t.printString("cd");
    // Park the cursor on column 4 (0-based 3), inside the blank gap that
    // gets flushed as spaces rather than eaten as trailing.
    t.setCursorPos(1, 4);

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    try testing.expectEqualStrings("ab    cd", buffer.written());
    // Byte 3 is the second of the four spaces, the cell the cursor is
    // on, not the start or the end of the run.
    try testing.expectEqual(3, result.cursor_byte.?);
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

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, screen, .{});

    // The terminal cursor is still after "second", but the caret moved up
    // a row. Moving the caret emits no selection change, so the reported
    // caret offset is the only thing that tells a client it moved.
    try testing.expectEqualStrings("first\nsecond", buffer.written());
    const caret_pt = screen.pages.pointFromPin(.viewport, screen.caret_pin.?.*).?;
    try testing.expectEqual(0, caret_pt.viewport.y);
    try testing.expectEqual(caret_pt.viewport.x, result.cursor_byte.?);
}

test "a11y text: cursor on a wide character's spacer lands on the character" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 日 occupies columns 2 and 3; column 3 is its spacer tail.
    try t.printString("ab日cd");
    t.setCursorPos(1, 4);

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    try testing.expectEqualStrings("ab日cd", buffer.written());
    // The cursor is visually sitting on 日, so it must resolve to that
    // character's own offset. A spacer has no text and is skipped without
    // accumulating a blank, so the deferred blank-run path can never
    // resolve it and it would otherwise fall through to end-of-row.
    try testing.expectEqual(2, result.cursor_byte.?);
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
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try buildWithSink(&buffer.writer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("\u{2192}\u{2192}link", buffer.written());
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
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try buildWithSink(&buffer.writer, t.screens.active, &sink, .{ .track_links = false });

    try testing.expectEqualStrings("link", buffer.written());
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
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try buildWithSink(&buffer.writer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("abcd\nefgh", buffer.written());
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
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try buildWithSink(&buffer.writer, t.screens.active, &sink, .{});

    try testing.expectEqualStrings("bold plain", buffer.written());
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

    // The per-frame change probe walks without a sink to stay cheap. It is
    // only a valid gate if its text is byte-identical to a full rebuild's.
    var sink: TestSink = .{ .alloc = alloc };
    defer sink.deinit();
    var full: std.Io.Writer.Allocating = .init(alloc);
    defer full.deinit();
    const full_result = try buildWithSink(&full.writer, t.screens.active, &sink, .{});

    var probe: std.Io.Writer.Allocating = .init(alloc);
    defer probe.deinit();
    const probe_result = try build(&probe.writer, t.screens.active, .{});

    try testing.expectEqualStrings(full.written(), probe.written());
    try testing.expectEqual(full_result.cp_count, probe_result.cp_count);
    try testing.expectEqual(full_result.cursor_byte, probe_result.cursor_byte);

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
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try buildWithSink(&buffer.writer, t.screens.active, &sink, .{});
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

    matchRegexLinks(buffer.written(), &cfgs, &sink);

    // The OSC 8 range survives; only the trailing bare URL is added.
    try testing.expectEqual(2, sink.links.items.len);
    try testing.expectEqual(20, sink.links.items[1].start_cp);
    try testing.expectEqualStrings("https://ghostty.org", sink.links.items[1].uri);
}

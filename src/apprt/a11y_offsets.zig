//! Offset math over the flat accessibility text snapshot produced by
//! `a11y_text.build`.
//!
//! Where `a11y_text` produces the snapshot, this module navigates it:
//! converting between byte offsets, UTF-8 codepoint offsets, terminal
//! grid positions and widget-space points, and computing the minimal
//! diff between two snapshots.
//!
//! It is deliberately free of GTK and of any surface state — every
//! function takes the snapshot text and returns numbers — so the offset
//! arithmetic can be tested directly. That matters more here than
//! anywhere else in the accessibility code: AT-SPI offsets are in
//! codepoints, not bytes, and every historical crash in this subsystem
//! has been a boundary or unit mix-up. Handing an orphan UTF-8
//! continuation byte to the AT-SPI bridge makes `g_variant_new_string`
//! return NULL and SIGSEGVs inside `g_variant_builder_add_value`; being
//! off by a codepoint in the other direction silently truncates what a
//! screen reader announces.

const std = @import("std");

/// Byte length of a UTF-8 codepoint given its leading byte. Malformed
/// continuation or overlong starts advance 1 byte so the scan always
/// makes forward progress.
pub fn utf8CpLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// Count UTF-8 codepoints in `s`.
pub fn utf8CpCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) i += utf8CpLen(s[i]);
    return n;
}

/// Byte offset of the `cp_idx`-th codepoint in `s`. Clamps at `s.len`.
pub fn utf8CpToByte(s: []const u8, cp_idx: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < s.len and c < cp_idx) : (c += 1) i += utf8CpLen(s[i]);
    return i;
}

/// Byte offset of the first byte that does not begin a valid UTF-8
/// sequence, or null when `slice` validates cleanly.
///
/// Callers use this purely for diagnostics: our own snapshots are sliced
/// on codepoint boundaries, so a hit means the buffer itself is corrupt
/// and the offset identifies where.
pub fn firstInvalidUtf8(slice: []const u8) ?usize {
    if (std.unicode.utf8ValidateSlice(slice)) return null;

    var bad: usize = 0;
    while (bad < slice.len) {
        const len = utf8CpLen(slice[bad]);
        if (bad + len > slice.len) break;
        if (!std.unicode.utf8ValidateSlice(slice[bad..][0..len])) break;
        bad += len;
    }
    return bad;
}

/// Bytes `[0..p)` and `[len-s..)` are unchanged between the two
/// snapshots; the rest was replaced. Both offsets land on UTF-8
/// codepoint boundaries in `old`.
pub const PrefixSuffixDiff = struct {
    p: usize,
    s: usize,
};

/// Compute the byte-wise common prefix and suffix of `old` and `new`,
/// then pull both offsets back to UTF-8 codepoint boundaries.
///
/// Alignment matters because two multi-byte codepoints can share a
/// leading byte (e.g. `│` and `├`, both starting with 0xE2 0x94), and a
/// byte-wise compare can land inside a character.
pub fn prefixSuffix(old_text: []const u8, new_text: []const u8) PrefixSuffixDiff {
    var p: usize = 0;
    const min_len = @min(old_text.len, new_text.len);
    while (p < min_len and old_text[p] == new_text[p]) : (p += 1) {}

    // Cap the suffix so it can't overlap the prefix (that would make the
    // remove/insert ranges go negative).
    var s: usize = 0;
    const max_s = @min(old_text.len - p, new_text.len - p);
    while (s < max_s and
        old_text[old_text.len - 1 - s] == new_text[new_text.len - 1 - s]) : (s += 1)
    {}

    // The `p < old_text.len` guard matters when `old_text` is a prefix of
    // `new_text`: `p == old_text.len` and indexing would go out of
    // bounds, but end-of-buffer is already a codepoint boundary.
    while (p > 0 and p < old_text.len and (old_text[p] & 0xC0) == 0x80) : (p -= 1) {}
    while (s > 0 and (old_text[old_text.len - s] & 0xC0) == 0x80) : (s -= 1) {}

    return .{ .p = p, .s = s };
}

/// Look for a whole-line scroll up: a K > 0 at a `\n` boundary of `old`
/// such that `new[0..|old|-K] == old[K..]`. Returns 0 if no such K
/// exists. Since `\n` is ASCII, every candidate K is already a UTF-8
/// codepoint boundary.
pub fn scrollK(old_text: []const u8, new_text: []const u8) usize {
    if (old_text.len == 0) return 0;
    var i: usize = 0;
    while (i < old_text.len) : (i += 1) {
        if (old_text[i] != '\n') continue;
        const boundary = i + 1;
        const remainder = old_text.len - boundary;
        // A zero-byte remainder matches trivially at every trailing `\n`
        // and would mask the prefix/suffix diff for every change where
        // old_text ends in `\n`. Require a non-trivial middle.
        if (remainder == 0 or remainder > new_text.len) continue;
        if (std.mem.eql(u8, new_text[0..remainder], old_text[boundary..])) {
            return boundary;
        }
    }
    return 0;
}

/// Map (row, col) in the snapshot to a codepoint offset. Returns null
/// when `row` is past the last row in `text`.
///
/// Contrast `offsetAtGrid`, which clamps to the last row instead. The
/// difference is deliberate: a selection anchored to a row that scrolled
/// out of the viewport has no offset and must be dropped, whereas a
/// pointer event below the last row should still resolve to something.
pub fn rowColToCp(text: []const u8, row: u32, col: u32) ?usize {
    var seen_nl: u32 = 0;
    var row_start: usize = 0;
    if (row > 0) {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n') {
                seen_nl += 1;
                if (seen_nl == row) {
                    row_start = i + 1;
                    break;
                }
            }
        }
        if (seen_nl < row) return null;
    }
    var row_end: usize = row_start;
    var row_cp: u32 = 0;
    while (row_end < text.len and text[row_end] != '\n') {
        row_end += utf8CpLen(text[row_end]);
        row_cp += 1;
    }
    const clamped_col: u32 = @min(col, row_cp);
    const row_prefix_cp = utf8CpCount(text[0..row_start]);
    return row_prefix_cp + clamped_col;
}

/// Map (row, col) to a codepoint offset, clamping a row past the end of
/// the snapshot to the last row and a column past end-of-row to the row
/// length. Always resolves; see `rowColToCp` for the variant that fails.
pub fn offsetAtGrid(text: []const u8, want_row: u32, col_in: u32) c_uint {
    var col = col_in;

    // Single-pass scan: find the byte offset where row `want_row` begins.
    // If the point is past the last row, fall back to the start of
    // whatever the last row in the buffer is.
    var row_start: usize = 0;
    var last_row_start: usize = 0;
    var seen_newlines: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            seen_newlines += 1;
            last_row_start = i + 1;
            if (seen_newlines == want_row) {
                row_start = i + 1;
                break;
            }
        }
    }
    if (seen_newlines < want_row) row_start = last_row_start;

    // Measure the codepoint length of the row and clamp the requested
    // column to it.
    var row_end: usize = row_start;
    var row_cp_count: u32 = 0;
    while (row_end < text.len and text[row_end] != '\n') {
        row_end += utf8CpLen(text[row_end]);
        row_cp_count += 1;
    }
    if (col > row_cp_count) col = row_cp_count;

    // Advance `col` codepoints into the row. `row_start` and `row_end`
    // are codepoint-aligned by construction, so the slice is safe to
    // walk.
    const byte_offset = row_start + utf8CpToByte(text[row_start..row_end], col);
    return @intCast(utf8CpCount(text[0..byte_offset]));
}

/// A position on the terminal grid, in cells.
pub const GridPos = struct {
    row: u32,
    col: u32,
};

/// Convert a widget-space point to a grid position.
///
/// Negative and non-finite inputs clamp to (0, 0) so the float-to-int
/// conversion stays in range; `max_cells` guards against absurd
/// magnitudes. Callers clamp the result against the actual text bounds.
pub fn pointToGrid(x: f32, y: f32, cell_w: f32, cell_h: f32) GridPos {
    const max_cells: f32 = 1_000_000;
    const row_f = y / cell_h;
    const col_f = x / cell_w;
    const row_clamped: f32 = if (std.math.isFinite(row_f))
        @max(0, @min(row_f, max_cells))
    else
        0;
    const col_clamped: f32 = if (std.math.isFinite(col_f))
        @max(0, @min(col_f, max_cells))
    else
        0;
    return .{
        .row = @intFromFloat(row_clamped),
        .col = @intFromFloat(col_clamped),
    };
}

/// The grid rectangle covered by a codepoint range. Height is always one
/// row: AT clients get one rect per line, and a range spanning rows is
/// reported as its first row only.
pub const GridRect = struct {
    row: u32,
    col: u32,
    width_cols: u32,
};

/// Grid rectangle for the codepoint range `[start, end)`.
///
/// Rows must come out distinct per line — a screen reader's flat review
/// collapses to a single line if every row reports the same Y.
pub fn extentsCells(text: []const u8, start: c_uint, end: c_uint) GridRect {
    const text_cp_count: c_uint = @intCast(utf8CpCount(text));
    const s_cp = @min(start, text_cp_count);
    const e_cp = @min(end, text_cp_count);
    const s_byte = utf8CpToByte(text, s_cp);
    const e_byte = utf8CpToByte(text, e_cp);

    // Row index of `s_byte` within the viewport: count newlines before it.
    var row: u32 = 0;
    for (text[0..s_byte]) |ch| {
        if (ch == '\n') row += 1;
    }

    // Column index of `s_byte`: scan back to the last newline (or start)
    // and count codepoints in that prefix — one codepoint per terminal
    // cell in our dump.
    var col_start: usize = s_byte;
    while (col_start > 0 and text[col_start - 1] != '\n') : (col_start -= 1) {}
    const col: u32 = @intCast(utf8CpCount(text[col_start..s_byte]));

    // Width in cells: codepoints from `s_byte` to the first newline (or
    // `e_byte`), whichever comes first.
    var width_cols: u32 = 0;
    var i_byte: usize = s_byte;
    while (i_byte < e_byte and text[i_byte] != '\n') {
        i_byte += utf8CpLen(text[i_byte]);
        width_cols += 1;
    }
    if (width_cols == 0) width_cols = 1;

    return .{ .row = row, .col = col, .width_cols = width_cols };
}

/// Text granularities we resolve. GTK's enum also carries `sentence` and
/// `paragraph`; both map to `line` for a terminal, where a visual row is
/// the only meaningful unit above a word.
pub const Granularity = enum {
    character,
    word,
    line,
};

/// A resolved granularity range: codepoint bounds plus the matching
/// slice of the input text.
pub const Contents = struct {
    start_cp: c_uint,
    end_cp: c_uint,
    bytes: []const u8,
};

/// Resolve the `granularity`-sized run of text containing codepoint
/// `offset`.
///
/// `offset` arrives from AT-SPI as a codepoint index. Boundary scanning
/// runs on bytes (fast, simple) and converts back to codepoint indices
/// before returning, so callers never see a byte offset.
pub fn contentsAt(
    text: []const u8,
    offset: c_uint,
    granularity: Granularity,
) Contents {
    const text_cp_count: c_uint = @intCast(utf8CpCount(text));
    const off_cp = @min(offset, text_cp_count);
    const off_byte = utf8CpToByte(text, off_cp);

    switch (granularity) {
        .character => {
            if (off_cp >= text_cp_count) return .{
                .start_cp = text_cp_count,
                .end_cp = text_cp_count,
                .bytes = text[text.len..],
            };
            const end_byte = off_byte + utf8CpLen(text[off_byte]);
            return .{
                .start_cp = off_cp,
                .end_cp = off_cp + 1,
                .bytes = text[off_byte..end_byte],
            };
        },
        .word => {
            var ws_byte: usize = off_byte;
            while (ws_byte > 0 and
                text[ws_byte - 1] != ' ' and
                text[ws_byte - 1] != '\n') : (ws_byte -= 1)
            {}
            var we_byte: usize = off_byte;
            while (we_byte < text.len and
                text[we_byte] != ' ' and
                text[we_byte] != '\n') : (we_byte += 1)
            {}
            return .{
                .start_cp = @intCast(utf8CpCount(text[0..ws_byte])),
                .end_cp = @intCast(utf8CpCount(text[0..we_byte])),
                .bytes = text[ws_byte..we_byte],
            };
        },
        .line => {
            var ls_byte: usize = off_byte;
            while (ls_byte > 0 and text[ls_byte - 1] != '\n') : (ls_byte -= 1) {}
            var le_byte: usize = off_byte;
            while (le_byte < text.len and text[le_byte] != '\n') : (le_byte += 1) {}
            if (le_byte < text.len) le_byte += 1; // include the newline
            return .{
                .start_cp = @intCast(utf8CpCount(text[0..ls_byte])),
                .end_cp = @intCast(utf8CpCount(text[0..le_byte])),
                .bytes = text[ls_byte..le_byte],
            };
        },
    }
}

const testing = std.testing;

// A three-byte codepoint whose leading two bytes are shared with `├`
// (0xE2 0x94 0x82 vs 0xE2 0x94 0x9C). This pair is what makes a
// byte-wise diff land mid-character.
const box_v = "│";
const box_t = "├";

test "utf8: codepoint length, count and index" {
    try testing.expectEqual(@as(usize, 1), utf8CpLen('a'));
    try testing.expectEqual(@as(usize, 2), utf8CpLen("é"[0]));
    try testing.expectEqual(@as(usize, 3), utf8CpLen(box_v[0]));
    try testing.expectEqual(@as(usize, 4), utf8CpLen("😀"[0]));

    // Continuation bytes advance by one so a malformed scan terminates.
    try testing.expectEqual(@as(usize, 1), utf8CpLen(0x80));

    const s = "a" ++ box_v ++ "b😀";
    try testing.expectEqual(@as(usize, 4), utf8CpCount(s));
    try testing.expectEqual(@as(usize, 9), s.len);

    try testing.expectEqual(@as(usize, 0), utf8CpToByte(s, 0));
    try testing.expectEqual(@as(usize, 1), utf8CpToByte(s, 1));
    try testing.expectEqual(@as(usize, 4), utf8CpToByte(s, 2));
    try testing.expectEqual(@as(usize, 5), utf8CpToByte(s, 3));
    // Past the end clamps rather than overruns.
    try testing.expectEqual(s.len, utf8CpToByte(s, 99));
}

test "utf8: firstInvalidUtf8 locates the bad byte" {
    try testing.expectEqual(@as(?usize, null), firstInvalidUtf8("hello " ++ box_v));
    try testing.expectEqual(@as(?usize, null), firstInvalidUtf8(""));

    // Lone continuation byte after three valid ASCII bytes.
    try testing.expectEqual(@as(?usize, 3), firstInvalidUtf8("abc\x80def"));

    // Truncated three-byte sequence at the end of the buffer.
    try testing.expectEqual(@as(?usize, 2), firstInvalidUtf8("ab\xE2\x94"));
}

test "diff: prefixSuffix on a plain single-character edit" {
    const old_text = "hello world";
    const new_text = "hello Xorld";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 6), d.p);
    try testing.expectEqual(@as(usize, 4), d.s);
}

test "diff: prefixSuffix pulls back off a shared multi-byte lead" {
    // Both sides start 0xE2 0x94, so a byte-wise prefix lands 2 bytes
    // into the character. The result must retreat to the boundary or the
    // AT-SPI bridge receives an orphan continuation byte.
    const old_text = "a" ++ box_v ++ "z";
    const new_text = "a" ++ box_t ++ "z";

    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 1), d.p);
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[0..d.p]));
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[d.p .. old_text.len - d.s]));
    try testing.expect(std.unicode.utf8ValidateSlice(new_text[0..d.p]));
}

test "diff: prefixSuffix when old is a prefix of new" {
    // `p` reaches old_text.len; indexing at `p` would be out of bounds.
    const old_text = "abc";
    const new_text = "abcdef";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 3), d.p);
    try testing.expectEqual(@as(usize, 0), d.s);
}

test "diff: prefixSuffix on identical and empty inputs" {
    const same = prefixSuffix("abc", "abc");
    try testing.expectEqual(@as(usize, 3), same.p);
    try testing.expectEqual(@as(usize, 0), same.s);

    const empty = prefixSuffix("", "");
    try testing.expectEqual(@as(usize, 0), empty.p);
    try testing.expectEqual(@as(usize, 0), empty.s);

    const from_empty = prefixSuffix("", "new");
    try testing.expectEqual(@as(usize, 0), from_empty.p);
    try testing.expectEqual(@as(usize, 0), from_empty.s);
}

test "diff: prefix and suffix never overlap" {
    // Without the cap, the common prefix and suffix of "aaaa"/"aa" would
    // both claim the same bytes and the replaced range would go negative.
    const old_text = "aaaa";
    const new_text = "aa";
    const d = prefixSuffix(old_text, new_text);
    try testing.expect(d.p + d.s <= old_text.len);
    try testing.expect(d.p + d.s <= new_text.len);
}

test "diff: scrollK detects a whole-line shift" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";
    // One line scrolled off: K is the byte just past the first newline.
    try testing.expectEqual(@as(usize, 6), scrollK(old_text, new_text));
}

test "diff: scrollK rejects a trailing-newline-only match" {
    // The zero-length remainder at the final `\n` matches trivially; if
    // that were accepted every edit to a newline-terminated buffer would
    // be reported as a scroll.
    const old_text = "abc\n";
    const new_text = "abd\n";
    try testing.expectEqual(@as(usize, 0), scrollK(old_text, new_text));
}

test "diff: scrollK returns 0 with no newline or no match" {
    try testing.expectEqual(@as(usize, 0), scrollK("", "anything"));
    try testing.expectEqual(@as(usize, 0), scrollK("no newlines", "still none"));
    try testing.expectEqual(@as(usize, 0), scrollK("a\nb\n", "totally different"));
}

test "diff: typing echo is cheaper as prefix/suffix than as scroll" {
    // Repeated `$ ` prompts make the last old row a prefix of new, so
    // scroll detection fires spuriously. The caller picks whichever diff
    // emits fewer bytes; assert the sizes make prefix/suffix win.
    const old_text = "$ \n$ \n$ ";
    const new_text = "$ \n$ \n$ x";

    const ps = prefixSuffix(old_text, new_text);
    const ps_total = (old_text.len - ps.p - ps.s) + (new_text.len - ps.p - ps.s);

    const k = scrollK(old_text, new_text);
    const scroll_total = if (k > 0)
        k + (new_text.len - (old_text.len - k))
    else
        std.math.maxInt(usize);

    try testing.expect(ps_total < scroll_total);
}

test "grid: rowColToCp counts codepoints, not bytes" {
    const text = box_v ++ box_v ++ "\nabc";
    // Row 1 begins 7 bytes in but only 3 codepoints in (two box drawing
    // characters plus the newline, which is itself a codepoint). Counting
    // bytes here would report 7 and push every offset off the end.
    try testing.expectEqual(@as(?usize, 3), rowColToCp(text, 1, 0));
    try testing.expectEqual(@as(?usize, 5), rowColToCp(text, 1, 2));
    try testing.expectEqual(@as(?usize, 1), rowColToCp(text, 0, 1));
}

test "grid: rowColToCp clamps column, fails past the last row" {
    const text = "ab\ncd";
    try testing.expectEqual(@as(?usize, 5), rowColToCp(text, 1, 99));
    try testing.expectEqual(@as(?usize, null), rowColToCp(text, 7, 0));
}

test "grid: offsetAtGrid clamps instead of failing" {
    const text = "ab\ncd";
    // Same in-range answers as rowColToCp...
    try testing.expectEqual(@as(c_uint, 3), offsetAtGrid(text, 1, 0));
    // ...but a row past the end resolves into the last row rather than
    // returning nothing.
    try testing.expectEqual(@as(c_uint, 3), offsetAtGrid(text, 7, 0));
    try testing.expectEqual(@as(c_uint, 5), offsetAtGrid(text, 7, 99));
}

test "grid: pointToGrid survives negative and non-finite input" {
    const cw: f32 = 10;
    const ch: f32 = 20;

    try testing.expectEqual(GridPos{ .row = 2, .col = 3 }, pointToGrid(35, 55, cw, ch));

    // Negatives clamp to the origin rather than wrapping through
    // @intFromFloat.
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-500, -500, cw, ch));

    // NaN and both infinities are non-finite, so they take the origin
    // fallback rather than the magnitude guard.
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(nan, nan, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-inf, -inf, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(inf, inf, cw, ch));

    // A finite but absurd magnitude saturates at the guard instead of
    // overflowing the float-to-int conversion.
    const huge = pointToGrid(1e30, 1e30, cw, ch);
    try testing.expectEqual(@as(u32, 1_000_000), huge.row);
    try testing.expectEqual(@as(u32, 1_000_000), huge.col);
}

test "extents: each row reports a distinct row index" {
    const text = "row0\nrow1\nrow2";
    // Flat review collapses to one line if these ever coincide.
    try testing.expectEqual(@as(u32, 0), extentsCells(text, 0, 1).row);
    try testing.expectEqual(@as(u32, 1), extentsCells(text, 5, 6).row);
    try testing.expectEqual(@as(u32, 2), extentsCells(text, 10, 11).row);
}

test "extents: column and width are in cells, not bytes" {
    const text = box_v ++ box_v ++ "abc";
    // Third codepoint sits at column 2 even though it is byte 6.
    const r = extentsCells(text, 2, 5);
    try testing.expectEqual(@as(u32, 0), r.row);
    try testing.expectEqual(@as(u32, 2), r.col);
    try testing.expectEqual(@as(u32, 3), r.width_cols);
}

test "extents: width stops at the row end and never reports zero" {
    const text = "ab\ncdef";
    // Range spans the newline; width covers only the first row.
    const spanning = extentsCells(text, 0, 6);
    try testing.expectEqual(@as(u32, 2), spanning.width_cols);

    // An empty range still reports one cell so the rect is visible.
    const empty = extentsCells(text, 1, 1);
    try testing.expectEqual(@as(u32, 1), empty.width_cols);
}

test "contents: character granularity returns one whole codepoint" {
    const text = "a" ++ box_v ++ "b";
    const c = contentsAt(text, 1, .character);
    try testing.expectEqual(@as(c_uint, 1), c.start_cp);
    try testing.expectEqual(@as(c_uint, 2), c.end_cp);
    try testing.expectEqualStrings(box_v, c.bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(c.bytes));
}

test "contents: character granularity past the end is empty" {
    const text = "abc";
    const c = contentsAt(text, 99, .character);
    try testing.expectEqual(@as(c_uint, 3), c.start_cp);
    try testing.expectEqual(@as(c_uint, 3), c.end_cp);
    try testing.expectEqualStrings("", c.bytes);
}

test "contents: word granularity stops at spaces and newlines" {
    const text = "alpha beta\ngamma";

    const mid = contentsAt(text, 7, .word);
    try testing.expectEqualStrings("beta", mid.bytes);
    try testing.expectEqual(@as(c_uint, 6), mid.start_cp);
    try testing.expectEqual(@as(c_uint, 10), mid.end_cp);

    // A word bounded by a newline rather than a space.
    const after_nl = contentsAt(text, 12, .word);
    try testing.expectEqualStrings("gamma", after_nl.bytes);
    try testing.expectEqual(@as(c_uint, 11), after_nl.start_cp);

    // Sitting on the separator itself walks back to the start of the
    // preceding word and stops immediately going forward, so the offset
    // resolves to the word to its left rather than to an empty range.
    // Pinning this down because it is the boundary case an AT client hits
    // when stepping word-by-word across a line.
    const on_space = contentsAt(text, 5, .word);
    try testing.expectEqualStrings("alpha", on_space.bytes);
    try testing.expectEqual(@as(c_uint, 0), on_space.start_cp);
    try testing.expectEqual(@as(c_uint, 5), on_space.end_cp);
}

test "contents: line granularity includes the trailing newline" {
    const text = "first\nsecond\nthird";

    const first = contentsAt(text, 2, .line);
    try testing.expectEqualStrings("first\n", first.bytes);
    try testing.expectEqual(@as(c_uint, 0), first.start_cp);
    try testing.expectEqual(@as(c_uint, 6), first.end_cp);

    // The final line has no newline to include.
    const last = contentsAt(text, 14, .line);
    try testing.expectEqualStrings("third", last.bytes);
    try testing.expectEqual(@as(c_uint, 13), last.start_cp);
    try testing.expectEqual(@as(c_uint, 18), last.end_cp);
}

test "contents: line granularity with multi-byte rows" {
    const text = box_v ++ box_v ++ "\nabc";
    const second = contentsAt(text, 3, .line);
    try testing.expectEqualStrings("abc", second.bytes);
    // Row 1 begins at codepoint 3 (two box chars plus the newline).
    try testing.expectEqual(@as(c_uint, 3), second.start_cp);
    try testing.expectEqual(@as(c_uint, 6), second.end_cp);
}

test "contents: every granularity yields valid UTF-8 on multi-byte text" {
    // The bridge substitutes the literal "[Invalid UTF-8]" for anything
    // that fails validation, and a screen reader then speaks it.
    const text = box_v ++ " " ++ box_t ++ "x\n😀 tail";
    const cp_count: c_uint = @intCast(utf8CpCount(text));

    var off: c_uint = 0;
    while (off <= cp_count) : (off += 1) {
        for ([_]Granularity{ .character, .word, .line }) |g| {
            const c = contentsAt(text, off, g);
            try testing.expect(std.unicode.utf8ValidateSlice(c.bytes));
            try testing.expect(c.start_cp <= c.end_cp);
            try testing.expect(c.end_cp <= cp_count);
        }
    }
}

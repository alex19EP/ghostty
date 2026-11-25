//! Accessibility support for the Surface class: the GtkAccessibleText
//! and GtkAccessibleHypertext implementations and their state, embedded
//! in the Surface's private data.
//!
//! Every offset crossing this boundary is a UTF-8 codepoint index, never
//! a byte index, per the AT-SPI Text contract. `a11y.offsets` owns that
//! arithmetic; the viewport walk lives in `a11y.text`.
const A11y = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const a11y = @import("../../../a11y/main.zig");
const global = @import("../../../global.zig");
const terminal = @import("../../../terminal/main.zig");
const unicode = @import("../../../unicode/main.zig");
const a11y_hypertext = @import("../a11y_hypertext.zig");
const gtk_version = @import("../gtk_version.zig");
const scale_util = @import("../scale.zig");
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_surface_a11y);

/// The snapshot AT clients read and the baseline for the next event.
/// Hidden surfaces update it on demand without sending events.
cache: a11y.text.Snapshot = .{},

/// False until the first read.
cached: bool = false,

/// The next snapshot is built here and swapped into `cache`.
scratch: a11y.text.Snapshot = .{},

/// Set on the first AT read and never cleared, since GTK does not tell
/// us when clients go away. Frames are only checked while set.
active: bool = false,

/// A frame could not be checked, so the next read rebuilds the cache.
cache_stale: bool = false,

check_source: ?c_uint = null,

/// Prevents synchronous reads during notifications from rebuilding the cache.
emitting: bool = false,

/// When the oldest frame GTK has not painted yet was pushed, in
/// `glib.getMonotonicTime` microseconds.
unpainted_since: ?i64 = null,

/// The current selection in viewport cells and whether caret mode is active.
selection: ?SelRaw = null,
caret_mode: bool = false,

/// Non-default style runs over the cached text, rebuilt with it. Gaps
/// between runs are default-styled.
style_runs: std.ArrayList(StyleRun) = .empty,

/// Links in the cached text, rebuilt with it. Only populated when
/// `a11y_hypertext.available` (GTK >= 4.22). Each owns its URI and,
/// once a client has asked for it, a strong reference on its hyperlink
/// object.
links: std.ArrayList(Link) = .empty,

/// The previous refresh's `links`, held only for the duration of a
/// `refreshCache` so `Sink.commitLink` can reuse unchanged hyperlinks
/// in place. Rebuilding every hyperlink on every refresh was the cause
/// of a use-after-free: Orca queues `GetLink(idx)` from an older frame's
/// link count, and a hyperlink freed before that query dispatches made
/// GTK's bridge crash in `gtk_accessible_get_at_context`, taking Orca
/// with it. Empty outside a refresh.
links_prev: std.ArrayList(Link) = .empty,

/// Configured regex link matches per row of text, so a refresh only
/// runs the patterns on rows that changed.
regex_links: a11y.text.RegexLinkCache = .{},

/// How many `links_prev` entries were reused this refresh. Reuse is
/// positional, so this only grows.
links_prev_consumed: usize = 0,

/// Set once a refresh hits a link that differs from the previous one at
/// the same index. The rest of `links_prev` is disposed on the spot and
/// no further reuse is attempted.
links_prev_frozen: bool = false,

/// An inert, empty hyperlink returned when a client asks for a link
/// index past the end. That happens: Orca queues `GetLink(idx)` after a
/// `GetNLinks` that reported more, and the link set can shrink before
/// the query dispatches. GTK's bridge serializes our return value with
/// no null check, so neither NULL nor an out-of-bounds read is survivable.
/// Created on first use.
link_sentinel: ?*a11y_hypertext.AccessibleHyperlink = null,

/// A pushed frame pending this long indicates GTK has stopped painting.
const unpainted_after_us = 250 * std.time.us_per_ms;

/// A half-open codepoint range.
pub const Range = struct {
    start: c_uint,
    end: c_uint,
};

pub const Link = struct {
    range: Range,
    uri: [:0]u8,

    /// Made and parented by `getLink` the first time a client asks for
    /// this link. Realizing a hyperlink's AT context is the expensive
    /// part, and while output scrolls the links are replaced every frame,
    /// so making one for every link up front cost more than finding them.
    /// A client that knows links are in text order only asks for the few
    /// it needs.
    obj: ?*a11y_hypertext.AccessibleHyperlink = null,
};

/// A maximal run of codepoints sharing one non-default style.
pub const StyleRun = struct {
    range: Range,
    style: terminal.Style,
};

/// Selection bounds in raw viewport cells, as the probe reads them.
const SelRaw = struct {
    tl: terminal.point.Coordinate,
    br: terminal.point.Coordinate,
};

pub fn deinit(self: *A11y, alloc: Allocator) void {
    if (self.check_source) |id| _ = glib.Source.remove(id);
    // `links_prev` is empty outside a refresh, but drain it anyway in case
    // a refresh was interrupted.
    clearLinks(&self.links, alloc);
    self.links.deinit(alloc);
    disposeLinksFrom(&self.links_prev, 0, alloc);
    self.links_prev.deinit(alloc);
    if (self.link_sentinel) |s| unparentAndUnref(s);
    self.regex_links.deinit(alloc);
    self.style_runs.deinit(alloc);
    self.cache.deinit(alloc);
    self.scratch.deinit(alloc);
    self.* = .{};
}

/// Called from GTK's paint after each frame. Schedules a check for
/// changes to send to AT clients. Frames painted before it runs share
/// one check.
///
/// The check runs on every surface, not just the focused one, so that
/// output in other splits is announced too.
pub fn frameRendered(self: *A11y, surface: *Surface) void {
    self.unpainted_since = null;
    if (!self.active or self.check_source != null) return;

    // The same priority as D-Bus, so a busy bus does not delay it.
    self.check_source = glib.idleAddFull(
        glib.PRIORITY_DEFAULT,
        checkFrame,
        surface,
        null,
    );
}

/// Called when the renderer pushes a frame. GTK can stop painting a
/// window without unmapping it, for example an X11 window unmapped by
/// the window manager. Frames that are pushed but not painted show that.
pub fn framePushed(self: *A11y) void {
    if (self.unpainted_since == null) self.unpainted_since = glib.getMonotonicTime();
}

/// Whether GTK paints our frames, so every change gets checked.
fn painted(self: *const A11y, surface: *Surface) bool {
    if (!surface.isPainted()) return false;
    const since = self.unpainted_since orelse return true;
    return glib.getMonotonicTime() - since < unpainted_after_us;
}

fn checkFrame(ud: ?*anyopaque) callconv(.c) c_int {
    const surface: *Surface = @ptrCast(@alignCast(ud orelse return 0));
    const self = surface.a11y();
    self.check_source = null;
    if (self.cached and self.painted(surface)) _ = self.updateSnapshot(surface, true);
    return 0;
}

//---------------------------------------------------------------
// GtkAccessibleText interface implementation

/// Install the parts of GtkAccessibleText this surface implements.
/// Slots left alone keep GTK's `default_init` implementations, which
/// decline gracefully.
pub fn initAccessibleTextInterface(iface: *gtk.AccessibleTextInterface) callconv(.c) void {
    iface.f_get_contents = &getContents;
    iface.f_get_contents_at = &getContentsAt;
    iface.f_get_caret_position = &getCaretPosition;
    iface.f_get_selection = &getSelection;
    iface.f_get_attributes = &getAttributes;
    iface.f_get_default_attributes = &getDefaultAttributes;
    iface.f_get_extents = &getExtents;
    iface.f_get_offset = &getOffset;

    // Only install later slots when the runtime vtable has room for them.
    if (gtk_version.runtimeAtLeast(4, 22, 0)) {
        iface.f_set_caret_position = &setCaretPosition;
        iface.f_set_selection = &setSelection;
    }
}

/// Return the extents of a text range, in widget coordinates (see
/// `deviceScale`). Orca's flat review groups text into lines by Y
/// coordinate, so each viewport row needs a distinct rect:
/// Y = row * cell_height.
fn getExtents(
    accessible: *gtk.AccessibleText,
    start: c_uint,
    end: c_uint,
    extents: *graphene.Rect,
) callconv(.c) c_int {
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    const core_surface = surface.core() orelse return 0;

    const text = self.refreshCache(surface) orelse return 0;

    const cell_w: f32 = @floatFromInt(core_surface.size.cell.width);
    const cell_h: f32 = @floatFromInt(core_surface.size.cell.height);
    if (cell_w <= 0 or cell_h <= 0) return 0;

    const rect = a11y.offsets.extentsCells(text, self.cellWidths(), start, end);
    const scale = deviceScale(surface);

    // Cell (0,0) is not at widget-local (0,0): the renderer leaves a
    // padding gutter that has to be added back here.
    const pad_left: f32 = @floatFromInt(core_surface.size.padding.left);
    const pad_top: f32 = @floatFromInt(core_surface.size.padding.top);

    extents.f_origin.f_x =
        (pad_left + @as(f32, @floatFromInt(rect.col)) * cell_w) / scale;
    extents.f_origin.f_y =
        (pad_top + @as(f32, @floatFromInt(rect.row)) * cell_h) / scale;
    extents.f_size.f_width =
        @as(f32, @floatFromInt(rect.width_cols)) * cell_w / scale;
    extents.f_size.f_height = cell_h / scale;
    return 1;
}

/// Device pixels per widget pixel: `core_surface.size` is in device
/// pixels, GTK accessibility coordinates are widget space. This is the
/// same (possibly fractional) surface scale the render surface sizes
/// itself with; the integer `getScaleFactor` rounds 1.25 up to 2. Not
/// `getContentScale`, which folds in the gtk-xft-dpi font scale.
fn deviceScale(surface: *Surface) f32 {
    return @floatCast(scale_util.widgetSurfaceScale(surface.as(gtk.Widget)));
}

/// Map a widget-space point to a codepoint offset within the cached
/// text. Inverse of `getExtents`. Out-of-range points clamp, so the
/// AT client always gets an in-range offset when we return TRUE.
fn getOffset(
    accessible: *gtk.AccessibleText,
    point: *const graphene.Point,
    out_offset: *c_uint,
) callconv(.c) c_int {
    const surface = gobject.ext.cast(Surface, accessible) orelse {
        out_offset.* = 0;
        return 0;
    };
    const self = surface.a11y();
    const core_surface = surface.core() orelse {
        out_offset.* = 0;
        return 0;
    };

    const text = self.refreshCache(surface) orelse {
        out_offset.* = 0;
        return 0;
    };

    const cell_w: f32 = @floatFromInt(core_surface.size.cell.width);
    const cell_h: f32 = @floatFromInt(core_surface.size.cell.height);
    if (cell_w <= 0 or cell_h <= 0) {
        out_offset.* = 0;
        return 0;
    }

    // Exact inverse of `getExtents`: back into device pixels, then out
    // of the renderer's gutter. `pointToGrid` clamps negatives to cell
    // (0,0), so a point inside the padding lands on the first cell.
    const scale = deviceScale(surface);
    const pad_left: f32 = @floatFromInt(core_surface.size.padding.left);
    const pad_top: f32 = @floatFromInt(core_surface.size.padding.top);
    const grid = a11y.offsets.pointToGrid(
        point.f_x * scale - pad_left,
        point.f_y * scale - pad_top,
        cell_w,
        cell_h,
    );
    out_offset.* = @intCast(a11y.offsets.offsetAtGrid(
        text,
        self.cellWidths(),
        grid.row,
        grid.col,
    ));
    return 1;
}

fn cellWidths(self: *const A11y) a11y.offsets.CellWidths {
    return self.cache.cellWidths();
}

/// A hidden surface can keep receiving terminal output between reads.
fn refreshCache(self: *A11y, surface: *Surface) ?[]const u8 {
    self.active = true;
    if (self.emitting) return self.cache.text.items;
    if (!self.cached or self.cache_stale or
        (self.check_source == null and !self.painted(surface)))
    {
        if (!self.updateSnapshot(surface, false)) return null;
    }
    return self.cache.text.items;
}

/// Build once under the renderer lock. Collect styles and OSC 8 links
/// from its pins only when replacing the cache. Regex matching and GTK
/// object operations run after releasing the lock.
fn updateSnapshot(self: *A11y, surface: *Surface, notify: bool) bool {
    const core_surface = surface.core() orelse return false;
    const alloc = Application.default().allocator();
    const track_links = a11y_hypertext.available;
    var sink: Sink = .{ .a11y = self, .alloc = alloc };
    defer sink.deinit();

    const selection, const caret_mode = snapshot: {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        const screen = core_surface.renderer_state.terminal.screens.active;

        a11y.text.build(alloc, &self.scratch, screen) catch |err| {
            log.warn("ax text build failed: {}", .{err});
            self.cache_stale = true;
            return false;
        };
        self.cache_stale = false;

        const selection = selectionRaw(screen);
        if (self.cached and self.cache.eql(&self.scratch) and
            std.meta.eql(self.selection, selection) and self.caret_mode == screen.caret_mode)
        {
            return true;
        }

        self.style_runs.clearRetainingCapacity();
        a11y.text.collectRanges(&self.scratch, &sink, track_links);
        break :snapshot .{ selection, screen.caret_mode };
    };

    self.emitting = true;
    defer self.emitting = false;

    assert(self.links_prev.items.len == 0);
    assert(self.links_prev_consumed == 0);
    assert(!self.links_prev_frozen);
    self.links_prev = self.links;
    self.links = .empty;

    // Like Ctrl-hover, the regex pass is on demand. OSC 8 links are
    // collected in every mode.
    if (track_links and caret_mode) self.regex_links.apply(
        alloc,
        self.scratch.text.items,
        core_surface.config.links,
        &sink,
    );
    sink.finishLinks();
    self.finalizeLinksPrev(alloc);

    const old_selection = self.selectionRange(self.selection);
    self.selection = selection;
    self.caret_mode = caret_mode;
    self.cached = true;
    std.mem.swap(a11y.text.Snapshot, &self.cache, &self.scratch);

    if (notify) {
        const accessible = surface.as(gtk.AccessibleText);
        self.emitTextDiff(surface, self.scratch.text.items, self.cache.text.items);
        if (self.cache.caret != self.scratch.caret) {
            gtk.AccessibleText.updateCaretPosition(accessible);
        }
        if (!std.meta.eql(old_selection, self.selectionRange(selection))) {
            gtk.AccessibleText.updateSelectionBound(accessible);
        }
    }
    return true;
}

/// Collect style ranges and stage hyperlinks for adoption outside the
/// renderer lock.
const Sink = struct {
    a11y: *A11y,
    alloc: Allocator,

    /// Links found so far, in discovery order: the walk's OSC 8 runs,
    /// then the regex matches. `finishLinks` turns them into `A11y.links`
    /// in offset order.
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        range: Range,
        uri: [:0]u8,
    };

    /// Record a link range. Only copies it: the hyperlink objects are made
    /// in `finishLinks`, once every link is known, because their indices
    /// have to follow text order. Allocation failure drops the link, which
    /// degrades to plain text.
    pub fn commitLink(self: *Sink, start_cp: usize, end_cp: usize, uri: []const u8) void {
        if (start_cp >= end_cp) return;

        const uri_owned = self.alloc.dupeSentinel(u8, uri, 0) catch |err| {
            log.warn("ax link uri dup failed: {}", .{err});
            return;
        };
        self.pending.append(self.alloc, .{
            .range = .{ .start = @intCast(start_cp), .end = @intCast(end_cp) },
            .uri = uri_owned,
        }) catch |err| {
            log.warn("ax link append failed: {}", .{err});
            self.alloc.free(uri_owned);
        };
    }

    /// Sort the pending links by start offset and add them to
    /// `A11y.links`, so link index order is text order. The walk commits OSC 8
    /// links before the regex pass adds its matches, and each configured
    /// regex adds its own sorted run, so discovery order is not text
    /// order once a screen mixes them. Orca relies on text order to find
    /// the links in a range without reading every link's offsets, one
    /// D-Bus round trip each, on every spoken insertion. The sort is
    /// stable, so links starting at the same offset keep discovery order.
    fn finishLinks(self: *Sink) void {
        std.mem.sort(Pending, self.pending.items, {}, struct {
            fn lessThan(_: void, a: Pending, b: Pending) bool {
                return a.range.start < b.range.start;
            }
        }.lessThan);
        for (self.pending.items) |link| self.adoptLink(link);
        // Every entry's URI now belongs to `A11y.links` or was freed.
        self.pending.clearRetainingCapacity();
    }

    fn deinit(self: *Sink) void {
        for (self.pending.items) |link| self.alloc.free(link.uri);
        self.pending.deinit(self.alloc);
    }

    /// Append `link` to `A11y.links`, taking ownership of its URI. When the
    /// previous refresh had an identical link at the same index its
    /// hyperlink object, if it has one, is moved over as is, keeping its
    /// AT-SPI bus path alive across the frame. Reuse is by index because a
    /// hyperlink's index is construct-only.
    fn adoptLink(self: *Sink, link: Pending) void {
        const state = self.a11y;
        const range = link.range;
        const uri_owned = link.uri;
        const target_idx = state.links.items.len;

        if (!state.links_prev_frozen and target_idx < state.links_prev.items.len) reuse: {
            const candidate = state.links_prev.items[target_idx];
            if (std.meta.eql(candidate.range, range) and
                std.mem.eql(u8, candidate.uri, uri_owned))
            {
                state.links.append(self.alloc, candidate) catch |err| {
                    log.warn("ax link append failed: {}", .{err});
                    break :reuse;
                };
                state.links_prev_consumed = target_idx + 1;
                self.alloc.free(uri_owned);
                return;
            }

            // Fall through to a new link, and dispose the rest of the
            // previous set now so the old object at this index doesn't
            // shadow the new one on the bus.
        }
        if (target_idx < state.links_prev.items.len) {
            state.links_prev_frozen = true;
            disposeLinksFrom(&state.links_prev, state.links_prev_consumed, self.alloc);
        }

        // No hyperlink object yet; `getLink` makes it when asked.
        state.links.append(self.alloc, .{
            .range = range,
            .uri = uri_owned,
        }) catch |err| {
            log.warn("ax link append failed: {}", .{err});
            self.alloc.free(uri_owned);
        };
    }

    /// Record a style run. Allocation failure drops it, which degrades
    /// to "announced without attributes".
    pub fn commitStyleRun(self: *Sink, start_cp: usize, end_cp: usize, style: terminal.Style) void {
        self.a11y.style_runs.append(self.alloc, .{
            .range = .{ .start = @intCast(start_cp), .end = @intCast(end_cp) },
            .style = style,
        }) catch {};
    }

    pub fn committedLinkCount(self: *Sink) usize {
        return self.pending.items.len;
    }

    /// Whether `[start_cp, end_cp)` intersects any of the first `limit`
    /// links. `limit` is clamped because a failed commit can leave the
    /// list shorter than the caller's snapshot of its length.
    pub fn linkOverlaps(self: *Sink, start_cp: usize, end_cp: usize, limit: usize) bool {
        const links = self.pending.items;
        for (links[0..@min(limit, links.len)]) |existing| {
            if (start_cp < existing.range.end and
                end_cp > existing.range.start) return true;
        }
        return false;
    }
};

/// Unparent, then unref. The order matters: an unparented hyperlink
/// tears down its AT context and leaves the bus. Unreffed while still
/// parented, it is freed while the bridge keeps its bus path pointing at
/// it, and the next call on that path crashes the bridge and Orca.
fn unparentAndUnref(obj: *a11y_hypertext.AccessibleHyperlink) void {
    const accessible: *gtk.Accessible = @ptrCast(@alignCast(obj));
    accessible.setAccessibleParent(null, null);
    obj.unref();
}

/// Release every link in `list` and empty it.
fn clearLinks(list: *std.ArrayList(Link), alloc: Allocator) void {
    disposeLinksFrom(list, 0, alloc);
}

/// Release the links in `list` from index `from` onwards and truncate it
/// there. A second call with the same `from` is a no-op.
fn disposeLinksFrom(list: *std.ArrayList(Link), from: usize, alloc: Allocator) void {
    if (from >= list.items.len) return;
    for (list.items[from..]) |link| {
        if (link.obj) |obj| unparentAndUnref(obj);
        alloc.free(link.uri);
    }
    list.shrinkRetainingCapacity(from);
}

/// End-of-refresh cleanup: dispose the previous links that weren't
/// reused and reset the reuse state for the next refresh.
fn finalizeLinksPrev(self: *A11y, alloc: Allocator) void {
    disposeLinksFrom(&self.links_prev, self.links_prev_consumed, alloc);
    self.links_prev.clearAndFree(alloc);
    self.links_prev_consumed = 0;
    self.links_prev_frozen = false;
}

/// The selection's bounds in viewport cells, or null if there is none
/// or either end is outside the viewport. Caller holds the renderer
/// mutex.
fn selectionRaw(screen: *terminal.Screen) ?SelRaw {
    const sel = screen.selection orelse return null;
    const tl = screen.pages.pointFromPin(.viewport, sel.topLeft(screen)) orelse return null;
    const br = screen.pages.pointFromPin(.viewport, sel.bottomRight(screen)) orelse return null;
    return .{ .tl = tl.viewport, .br = br.viewport };
}

/// Map a selection in viewport cells to the cached text.
fn selectionRange(self: *const A11y, selection: ?SelRaw) ?Range {
    const raw = selection orelse return null;
    const text = self.cache.text.items;
    const widths = self.cellWidths();
    const start = a11y.offsets.rowColToCp(text, widths, raw.tl.y, raw.tl.x) orelse return null;
    const end = (a11y.offsets.rowColToCp(text, widths, raw.br.y, raw.br.x) orelse return null) + 1;
    if (end <= start) return null;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// GTK reads the removed text synchronously, so expose the old snapshot
/// for the duration of the removal.
fn emitRemoval(self: *A11y, accessible: *gtk.AccessibleText, start: c_uint, end: c_uint) void {
    std.mem.swap(a11y.text.Snapshot, &self.cache, &self.scratch);
    defer std.mem.swap(a11y.text.Snapshot, &self.cache, &self.scratch);
    gtk.AccessibleText.updateContents(accessible, .remove, start, end);
}

/// Prefix/suffix diff: bytes `[0..p)` and `[len-s..)` are unchanged,
/// the rest was replaced, with both cuts on codepoint boundaries.
const PrefixSuffixDiff = a11y.offsets.PrefixSuffixDiff;

/// Fire the AT-SPI events for the change from `old_text` to
/// `new_text`. `chooseDiff` owns the shape choice (pure arithmetic,
/// unit-tested). A line shift is a `.remove` at one end plus an
/// `.insert` at the other, matching what VTE exposes to Orca; a
/// whole-viewport replacement would be re-read in full on every scroll.
fn emitTextDiff(self: *A11y, surface: *Surface, old_text: []const u8, new_text: []const u8) void {
    switch (a11y.offsets.chooseDiff(old_text, new_text)) {
        .none => {},
        .shift_up => |k| self.emitShiftUp(surface, old_text, new_text, k),
        .shift_down => |j| self.emitShiftDown(surface, old_text, new_text, j),
        .replace => |ps| self.emitPrefixSuffix(surface, old_text, new_text, ps),
    }
}

/// Emit `.remove(0, K_cp)` + `.insert(tail_cp, |new|_cp)` for an
/// upward line shift. `scroll_k` is > 0 and lands on a `\n` boundary
/// of `old` (guaranteed by `chooseDiff`).
fn emitShiftUp(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    scroll_k: usize,
) void {
    const accessible = surface.as(gtk.AccessibleText);

    const removed_cp: c_uint = @intCast(utf8CpCount(old_text[0..scroll_k]));
    const tail_cp: c_uint = @intCast(utf8CpCount(old_text[scroll_k..]));
    const new_end_cp: c_uint = @intCast(utf8CpCount(new_text));

    // The bridge reads the deleted range back out of us synchronously,
    // so the cache must point at the pre-remove text for the call.
    self.emitRemoval(accessible, 0, removed_cp);

    if (new_end_cp > tail_cp) {
        gtk.AccessibleText.updateContents(accessible, .insert, tail_cp, new_end_cp);
    }
}

/// Emit `.remove(kept_cp, |old|_cp)` + `.insert(0, J_cp)` for a
/// downward line shift (scrolling back through output). Remove first:
/// after it the exposed text is exactly `new[scroll_j..]`, so the
/// insert offset needs no adjustment.
fn emitShiftDown(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    scroll_j: usize,
) void {
    const accessible = surface.as(gtk.AccessibleText);

    // Bytes of `old` that survive the shift. `chooseDiff` guarantees
    // `old_text[0..kept] == new_text[scroll_j..]`.
    const kept = new_text.len - scroll_j;
    const kept_cp: c_uint = @intCast(utf8CpCount(old_text[0..kept]));
    const old_end_cp: c_uint = @intCast(utf8CpCount(old_text));
    const inserted_cp: c_uint = @intCast(utf8CpCount(new_text[0..scroll_j]));

    if (old_end_cp > kept_cp) {
        self.emitRemoval(accessible, kept_cp, old_end_cp);
    }

    gtk.AccessibleText.updateContents(accessible, .insert, 0, inserted_cp);
}

/// Emit a single remove+insert pair covering the region between the
/// common prefix and common suffix of `old` and `new`.
fn emitPrefixSuffix(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    diff: PrefixSuffixDiff,
) void {
    const p = diff.prefix_len;
    const s = diff.suffix_len;
    const removed_len = old_text.len - p - s;
    const inserted_len = new_text.len - p - s;

    const accessible = surface.as(gtk.AccessibleText);
    const start_cp: c_uint = @intCast(utf8CpCount(old_text[0..p]));
    if (removed_len != 0) {
        const end_cp: c_uint = @intCast(utf8CpCount(old_text[0..(old_text.len - s)]));
        self.emitRemoval(accessible, start_cp, end_cp);
    }
    if (inserted_len != 0) {
        const end_cp: c_uint = @intCast(utf8CpCount(new_text[0..(new_text.len - s)]));
        gtk.AccessibleText.updateContents(accessible, .insert, start_cp, end_cp);
    }
}

fn getContents(
    accessible: *gtk.AccessibleText,
    start: c_uint,
    end: c_uint,
) callconv(.c) *glib.Bytes {
    const surface = gobject.ext.cast(Surface, accessible) orelse return emptyBytes();
    const self = surface.a11y();
    const text = self.refreshCache(surface) orelse return emptyBytes();

    // `start`/`end` are codepoint indices per the AT-SPI Text
    // contract; convert to byte offsets before slicing so the result
    // is valid UTF-8.
    const byte_start = utf8CpToByte(text, @intCast(start));
    const byte_end = utf8CpToByte(text, @intCast(end));
    if (byte_start >= byte_end) return emptyBytes();

    return bytesNulTerm(text[byte_start..byte_end]);
}

/// A NUL-terminated empty `GBytes`. A string literal points at static
/// storage; `&[_:0]u8{}` looks equivalent but is only valid for the
/// enclosing scope and can dangle by the time `g_bytes_new` copies it.
fn emptyBytes() *glib.Bytes {
    return glib.Bytes.new("", 1);
}

/// Wrap `slice` in a freshly-allocated, NUL-terminated `GBytes`.
/// GTK's bridge hands the payload to `g_variant_new_string`, which
/// needs NUL termination (despite the `get_contents` docs) or it reads
/// past the allocation, and returns NULL on invalid UTF-8, crashing the
/// AT-SPI bridge — so broken input becomes an empty result instead.
fn bytesNulTerm(slice: []const u8) *glib.Bytes {
    if (!std.unicode.utf8ValidateSlice(slice)) {
        log.warn("accessibility text is not valid UTF-8, ignoring", .{});
        return emptyBytes();
    }

    const alloc = Application.default().allocator();
    const buf = alloc.dupeSentinel(u8, slice, 0) catch return emptyBytes();
    defer alloc.free(buf);
    // g_bytes_new copies, so `buf` can be freed when this returns.
    return glib.Bytes.new(buf.ptr, slice.len + 1);
}

// UTF-8 codepoint offset helpers; `unicode.utf8` owns the arithmetic
// and the tests that pin it down.
const utf8CpCount = unicode.utf8.cpCount;
const utf8CpToByte = unicode.utf8.cpToByte;

fn getContentsAt(
    accessible: *gtk.AccessibleText,
    offset: c_uint,
    granularity: gtk.AccessibleTextGranularity,
    out_start: *c_uint,
    out_end: *c_uint,
) callconv(.c) *glib.Bytes {
    const surface = gobject.ext.cast(Surface, accessible) orelse {
        out_start.* = 0;
        out_end.* = 0;
        return emptyBytes();
    };
    const self = surface.a11y();
    const text = self.refreshCache(surface) orelse {
        out_start.* = 0;
        out_end.* = 0;
        return emptyBytes();
    };

    // A terminal has no sentences or paragraphs distinct from its
    // visual rows, so both fold into `.line`. Unknown values (the
    // non-exhaustive `_`) get an empty range at the requested offset.
    const g: a11y.offsets.Granularity = switch (granularity) {
        .character => .character,
        .word => .word,
        .line, .paragraph, .sentence => .line,
        _ => {
            const text_cp_count: c_uint = @intCast(utf8CpCount(text));
            const off_cp = @min(offset, text_cp_count);
            out_start.* = off_cp;
            out_end.* = off_cp;
            return emptyBytes();
        },
    };

    const contents = a11y.offsets.contentsAt(text, offset, g);
    out_start.* = @intCast(contents.start_cp);
    out_end.* = @intCast(contents.end_cp);
    if (contents.bytes.len == 0) return emptyBytes();
    return bytesNulTerm(contents.bytes);
}

fn getCaretPosition(
    accessible: *gtk.AccessibleText,
) callconv(.c) c_uint {
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    _ = self.refreshCache(surface);
    return @intCast(self.cache.caret);
}

/// Move the caret to `offset` (GTK 4.22+). A terminal has no caret an
/// AT client can set directly, since the shell owns the cursor, so this
/// clicks the cell at `offset`. With shell integration that click moves
/// the prompt cursor (`Surface.maybePromptClick`); elsewhere it is a
/// benign click that selects nothing. This is what braille cursor
/// routing keys arrive as.
fn setCaretPosition(
    accessible: *gtk.AccessibleText,
    offset: c_uint,
) callconv(.c) c_int {
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    const core_surface = surface.core() orelse return 0;

    const text = self.refreshCache(surface) orelse return 0;

    // Clamp to the last codepoint rather than past-the-end so the cell
    // lookup below always lands on a real cell.
    const text_cp_count = utf8CpCount(text);
    const off_cp: usize = if (text_cp_count == 0) 0 else @min(offset, text_cp_count - 1);

    // A codepoint offset is not a column: a double-width character earlier
    // on the row takes two, and clicking as though it took one lands on
    // the wrong word.
    const cell = a11y.offsets.cpToGrid(text, self.cellWidths(), off_cp);

    const cell_w: f32 = @floatFromInt(core_surface.size.cell.width);
    const cell_h: f32 = @floatFromInt(core_surface.size.cell.height);
    if (cell_w <= 0 or cell_h <= 0) return 0;

    // The cell's center, in the device pixels the core's mouse handling
    // works in (no widget scale here), past the renderer's padding gutter.
    // Without the gutter the click lands in the padding, and nvim, like
    // any mouse-reporting program, silently ignores it.
    const pad_left: f32 = @floatFromInt(core_surface.size.padding.left);
    const pad_top: f32 = @floatFromInt(core_surface.size.padding.top);
    surface.synthesizeClick(.{
        .x = pad_left + @as(f32, @floatFromInt(cell.col)) * cell_w + cell_w / 2.0,
        .y = pad_top + @as(f32, @floatFromInt(cell.row)) * cell_h + cell_h / 2.0,
    }) catch |err| {
        log.warn("ax set caret position click failed err={}", .{err});
        return 0;
    };
    return 1;
}

/// Report the terminal's selection, if any, as one range. See
/// `selectionRange` for when one can't be reported.
fn getSelection(
    accessible: *gtk.AccessibleText,
    n_ranges: *usize,
    out_ranges: ?*[*]gtk.AccessibleTextRange,
) callconv(.c) c_int {
    n_ranges.* = 0;
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    _ = self.refreshCache(surface) orelse return 0;

    // A client can read back its selection before the next frame.
    const selection = if (self.emitting) self.selection else selection: {
        const core_surface = surface.core() orelse return 0;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        break :selection selectionRaw(core_surface.renderer_state.terminal.screens.active);
    };
    const range = self.selectionRange(selection) orelse return 0;

    // Transfer-container: the caller frees the array with `g_free`.
    if (out_ranges) |out| {
        const ranges: [*]gtk.AccessibleTextRange = @ptrCast(@alignCast(
            glib.malloc(@sizeOf(gtk.AccessibleTextRange)),
        ));
        ranges[0] = .{ .f_start = range.start, .f_length = range.end - range.start };
        out.* = ranges;
    }
    n_ranges.* = 1;
    return 1;
}

/// Select a codepoint range of the snapshot (GTK 4.22+); an empty range
/// clears the selection. Only selection 0 exists.
fn setSelection(
    accessible: *gtk.AccessibleText,
    i: usize,
    range: *gtk.AccessibleTextRange,
) callconv(.c) c_int {
    if (i != 0) return 0;

    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    const core_surface = surface.core() orelse return 0;

    const text = self.refreshCache(surface) orelse return 0;
    const text_cp_count = utf8CpCount(text);

    if (range.f_length == 0) {
        {
            core_surface.renderer_state.mutex.lockUncancelable(global.io());
            defer core_surface.renderer_state.mutex.unlock(global.io());
            core_surface.renderer_state.terminal.screens.active.clearSelection();
        }
        surface.redraw();
        return 1;
    }

    // The range comes from another process, so saturate rather than wrap.
    const start_cp = @min(range.f_start, text_cp_count);
    const end_cp = @min(std.math.add(usize, range.f_start, range.f_length) catch
        text_cp_count, text_cp_count);
    if (end_cp <= start_cp) return 0;

    // The selection's end cell is inclusive; the range is not.
    const widths = self.cellWidths();
    const start = a11y.offsets.cpToGrid(text, widths, start_cp);
    const end = a11y.offsets.cpToGrid(text, widths, end_cp - 1);

    {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen: *terminal.Screen = core_surface.renderer_state.terminal.screens.active;
        if (screen.pages.cols == 0) return 0;
        const max_col = screen.pages.cols - 1;
        const start_pin = screen.pages.pin(.{ .viewport = .{
            .x = @intCast(@min(start.col, max_col)),
            .y = start.row,
        } }) orelse return 0;
        const end_pin = screen.pages.pin(.{ .viewport = .{
            .x = @intCast(@min(end.col, max_col)),
            .y = end.row,
        } }) orelse return 0;

        screen.select(terminal.Selection.init(start_pin, end_pin, false)) catch |err| {
            log.warn("ax set selection failed err={}", .{err});
            return 0;
        };
    }

    // Paint the highlight.
    surface.redraw();
    return 1;
}

/// The most attributes `getAttributes` reports for one run.
const max_attributes = 16;

/// Report the SGR attributes of the style run containing `offset`, with
/// the run's whole range so clients don't re-query once per character.
/// Ownership follows `get_default_attributes`: `ranges` is
/// transfer-container (`g_free`), the name and value arrays are
/// NULL-terminated and freed with `g_strfreev`.
///
/// Standard AT-SPI attribute names where one exists; terminal-only ones
/// get a `ghostty-` prefix so clients that don't know them won't read
/// them as standard attributes.
fn getAttributes(
    accessible: *gtk.AccessibleText,
    offset: c_uint,
    n_ranges: *usize,
    out_ranges: ?*[*]gtk.AccessibleTextRange,
    out_names: ?*[*][*:0]u8,
    out_values: ?*[*][*:0]u8,
) callconv(.c) c_int {
    n_ranges.* = 0;
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    const core_surface = surface.core() orelse return 0;

    _ = self.refreshCache(surface) orelse return 0;

    const run: StyleRun = for (self.style_runs.items) |r| {
        if (offset >= r.range.start and offset < r.range.end) break r;
    } else return 0;

    // Resolve palette colors to the RGB the user sees. The palette can
    // change under OSC 4, so read it under the renderer mutex.
    const Colors = struct {
        fg: ?terminal.color.RGB,
        bg: ?terminal.color.RGB,
        underline: ?terminal.color.RGB,
    };
    const colors: Colors = colors: {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        const palette = &core_surface.renderer_state.terminal.colors.palette.current;
        break :colors .{
            .fg = resolveColor(run.style.fg_color, palette),
            .bg = resolveColor(run.style.bg_color, palette),
            .underline = resolveColor(run.style.underline_color, palette),
        };
    };

    var attrs: Attributes = .{};
    if (colors.fg) |rgb| attrs.addColor("fg-color", rgb);
    if (colors.bg) |rgb| attrs.addColor("bg-color", rgb);

    const flags = run.style.flags;
    // Faint reports as a light weight so clients that key on "weight"
    // still see it; `ghostty-faint` below keeps it distinct from a
    // configured light font.
    if (flags.bold) attrs.add("weight", "700") else if (flags.faint) attrs.add("weight", "300");
    if (flags.italic) attrs.add("style", "italic");
    switch (flags.underline) {
        .none => {},
        // AT-SPI only knows none/single/double/error.
        .single, .curly, .dotted, .dashed => attrs.add("underline", "single"),
        .double => attrs.add("underline", "double"),
    }
    if (flags.overline) attrs.add("overline", "single");
    if (flags.strikethrough) attrs.add("strikethrough", "true");
    if (flags.faint) attrs.add("ghostty-faint", "true");
    if (flags.blink) attrs.add("ghostty-blink", "true");
    if (flags.inverse) attrs.add("ghostty-inverse", "true");
    if (flags.invisible) attrs.add("ghostty-invisible", "true");
    if (colors.underline) |rgb| attrs.addColor("ghostty-underline-color", rgb);

    if (attrs.count == 0) return 0;

    if (out_ranges) |out| {
        const ranges: [*]gtk.AccessibleTextRange = @ptrCast(@alignCast(
            glib.malloc(@sizeOf(gtk.AccessibleTextRange)),
        ));
        ranges[0] = .{
            .f_start = run.range.start,
            .f_length = run.range.end - run.range.start,
        };
        out.* = ranges;
    }
    attrs.transfer(out_names, out_values);
    n_ranges.* = 1;
    return 1;
}

fn resolveColor(
    color: terminal.Style.Color,
    palette: *const terminal.color.Palette,
) ?terminal.color.RGB {
    return switch (color.value()) {
        .none => null,
        .palette => |idx| palette[idx],
        .rgb => |rgb| rgb,
    };
}

/// Attribute name/value pairs being collected for a GTK caller, as
/// `g_strdup`'d strings it will own.
const Attributes = struct {
    names: [max_attributes][*:0]u8 = undefined,
    values: [max_attributes][*:0]u8 = undefined,
    count: usize = 0,

    fn add(self: *Attributes, name: [*:0]const u8, value: [*:0]const u8) void {
        assert(self.count < max_attributes);
        self.names[self.count] = glib.strdup(name);
        self.values[self.count] = glib.strdup(value);
        self.count += 1;
    }

    fn addColor(self: *Attributes, name: [*:0]const u8, rgb: terminal.color.RGB) void {
        var buf: [16]u8 = undefined;
        // Three u8 and two commas always fit.
        const value = std.mem.printSentinel(&buf, "{d},{d},{d}", .{ rgb.r, rgb.g, rgb.b }, 0) catch
            unreachable;
        self.add(name, value.ptr);
    }

    /// Hand the strings to the caller as two NULL-terminated arrays, or
    /// free those it declined.
    fn transfer(self: *Attributes, out_names: ?*[*][*:0]u8, out_values: ?*[*][*:0]u8) void {
        giveStrv(self.names[0..self.count], out_names);
        giveStrv(self.values[0..self.count], out_values);
    }

    fn giveStrv(strs: [][*:0]u8, out: ?*[*][*:0]u8) void {
        const dest = out orelse {
            for (strs) |s| glib.free(s);
            return;
        };
        // `g_malloc0` leaves the trailing NULL slot zeroed.
        const arr: [*][*:0]u8 = @ptrCast(@alignCast(
            glib.malloc0((strs.len + 1) * @sizeOf(?[*:0]u8)),
        ));
        @memcpy(arr[0..strs.len], strs);
        dest.* = arr;
    }
};

/// Report the font every cell is drawn in: the first configured family
/// and the live size in points, so increase/decrease/reset_font_size
/// show up as the user sees them.
fn getDefaultAttributes(
    accessible: *gtk.AccessibleText,
    out_names: ?*[*][*:0]u8,
    out_values: ?*[*][*:0]u8,
) callconv(.c) void {
    var attrs: Attributes = .{};
    // Without a core surface the arrays are empty but still present, so
    // GTK's `g_strfreev` has something valid to free.
    defer attrs.transfer(out_names, out_values);

    const surface = gobject.ext.cast(Surface, accessible) orelse return;
    const core_surface = surface.core() orelse return;

    // An empty list falls back to "monospace", like the font backend.
    const families = core_surface.config.font.@"font-family".list.items;
    attrs.add("family-name", if (families.len > 0) families[0].ptr else "monospace");

    var buf: [32]u8 = undefined;
    const size: [:0]const u8 = std.mem.printSentinel(
        &buf,
        "{d:.2}",
        .{core_surface.font_size.points},
        0,
    ) catch "0";
    attrs.add("size", size.ptr);
}

//---------------------------------------------------------------
// GtkAccessibleHypertext interface implementation (GTK 4.22+)
//
// Orca reads these directly to announce links inline as the caret or
// flat review crosses them; no link-role children are needed. On older
// GTK the interface is never registered (see `a11y_hypertext`).

pub fn initAccessibleHypertextInterface(
    iface: *a11y_hypertext.AccessibleHypertextInterface,
) callconv(.c) void {
    iface.f_get_n_links = &getNLinks;
    iface.f_get_link = &getLink;
    iface.f_get_link_at = &getLinkAt;
}

/// The surface's links, refreshed.
fn currentLinks(hypertext: *a11y_hypertext.AccessibleHypertext) ?struct { *Surface, []Link } {
    const surface = gobject.ext.cast(Surface, hypertext) orelse return null;
    const self = surface.a11y();
    _ = self.refreshCache(surface);
    return .{ surface, self.links.items };
}

fn getNLinks(hypertext: *a11y_hypertext.AccessibleHypertext) callconv(.c) c_uint {
    _, const links = currentLinks(hypertext) orelse return 0;
    return @intCast(links.len);
}

fn getLink(
    hypertext: *a11y_hypertext.AccessibleHypertext,
    index: c_uint,
) callconv(.c) *a11y_hypertext.AccessibleHyperlink {
    // Never fails for a real surface; the interface is only installed on
    // one.
    const surface, const links = currentLinks(hypertext).?;

    // The contract says `index` is below the link count; Orca breaks it
    // when the link set shrinks between its `GetNLinks` and a queued
    // `GetLink`. See `link_sentinel`.
    if (index >= links.len) {
        log.debug("ax GetLink({d}) out of bounds (links={d})", .{ index, links.len });
        return linkSentinel(surface);
    }

    const link = &links[index];
    if (link.obj) |obj| return obj;

    var bounds: gtk.AccessibleTextRange = .{
        .f_start = link.range.start,
        .f_length = link.range.end - link.range.start,
    };
    const obj = a11y_hypertext.hyperlinkNew(
        @ptrCast(surface),
        index,
        link.uri.ptr,
        &bounds,
    );
    link.obj = obj;

    // Parenting realizes the hyperlink's AT context. It must happen
    // before the bridge gets the object: one with no AT context has no
    // bus name, and returning it crashes the client with a D-Bus assert.
    // It must also happen outside `refreshCache`'s renderer mutex,
    // because realizing emits a tree change the client may answer by
    // querying us, which would re-enter `refreshCache` and deadlock.
    const accessible: *gtk.Accessible = @ptrCast(@alignCast(obj));
    accessible.setAccessibleParent(surface.as(gtk.Accessible), null);
    return obj;
}

/// The surface's sentinel hyperlink, created and parented on first use.
/// Its bounds start at the maximum offset with zero length, past any
/// real text, so Orca's range filter never matches it: with zero bounds
/// it matched any zone starting at 0 and Orca announced a spurious
/// "link" at the start of the line.
fn linkSentinel(surface: *Surface) *a11y_hypertext.AccessibleHyperlink {
    const self = surface.a11y();
    if (self.link_sentinel) |s| return s;

    var bounds: gtk.AccessibleTextRange = .{
        .f_start = std.math.maxInt(c_uint),
        .f_length = 0,
    };
    const obj = a11y_hypertext.hyperlinkNew(@ptrCast(surface), 0, "", &bounds);
    const accessible: *gtk.Accessible = @ptrCast(@alignCast(obj));
    accessible.setAccessibleParent(surface.as(gtk.Accessible), null);
    self.link_sentinel = obj;
    return obj;
}

fn getLinkAt(
    hypertext: *a11y_hypertext.AccessibleHypertext,
    offset: c_uint,
) callconv(.c) c_uint {
    _, const links = currentLinks(hypertext) orelse return std.math.maxInt(c_uint);
    for (links, 0..) |link, i| {
        if (offset >= link.range.start and offset < link.range.end) return @intCast(i);
    }
    return std.math.maxInt(c_uint);
}

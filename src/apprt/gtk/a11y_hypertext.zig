//! Hand-declared bindings for GTK 4.22's `GtkAccessibleHypertext` /
//! `GtkAccessibleHyperlink`. zig-gobject 0.3.0 (our current dep) does not
//! expose these yet, and Ghostty does not hard-require GTK 4.22, so we
//! resolve the symbols at runtime via `dlsym` on the already-loaded
//! libgtk. On older GTK, `available` stays false and all Hypertext
//! machinery in `surface.zig` becomes a no-op.
//!
//! Call `init()` once during `Application.startup`, before any surface
//! instances exist (interface registration in `Class.init` reads
//! `available`).

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gtk_version = @import("gtk_version.zig");

const log = std.log.scoped(.gtk_a11y_hypertext);

/// Opaque stand-in for `GtkAccessibleHypertext`. Only used as a typed
/// pointer through the interface vtable; we never instantiate one.
pub const AccessibleHypertext = opaque {
    /// Alias so this type slots into `gobject.ext.implement`, which
    /// expects interfaces to expose their vtable type as `Iface`.
    pub const Iface = AccessibleHypertextInterface;

    pub fn getGObjectType() gobject.Type {
        // `defineClass`'s implements loop calls this *before* any
        // instance exists — so `Class.init` hasn't run yet and init()
        // hasn't been called from there. Auto-init on first query so
        // the GType is resolvable immediately.
        init();
        const f = syms.hypertext_get_type orelse return 0;
        return f();
    }
};

/// Opaque stand-in for `GtkAccessibleHyperlink`. Instances are
/// constructed via `hyperlinkNew` and released with `unref`.
pub const AccessibleHyperlink = opaque {
    pub fn getGObjectType() gobject.Type {
        init();
        const f = syms.hyperlink_get_type orelse return 0;
        return f();
    }

    pub fn unref(self: *AccessibleHyperlink) void {
        const obj: *gobject.Object = @ptrCast(@alignCast(self));
        obj.unref();
    }
};

/// Vtable layout from `/usr/include/gtk-4.0/gtk/gtkaccessiblehypertext.h`:
///
///   struct _GtkAccessibleHypertextInterface {
///     GTypeInterface g_iface;
///     unsigned int (*get_n_links)(GtkAccessibleHypertext *);
///     GtkAccessibleHyperlink *(*get_link)(GtkAccessibleHypertext *,
///                                         unsigned int);
///     unsigned int (*get_link_at)(GtkAccessibleHypertext *,
///                                 unsigned int);
///   };
pub const AccessibleHypertextInterface = extern struct {
    g_iface: gobject.TypeInterface,
    get_n_links: ?*const fn (*AccessibleHypertext) callconv(.c) c_uint,
    get_link: ?*const fn (*AccessibleHypertext, c_uint) callconv(.c) *AccessibleHyperlink,
    get_link_at: ?*const fn (*AccessibleHypertext, c_uint) callconv(.c) c_uint,
};

const HyperlinkNewFn = *const fn (
    *AccessibleHypertext,
    c_uint,
    [*:0]const u8,
    *gtk.AccessibleTextRange,
) callconv(.c) *AccessibleHyperlink;

const GetTypeFn = *const fn () callconv(.c) gobject.Type;

const Syms = struct {
    hypertext_get_type: ?GetTypeFn = null,
    hyperlink_get_type: ?GetTypeFn = null,
    hyperlink_new: ?HyperlinkNewFn = null,
};

pub var syms: Syms = .{};

/// True once `init` has successfully resolved all required symbols
/// against a runtime GTK >= 4.22. Gate every call into this module
/// on this flag.
pub var available: bool = false;

/// Resolve GTK 4.22 hypertext symbols. Safe to call on older GTK —
/// leaves `available = false` and logs once. Idempotent; a second call
/// is a no-op.
pub fn init() void {
    if (available) return;
    if (!gtk_version.runtimeAtLeast(4, 22, 0)) {
        log.info(
            "GTK < 4.22 runtime; link announcement via GtkAccessibleHypertext disabled",
            .{},
        );
        return;
    }

    // libgtk-4 is already mapped into our process. `openZ` just bumps
    // the refcount; we intentionally never close the handle since the
    // resolved function pointers outlive any DynLib struct.
    var dl = std.DynLib.openZ("libgtk-4.so.1") catch |err| {
        log.warn("dlopen(libgtk-4.so.1) failed: {}", .{err});
        return;
    };

    const ht_get_type = dl.lookup(
        GetTypeFn,
        "gtk_accessible_hypertext_get_type",
    ) orelse {
        log.warn("missing symbol gtk_accessible_hypertext_get_type", .{});
        return;
    };
    const hl_get_type = dl.lookup(
        GetTypeFn,
        "gtk_accessible_hyperlink_get_type",
    ) orelse {
        log.warn("missing symbol gtk_accessible_hyperlink_get_type", .{});
        return;
    };
    const hl_new = dl.lookup(
        HyperlinkNewFn,
        "gtk_accessible_hyperlink_new",
    ) orelse {
        log.warn("missing symbol gtk_accessible_hyperlink_new", .{});
        return;
    };

    syms = .{
        .hypertext_get_type = ht_get_type,
        .hyperlink_get_type = hl_get_type,
        .hyperlink_new = hl_new,
    };
    available = true;
    log.info("GTK >= 4.22 hypertext bindings resolved", .{});
}

/// Construct a new hyperlink. The caller owns the returned reference.
/// Must only be called when `available` is true.
pub fn hyperlinkNew(
    parent: *AccessibleHypertext,
    index: c_uint,
    uri: [*:0]const u8,
    bounds: *gtk.AccessibleTextRange,
) *AccessibleHyperlink {
    std.debug.assert(available);
    return syms.hyperlink_new.?(parent, index, uri, bounds);
}

//! Runtime symbol resolution for GTK 4.22's `GtkAccessibleHypertext` /
//! `GtkAccessibleHyperlink`.
//!
//! The *types* come from our gobject bindings, which declare both. Only the
//! three *symbols* are resolved at runtime, via `dlsym` on the already-loaded
//! libgtk. That is deliberate: Ghostty runs against GTK as old as 4.14 (see
//! the `runtimeAtLeast` gates throughout `apprt/gtk`), and linking
//! `gtk_accessible_hypertext_get_type` directly would make the binary fail to
//! load at all on anything older, rather than merely doing without link
//! announcement. On older GTK, `available` stays false and all Hypertext
//! machinery in `surface.zig` becomes a no-op.
//!
//! Nothing here re-declares a GTK struct. An `extern struct` written by hand
//! to match a GTK vtable fails silently once GTK or the bindings move: it
//! compiles, every test passes, and the vfuncs simply never fire.
//!
//! If Ghostty ever hard-requires GTK >= 4.22, this file collapses to nothing:
//! list `gtk.AccessibleHypertext` directly in `Surface.Implements`, call
//! `gtk.AccessibleHyperlink.new` directly, and delete it.
//!
//! Call `init()` once during `Application.startup`, before any surface
//! instances exist (interface registration in `Class.init` reads
//! `available`).

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gtk_version = @import("gtk_version.zig");

const log = std.log.scoped(.gtk_a11y_hypertext);

/// Re-exported from the bindings so `surface.zig` has a single import for
/// the whole hypertext story.
pub const AccessibleHypertext = gtk.AccessibleHypertext;
pub const AccessibleHyperlink = gtk.AccessibleHyperlink;
pub const AccessibleHypertextInterface = gtk.AccessibleHypertextInterface;

/// Type tag for `Surface.Implements` and `gobject.ext.implement`.
///
/// Stands in for `AccessibleHypertext` in the registration machinery only,
/// because that is the one place that needs the GType — and asking the
/// bindings for it (`gtk.AccessibleHypertext.getGObjectType`) would link the
/// 4.22-only symbol. Everything else, vfunc signatures included, uses
/// `AccessibleHypertext`.
pub const AccessibleHypertextImpl = opaque {
    /// `gobject.ext.implement` expects interfaces to expose their vtable
    /// type as `Iface`.
    pub const Iface = AccessibleHypertextInterface;

    pub fn getGObjectType() gobject.Type {
        // `defineClass`'s implements loop calls this *before* any instance
        // exists — so `Class.init` hasn't run yet and `init()` hasn't been
        // called from there. Auto-init on first query so the GType is
        // resolvable immediately. Returns 0 on older GTK, and GObject then
        // declines to add the interface.
        init();
        const f = syms.hypertext_get_type orelse return 0;
        return f();
    }
};

/// Signature borrowed from the bindings' own declaration, so a GTK signature
/// change becomes a compile error here instead of a silent ABI mismatch at
/// the `dlsym` boundary. `@TypeOf` does not evaluate its operand, so this
/// does not emit a link-time reference to the symbol.
const HyperlinkNewFn = *const @TypeOf(gtk.AccessibleHyperlink.new);

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

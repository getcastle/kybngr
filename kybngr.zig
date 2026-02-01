const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
});

// Edit these, then rebuild.
const Config = struct {
    const mod_key = c.Mod4Mask;
    const border_width = 2;
    const border_focus = 0x005577;
    const border_normal = 0x444444;
    const gap = 10;
};

const Client = struct {
    window: c.Window,
    next: ?*Client = null,
};

const WM = struct {
    display: *c.Display,
    root: c.Window,
    screen: c_int,
    clients: ?*Client = null,
    focused: ?*Client = null,
    allocator: std.mem.Allocator,

    wm_protocols: c.Atom = c.None,
    wm_delete: c.Atom = c.None,

    fn init(allocator: std.mem.Allocator) !WM {
        const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        const screen = c.DefaultScreen(display);
        const root = c.RootWindow(display, screen);

        return WM{
            .display = display,
            .root = root,
            .screen = screen,
            .allocator = allocator,
        };
    }

    fn setup(self: *WM) !void {
        _ = c.XSelectInput(
            self.display,
            self.root,
            c.SubstructureRedirectMask | c.SubstructureNotifyMask,
        );

        self.grabKeys();

        // Intern once so closeWindow doesn't have to do it every time.
        self.wm_protocols = c.XInternAtom(self.display, "WM_PROTOCOLS", 0);
        self.wm_delete = c.XInternAtom(self.display, "WM_DELETE_WINDOW", 0);

        _ = c.XSetErrorHandler(errorHandler);
        _ = c.XSync(self.display, 0);
    }

    fn grabKeys(self: *WM) void {
        // Only two bindings live here. Everything else goes through sxhkd.
        const keys = [_]struct { key: c_uint, mod: c_uint }{
            .{ .key = c.XK_q, .mod = Config.mod_key },
            .{ .key = c.XK_q, .mod = Config.mod_key | c.ShiftMask },
        };

        // Grab with each common lock modifier so bindings work regardless
        // of NumLock/CapsLock state.
        const noise: [3]c_uint = .{ 0, c.Mod2Mask, c.LockMask };

        for (keys) |k| {
            const keycode = c.XKeysymToKeycode(self.display, k.key);
            for (noise) |n| {
                _ = c.XGrabKey(self.display, keycode, k.mod | n, self.root, 1, c.GrabModeAsync, c.GrabModeAsync);
            }
        }
    }

    fn run(self: *WM) !void {
        var event: c.XEvent = undefined;
        while (true) {
            _ = c.XNextEvent(self.display, &event);

            switch (event.type) {
                c.MapRequest => self.onMapRequest(&event.xmaprequest),
                c.UnmapNotify => self.onUnmapNotify(&event.xunmap),
                c.DestroyNotify => self.onDestroyNotify(&event.xdestroywindow),
                c.KeyPress => self.onKeyPress(&event.xkey),
                c.ConfigureRequest => self.onConfigureRequest(&event.xconfigurerequest),
                else => {},
            }
        }
    }

    fn onMapRequest(self: *WM, ev: *c.XMapRequestEvent) void {
        // Already managed, just retile.
        var current = self.clients;
        while (current) |client| : (current = client.next) {
            if (client.window == ev.window) {
                self.tile();
                return;
            }
        }

        const client = self.allocator.create(Client) catch return;
        client.* = .{ .window = ev.window };

        client.next = self.clients;
        self.clients = client;

        _ = c.XSetWindowBorderWidth(self.display, client.window, Config.border_width);
        _ = c.XSetWindowBorder(self.display, client.window, Config.border_normal);
        _ = c.XSelectInput(self.display, client.window, c.EnterWindowMask | c.FocusChangeMask);
        _ = c.XMapWindow(self.display, client.window);

        self.focused = client;
        self.tile();
    }

    fn onUnmapNotify(self: *WM, ev: *c.XUnmapEvent) void {
        self.removeClient(ev.window);
    }

    fn onDestroyNotify(self: *WM, ev: *c.XDestroyWindowEvent) void {
        self.removeClient(ev.window);
    }

    fn onKeyPress(self: *WM, ev: *c.XKeyEvent) void {
        const keysym = c.XkbKeycodeToKeysym(self.display, @intCast(ev.keycode), 0, 0);

        // Mask out lock keys before comparing.
        const clean_state = ev.state & ~@as(c_uint, c.Mod2Mask | c.LockMask | c.Mod3Mask);

        if (keysym == c.XK_q and clean_state == Config.mod_key) {
            if (self.focused) |client| {
                self.closeWindow(client.window);
            }
        } else if (keysym == c.XK_q and clean_state == (Config.mod_key | c.ShiftMask)) {
            std.process.exit(0);
        }
    }

    // Try WM_DELETE_WINDOW first, fall back to XKillClient.
    fn closeWindow(self: *WM, window: c.Window) void {
        var protocols: [*c]c.Atom = undefined;
        var count: c_ulong = 0;
        var actual_type: c.Atom = undefined;
        var actual_format: c_int = undefined;
        var bytes_after: c_ulong = undefined;

        if (c.XGetWindowProperty(
            self.display, window, self.wm_protocols,
            0, 32, 0, c.AnyPropertyType,
            &actual_type, &actual_format, &count, &bytes_after,
            @ptrCast(&protocols),
        ) != c.Success or count == 0) {
            _ = c.XKillClient(self.display, window);
            return;
        }

        var supported = false;
        for (0..@as(usize, @intCast(count))) |i| {
            if (protocols[i] == self.wm_delete) {
                supported = true;
                break;
            }
        }
        _ = c.XFree(@ptrCast(protocols));

        if (!supported) {
            _ = c.XKillClient(self.display, window);
            return;
        }

        var event: c.XEvent = undefined;
        event.xclient.type = c.ClientMessage;
        event.xclient.window = window;
        event.xclient.message_type = self.wm_protocols;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intCast(self.wm_delete);
        event.xclient.data.l[1] = c.CurrentTime;
        _ = c.XSendEvent(self.display, window, 0, c.NoEventMask, &event);
    }

    fn onConfigureRequest(self: *WM, ev: *c.XConfigureRequestEvent) void {
        // Managed windows get their geometry from tile(), not from themselves.
        var current = self.clients;
        while (current) |client| : (current = client.next) {
            if (client.window == ev.window) {
                var changes: c.XWindowChanges = undefined;
                changes.border_width = Config.border_width;
                _ = c.XConfigureWindow(self.display, ev.window, c.CWBorderWidth, &changes);
                return;
            }
        }

        // Not yet managed — grant it so the app doesn't block.
        var changes: c.XWindowChanges = undefined;
        changes.x = ev.x;
        changes.y = ev.y;
        changes.width = ev.width;
        changes.height = ev.height;
        changes.border_width = Config.border_width;
        changes.sibling = ev.above;
        changes.stack_mode = ev.detail;
        _ = c.XConfigureWindow(self.display, ev.window, @intCast(ev.value_mask), &changes);
    }

    fn tile(self: *WM) void {
        // Root window geometry is always current, even after xrandr changes.
        var attrs: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(self.display, self.root, &attrs);
        const screen_width = attrs.width;
        const screen_height = attrs.height;

        var count: usize = 0;
        var current = self.clients;
        while (current) |_| : (current = current.?.next) {
            count += 1;
        }

        if (count == 0) return;

        const usable_x: c_int = Config.gap;
        const usable_y: c_int = Config.gap;
        const usable_w: c_int = screen_width - 2 * Config.gap;
        const usable_h: c_int = screen_height - 2 * Config.gap;

        if (count == 1) {
            // Single window takes the whole screen.
            current = self.clients;
            if (current) |client| {
                _ = c.XMoveResizeWindow(
                    self.display, client.window,
                    usable_x, usable_y,
                    @intCast(usable_w - 2 * Config.border_width),
                    @intCast(usable_h - 2 * Config.border_width),
                );
                const border_color: c_ulong = if (client == self.focused) Config.border_focus else Config.border_normal;
                _ = c.XSetWindowBorder(self.display, client.window, border_color);
            }
        } else {
            // Master on the left, stack on the right.
            const master_w: c_int = @divTrunc(usable_w - Config.gap, 2);
            const stack_x: c_int = usable_x + master_w + Config.gap;
            const stack_w: c_int = usable_w - master_w - Config.gap;
            const stack_count: usize = count - 1;
            const stack_item_h: c_int = @intCast(
                (@as(usize, @intCast(usable_h)) - Config.gap * (stack_count - 1)) / stack_count,
            );

            var i: usize = 0;
            current = self.clients;
            while (current) |client| : (current = client.next) {
                if (i == 0) {
                    _ = c.XMoveResizeWindow(
                        self.display, client.window,
                        usable_x, usable_y,
                        @intCast(master_w - 2 * Config.border_width),
                        @intCast(usable_h - 2 * Config.border_width),
                    );
                } else {
                    const stack_idx = i - 1;
                    const y: c_int = @intCast(
                        @as(usize, @intCast(usable_y)) + stack_idx * (@as(usize, @intCast(stack_item_h)) + Config.gap),
                    );
                    _ = c.XMoveResizeWindow(
                        self.display, client.window,
                        stack_x, y,
                        @intCast(stack_w - 2 * Config.border_width),
                        @intCast(stack_item_h - 2 * Config.border_width),
                    );
                }

                const border_color: c_ulong = if (client == self.focused) Config.border_focus else Config.border_normal;
                _ = c.XSetWindowBorder(self.display, client.window, border_color);

                i += 1;
            }
        }

        if (self.focused) |focused| {
            _ = c.XSetInputFocus(self.display, focused.window, c.RevertToPointerRoot, c.CurrentTime);
            _ = c.XRaiseWindow(self.display, focused.window);
        }
    }

    fn removeClient(self: *WM, window: c.Window) void {
        var prev: ?*Client = null;
        var current = self.clients;

        while (current) |client| {
            if (client.window == window) {
                if (prev) |p| {
                    p.next = client.next;
                } else {
                    self.clients = client.next;
                }

                if (self.focused == client) {
                    self.focused = self.clients;
                }

                self.allocator.destroy(client);
                self.tile();
                return;
            }
            prev = client;
            current = client.next;
        }
    }

    fn deinit(self: *WM) void {
        _ = c.XCloseDisplay(self.display);
    }
};

fn errorHandler(display: ?*c.Display, event: [*c]c.XErrorEvent) callconv(.c) c_int {
    _ = display;
    var buf: [256]u8 = undefined;
    _ = c.XGetErrorText(event.*.display, event.*.error_code, &buf, buf.len);
    const msg = std.mem.sliceTo(&buf, 0);
    _ = posix.write(2, "X Error: ") catch {};
    _ = posix.write(2, msg) catch {};
    _ = posix.write(2, "\n") catch {};
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var wm = try WM.init(allocator);
    defer wm.deinit();

    try wm.setup();
    try wm.run();
}

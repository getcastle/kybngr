const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
});

// cimport misses the XA_* macros, just hardcode 'em
const XA_ATOM: c.Atom = 4;
const XA_CARDINAL: c.Atom = 6;
const XA_WINDOW: c.Atom = 33;

// Edit these, then rebuild.
const Config = struct {
    const mod_key = c.Mod4Mask;
    const border_width = 2;
    const border_focus = 0x005577;
    const border_normal = 0x444444;
    const gap = 10;
    const num_workspaces = 9;
};

const Client = struct {
    window: c.Window,
    next: ?*Client = null,
};

const Workspace = struct {
    clients: ?*Client = null,
    focused: ?*Client = null,
};

const WM = struct {
    display: *c.Display,
    root: c.Window,
    allocator: std.mem.Allocator,

    workspaces: [Config.num_workspaces]Workspace = [Config.num_workspaces]Workspace{
        .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{},
    },
    current: usize = 0,

    wm_protocols: c.Atom = c.None,
    wm_delete: c.Atom = c.None,

    // ewmh stuff — bars and fetch scripts read these off root
    ewmh_supported: c.Atom = c.None,
    ewmh_wm_name: c.Atom = c.None,
    ewmh_active_window: c.Atom = c.None,
    ewmh_desktop_geometry: c.Atom = c.None,
    ewmh_desktop_viewport: c.Atom = c.None,
    ewmh_current_desktop: c.Atom = c.None,
    ewmh_desktop_names: c.Atom = c.None,
    ewmh_number_of_desktops: c.Atom = c.None,

    fn init(allocator: std.mem.Allocator) !WM {
        const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        const root = c.RootWindow(display, c.DefaultScreen(display));

        return WM{
            .display = display,
            .root = root,
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

        // intern once, reuse forever
        self.wm_protocols = c.XInternAtom(self.display, "WM_PROTOCOLS", 0);
        self.wm_delete = c.XInternAtom(self.display, "WM_DELETE_WINDOW", 0);

        // ewmh — intern atoms and stamp them on root
        self.ewmh_supported = c.XInternAtom(self.display, "_NET_SUPPORTED", 0);
        self.ewmh_wm_name = c.XInternAtom(self.display, "_NET_WM_NAME", 0);
        self.ewmh_active_window = c.XInternAtom(self.display, "_NET_ACTIVE_WINDOW", 0);
        self.ewmh_desktop_geometry = c.XInternAtom(self.display, "_NET_DESKTOP_GEOMETRY", 0);
        self.ewmh_desktop_viewport = c.XInternAtom(self.display, "_NET_DESKTOP_VIEWPORT", 0);
        self.ewmh_current_desktop = c.XInternAtom(self.display, "_NET_CURRENT_DESKTOP", 0);
        self.ewmh_desktop_names = c.XInternAtom(self.display, "_NET_DESKTOP_NAMES", 0);
        self.ewmh_number_of_desktops = c.XInternAtom(self.display, "_NET_NUMBER_OF_DESKTOPS", 0);

        const utf8_string = c.XInternAtom(self.display, "UTF8_STRING", 0);

        // how neofetch/bars know what wm you're running
        const wm_name = "kybngr";
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_wm_name,
            utf8_string, 8, c.PropModeReplace,
            @ptrCast(wm_name.ptr), wm_name.len,
        );

        // tell everyone what we actually support
        const supported = [_]c.Atom{
            self.ewmh_supported,
            self.ewmh_wm_name,
            self.ewmh_active_window,
            self.ewmh_desktop_geometry,
            self.ewmh_desktop_viewport,
            self.ewmh_current_desktop,
            self.ewmh_desktop_names,
            self.ewmh_number_of_desktops,
        };
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_supported,
            XA_ATOM, 32, c.PropModeReplace,
            @ptrCast(&supported), supported.len,
        );

        // screen size for bars that want it
        var attrs: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(self.display, self.root, &attrs);
        var geo = [2]c_long{ attrs.width, attrs.height };
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_desktop_geometry,
            XA_CARDINAL, 32, c.PropModeReplace,
            @ptrCast(&geo), 2,
        );
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_desktop_viewport,
            XA_CARDINAL, 32, c.PropModeReplace,
            @ptrCast(&geo), 2,
        );

        // workspace ewmh props
        var num_desktops: c_long = Config.num_workspaces;
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_number_of_desktops,
            XA_CARDINAL, 32, c.PropModeReplace,
            @ptrCast(&num_desktops), 1,
        );
        self.updateCurrentDesktop();
        self.updateDesktopNames();

        _ = c.XSetErrorHandler(errorHandler);
        _ = c.XSync(self.display, 0);
    }

    fn grabKeys(self: *WM) void {
        // everything else is sxhkd's problem
        const keys = [_]struct { key: c_uint, mod: c_uint }{
            .{ .key = c.XK_q, .mod = Config.mod_key },
            .{ .key = c.XK_q, .mod = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_j, .mod = Config.mod_key },
            .{ .key = c.XK_k, .mod = Config.mod_key },
            .{ .key = c.XK_m, .mod = Config.mod_key },
        };

        // grab w/ lockmods so keys work w/ numlock/capslock on
        const noise: [3]c_uint = .{ 0, c.Mod2Mask, c.LockMask };

        for (keys) |k| {
            const keycode = c.XKeysymToKeycode(self.display, k.key);
            for (noise) |n| {
                _ = c.XGrabKey(self.display, keycode, k.mod | n, self.root, 1, c.GrabModeAsync, c.GrabModeAsync);
            }
        }

        // workspace keys: Super+1-9 and Super+Shift+1-9
        const ws_keys = [_]struct { key: c_uint, mod: c_uint, mod_shift: c_uint }{ 
            .{ .key = c.XK_1, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_2, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_3, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_4, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_5, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_6, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_7, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_8, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
            .{ .key = c.XK_9, .mod = Config.mod_key, .mod_shift = Config.mod_key | c.ShiftMask },
        };
        for (ws_keys) |wsk| {
            const keycode = c.XKeysymToKeycode(self.display, wsk.key);
            for (noise) |n| {
                _ = c.XGrabKey(self.display, keycode, wsk.mod | n, self.root, 1, c.GrabModeAsync, c.GrabModeAsync);
                _ = c.XGrabKey(self.display, keycode, wsk.mod_shift | n, self.root, 1, c.GrabModeAsync, c.GrabModeAsync);
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
        const ws = &self.workspaces[self.current];

        // already tracking this one, just retile
        var current = ws.clients;
        while (current) |client| : (current = client.next) {
            if (client.window == ev.window) {
                self.tile();
                return;
            }
        }

        // check if this is a popup/tooltip/splash we shouldn't manage
        if (!self.shouldManage(ev.window)) {
            _ = c.XMapWindow(self.display, ev.window);
            return;
        }

        const client = self.allocator.create(Client) catch return;
        client.* = .{ .window = ev.window };

        client.next = ws.clients;
        ws.clients = client;

        _ = c.XSetWindowBorderWidth(self.display, client.window, Config.border_width);
        _ = c.XSetWindowBorder(self.display, client.window, Config.border_normal);
        _ = c.XSelectInput(self.display, client.window, c.EnterWindowMask | c.FocusChangeMask);
        _ = c.XMapWindow(self.display, client.window);

        ws.focused = client;
        self.tile();
    }

    // check if a window should be tiled or left alone (tooltips, popups, etc)
    fn shouldManage(self: *WM, window: c.Window) bool {
        var attrs: c.XWindowAttributes = undefined;
        if (c.XGetWindowAttributes(self.display, window, &attrs) == 0) return false;

        // override_redirect means X handles it (menus, tooltips)
        if (attrs.override_redirect != 0) return false;

        // check _NET_WM_WINDOW_TYPE
        var actual_type: c.Atom = undefined;
        var actual_format: c_int = undefined;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]c.Atom = undefined;

        const net_wm_window_type = c.XInternAtom(self.display, "_NET_WM_WINDOW_TYPE", 0);
        if (c.XGetWindowProperty(
            self.display, window, net_wm_window_type,
            0, 1, 0, XA_ATOM,
            &actual_type, &actual_format, &nitems, &bytes_after,
            @ptrCast(&prop),
        ) == c.Success and nitems > 0) {
            const window_type = prop[0];
            _ = c.XFree(@ptrCast(prop));

            // types we should NOT tile
            const ignored_types = [_][]const u8{
                "_NET_WM_WINDOW_TYPE_TOOLTIP",
                "_NET_WM_WINDOW_TYPE_NOTIFICATION",
                "_NET_WM_WINDOW_TYPE_POPUP_MENU",
                "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
                "_NET_WM_WINDOW_TYPE_COMBO",
                "_NET_WM_WINDOW_TYPE_DND",
                "_NET_WM_WINDOW_TYPE_SPLASH",
            };

            for (ignored_types) |type_name| {
                const atom = c.XInternAtom(self.display, type_name.ptr, 0);
                if (window_type == atom) return false;
            }
        }

        return true;
    }

    fn onUnmapNotify(self: *WM, ev: *c.XUnmapEvent) void {
        // if the window still exists we unmapped it ourselves (ws switch) — ignore
        var attrs: c.XWindowAttributes = undefined;
        if (c.XGetWindowAttributes(self.display, ev.window, &attrs) != 0) return;
        self.removeClient(ev.window);
    }

    fn onDestroyNotify(self: *WM, ev: *c.XDestroyWindowEvent) void {
        self.removeClient(ev.window);
    }

    fn onKeyPress(self: *WM, ev: *c.XKeyEvent) void {
        const keysym = c.XkbKeycodeToKeysym(self.display, @intCast(ev.keycode), 0, 0);

        // strip numlock/capslock/scrolllock noise
        const clean_state = ev.state & ~@as(c_uint, c.Mod2Mask | c.LockMask | c.Mod3Mask);

        if (keysym == c.XK_q and clean_state == Config.mod_key) {
            if (self.workspaces[self.current].focused) |client| {
                self.closeWindow(client.window);
            }
        } else if (keysym == c.XK_q and clean_state == (Config.mod_key | c.ShiftMask)) {
            std.process.exit(0);
        } else if (keysym == c.XK_j and clean_state == Config.mod_key) {
            self.focusNext();
        } else if (keysym == c.XK_k and clean_state == Config.mod_key) {
            self.focusPrev();
        } else if (keysym == c.XK_m and clean_state == Config.mod_key) {
            self.swapMaster();
        } else if (keysym >= c.XK_1 and keysym <= c.XK_9) {
            const idx = @as(usize, @intCast(keysym - c.XK_1));
            if (idx < Config.num_workspaces) {
                if (clean_state == Config.mod_key) {
                    self.switchWorkspace(idx);
                } else if (clean_state == (Config.mod_key | c.ShiftMask)) {
                    self.moveToWorkspace(idx);
                }
            }
        }
    }

    // cycle focus forward, wrap at tail
    fn focusNext(self: *WM) void {
        const ws = &self.workspaces[self.current];
        const focused = ws.focused orelse return;
        const next = focused.next orelse ws.clients orelse return;
        ws.focused = next;
        self.tile();
    }

    // cycle focus back, wrap at head
    fn focusPrev(self: *WM) void {
        const ws = &self.workspaces[self.current];
        const focused = ws.focused orelse return;

        // walk to the node before focused
        var prev: ?*Client = null;
        var current = ws.clients;
        while (current) |client| : (current = client.next) {
            if (client.next == focused) {
                prev = client;
                break;
            }
        }

        // wasn't found — focused is head, wrap to tail
        if (prev == null) {
            current = ws.clients;
            while (current) |client| : (current = client.next) {
                if (client.next == null) {
                    prev = client;
                    break;
                }
            }
        }

        const target = prev orelse return;
        if (target == focused) return; // only one client
        ws.focused = target;
        self.tile();
    }

    // pull focused to head of list — that's master
    fn swapMaster(self: *WM) void {
        const ws = &self.workspaces[self.current];
        const focused = ws.focused orelse return;
        // already there
        if (ws.clients == focused) return;

        // unlink it
        var prev = ws.clients;
        while (prev) |p| {
            if (p.next == focused) {
                p.next = focused.next;
                break;
            }
            prev = p.next;
        }

        // stick it at the front
        focused.next = ws.clients;
        ws.clients = focused;
        self.tile();
    }

    // hide everything on current ws, show everything on target ws
    fn switchWorkspace(self: *WM, target: usize) void {
        if (target == self.current) return;

        // unmap all windows on current workspace
        var current = self.workspaces[self.current].clients;
        while (current) |client| : (current = client.next) {
            _ = c.XUnmapWindow(self.display, client.window);
        }

        self.current = target;

        // map all windows on new workspace and tile
        current = self.workspaces[self.current].clients;
        while (current) |client| : (current = client.next) {
            _ = c.XMapWindow(self.display, client.window);
        }

        self.tile();
        self.updateCurrentDesktop();
    }

    // move focused window from current ws to target ws
    fn moveToWorkspace(self: *WM, target: usize) void {
        if (target == self.current) return;
        const ws = &self.workspaces[self.current];
        const focused = ws.focused orelse return;

        // unlink from current
        var prev: ?*Client = null;
        var current = ws.clients;
        while (current) |client| : (current = client.next) {
            if (client == focused) {
                if (prev) |p| {
                    p.next = client.next;
                } else {
                    ws.clients = client.next;
                }
                break;
            }
            prev = client;
        }

        // update focus on current ws
        ws.focused = ws.clients;

        // hide it
        _ = c.XUnmapWindow(self.display, focused.window);

        // prepend onto target ws
        focused.next = self.workspaces[target].clients;
        self.workspaces[target].clients = focused;
        self.workspaces[target].focused = focused;

        self.tile();
    }

    // polite close via WM_DELETE_WINDOW, nuke it if that fails
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
        // check current workspace first — most configure events are for visible windows
        if (self.isWindowManaged(self.current, ev.window)) {
            var changes: c.XWindowChanges = undefined;
            changes.border_width = Config.border_width;
            _ = c.XConfigureWindow(self.display, ev.window, c.CWBorderWidth, &changes);
            return;
        }

        // search other workspaces
        for (0..Config.num_workspaces) |i| {
            if (i == self.current) continue;
            if (self.isWindowManaged(i, ev.window)) {
                var changes: c.XWindowChanges = undefined;
                changes.border_width = Config.border_width;
                _ = c.XConfigureWindow(self.display, ev.window, c.CWBorderWidth, &changes);
                return;
            }
        }

        // not ours yet — grant it or the app hangs
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

    fn isWindowManaged(self: *WM, ws_idx: usize, window: c.Window) bool {
        var current = self.workspaces[ws_idx].clients;
        while (current) |client| : (current = client.next) {
            if (client.window == window) return true;
        }
        return false;
    }

    // update active window on root so bars can see what's focused
    fn updateActiveWindow(self: *WM) void {
        var window: c.Window = if (self.workspaces[self.current].focused) |f| f.window else c.None;
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_active_window,
            XA_WINDOW, 32, c.PropModeReplace,
            @ptrCast(&window), 1,
        );
    }

    fn updateCurrentDesktop(self: *WM) void {
        var desktop: c_long = @intCast(self.current);
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_current_desktop,
            XA_CARDINAL, 32, c.PropModeReplace,
            @ptrCast(&desktop), 1,
        );
    }

    // null-separated workspace names for bars
    fn updateDesktopNames(self: *WM) void {
        const utf8_string = c.XInternAtom(self.display, "UTF8_STRING", 0);
        // "1\x000\x002\x00..." — each name is just the number
        var buf: [Config.num_workspaces * 2]u8 = undefined;
        var len: usize = 0;
        for (0..Config.num_workspaces) |i| {
            buf[len] = @intCast('1' + i);
            len += 1;
            buf[len] = 0;
            len += 1;
        }
        _ = c.XChangeProperty(
            self.display, self.root, self.ewmh_desktop_names,
            utf8_string, 8, c.PropModeReplace,
            @ptrCast(&buf), @intCast(len),
        );
    }

    fn tile(self: *WM) void {
        const ws = &self.workspaces[self.current];

        // use root attrs — always current, even after xrandr
        var attrs: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(self.display, self.root, &attrs);
        const screen_width = attrs.width;
        const screen_height = attrs.height;

        // count clients while we have the pointer anyway
        var count: usize = 0;
        var current = ws.clients;
        while (current) |_| : (current = current.?.next) {
            count += 1;
        }

        if (count == 0) {
            self.updateActiveWindow();
            return;
        }

        const usable_x: c_int = Config.gap;
        const usable_y: c_int = Config.gap;
        const usable_w: c_int = screen_width - 2 * Config.gap;
        const usable_h: c_int = screen_height - 2 * Config.gap;

        if (count == 1) {
            // only one window — give it everything
            current = ws.clients;
            if (current) |client| {
                _ = c.XMoveResizeWindow(
                    self.display, client.window,
                    usable_x, usable_y,
                    @intCast(usable_w - 2 * Config.border_width),
                    @intCast(usable_h - 2 * Config.border_width),
                );
                const border_color: c_ulong = if (client == ws.focused) Config.border_focus else Config.border_normal;
                _ = c.XSetWindowBorder(self.display, client.window, border_color);
            }
        } else {
            // master left, stack right — precompute all layout values
            const master_w: c_int = @divTrunc(usable_w - Config.gap, 2);
            const stack_x: c_int = usable_x + master_w + Config.gap;
            const stack_w: c_int = usable_w - master_w - Config.gap;
            const stack_count: usize = count - 1;
            const stack_item_h: c_int = @intCast(
                (@as(usize, @intCast(usable_h)) - Config.gap * (stack_count - 1)) / stack_count,
            );

            var i: usize = 0;
            current = ws.clients;
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

                const border_color: c_ulong = if (client == ws.focused) Config.border_focus else Config.border_normal;
                _ = c.XSetWindowBorder(self.display, client.window, border_color);

                i += 1;
            }
        }

        if (ws.focused) |focused| {
            _ = c.XSetInputFocus(self.display, focused.window, c.RevertToPointerRoot, c.CurrentTime);
            _ = c.XRaiseWindow(self.display, focused.window);
        }

        self.updateActiveWindow();
    }

    // search all workspaces for this window — it could be on any of them
    fn removeClient(self: *WM, window: c.Window) void {
        // check current workspace first — most likely location
        if (self.removeClientFromWorkspace(self.current, window)) return;

        // not on current, search the rest
        for (0..Config.num_workspaces) |i| {
            if (i == self.current) continue;
            if (self.removeClientFromWorkspace(i, window)) return;
        }
    }

    fn removeClientFromWorkspace(self: *WM, ws_idx: usize, window: c.Window) bool {
        var prev: ?*Client = null;
        var current = self.workspaces[ws_idx].clients;

        while (current) |client| {
            if (client.window == window) {
                if (prev) |p| {
                    p.next = client.next;
                } else {
                    self.workspaces[ws_idx].clients = client.next;
                }

                if (self.workspaces[ws_idx].focused == client) {
                    self.workspaces[ws_idx].focused = self.workspaces[ws_idx].clients;
                }

                self.allocator.destroy(client);

                // only retile if it was on the visible workspace
                if (ws_idx == self.current) self.tile();
                return true;
            }
            prev = client;
            current = client.next;
        }
        return false;
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

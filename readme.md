# kybngr 'keybanger'

A minimal tiling window manager for X11, written in Zig.

Master/stack layout. Keyboard-driven.

## Dependencies

- zig (0.15)
- libx11
- xorg-server-devel (for headers)

On Arch:

    sudo pacman -S zig libx11 xorg-server-devel sxhkd

## Building

    zig build -Doptimize=ReleaseFast
    sudo cp zig-out/bin/kybngr /usr/local/bin/

## Configuration

Everything is in the `Config` struct at the top of `kybngr.zig`. Change it, rebuild.

    mod_key           - modifier key (default: Super)
    border_width      - window border width in pixels
    border_focus      - focused window border color (hex)
    border_normal     - unfocused window border color (hex)
    gap               - gap between windows and screen edges in pixels
    num_workspaces    - number of workspaces (default: 9)

## Keybindings

    Super+q            close focused window
    Super+Shift+q      quit
    Super+j            focus next window
    Super+k            focus previous window
    Super+m            promote focused window to master
    Super+1-9          switch to workspace
    Super+Shift+1-9    move focused window to workspace

All other keybindings should be configured in sxhkd.

## Running

Add to the end of your `~/.xinitrc`:

    exec kybngr

Then start X with `startx`.

## Layout

One window open: it takes the full screen.

Two or more: the most recent window becomes master on the left half. All others
stack vertically on the right. No mouse, no floating, no status bar.

Tooltips, popups, splash screens, and notifications are automatically ignored
and not tiled. They appear where the application places them.

## Bar and tool compatibility

kybngr sets the following EWMH properties on the root window:

    _NET_WM_NAME              - reports "kybngr" to neofetch, screenfetch, bars, etc.
    _NET_SUPPORTED            - advertises supported EWMH hints
    _NET_ACTIVE_WINDOW        - updated on every focus change, for bar window lists
    _NET_DESKTOP_GEOMETRY     - current screen size
    _NET_DESKTOP_VIEWPORT     - current screen size
    _NET_NUMBER_OF_DESKTOPS   - total workspace count
    _NET_CURRENT_DESKTOP      - which workspace is active
    _NET_DESKTOP_NAMES        - workspace names ("1" through "9")

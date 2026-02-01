# kybngr 'keybanger'

A minimal tiling window manager for X11, written in Zig. (not really meant for public use..)

## Dependencies

- zig (0.15)
- libx11
- xorg-server-devel (for headers)
- sxhkd (for spawning and other keybindings)

On Arch:

    sudo pacman -S zig libx11 xorg-server-devel sxhkd

## Building

    zig build -Doptimize=ReleaseFast
    sudo cp zig-out/bin/kybngr /usr/local/bin/

## Configuration

Everything is in the `Config` struct at the top of `kybngr.zig`. Change it, rebuild.

    mod_key        - modifier key (default: Super)
    border_width   - window border width in pixels
    border_focus   - focused window border color (hex)
    border_normal  - unfocused window border color (hex)
    gap            - gap between windows and screen edges in pixels

## Keybindings

    Super+q        close focused window
    Super+Shift+q  quit
    Super+j        focus next window
    Super+k        focus previous window
    Super+m        promote focused window to master

All other keybindings should be configured in sxhkd. For example, to launch a
terminal and browser etc.

## Running

Add to the end of your `~/.xinitrc`:

    exec kybngr

Then start X with `startx`.

## Layout

One window open: it takes the full screen.

Two or more: the most recent window becomes master on the left half. All others
stack vertically on the right. No mouse, no floating, no status bar.

## Bar and tool compatibility

kybngr sets the following EWMH properties on the root window:

    _NET_WM_NAME           - reports "kybngr" to neofetch, screenfetch, bars, etc.
    _NET_SUPPORTED         - advertises supported EWMH hints
    _NET_ACTIVE_WINDOW     - updated on every focus change, for bar window lists
    _NET_DESKTOP_GEOMETRY  - current screen size
    _NET_DESKTOP_VIEWPORT  - current screen size

Compositors shoudld work out of box now..

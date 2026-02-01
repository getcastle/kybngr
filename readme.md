# kybngr 'keybanger'

A minimal tiling window manager for X11, written in Zig. 
(this is mostly for my own personal use & so i could learn zig, still a large wip)

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

All other keybindings should be configured in sxhkd. For example, to launch a
terminal and browser.

## Running

Add to the end of your `~/.xinitrc`:

    exec kybngr

Then start X with `startx`.

## Layout

One window open: it takes the full screen.

Two or more: the most recent window becomes master on the left half. All others
stack vertically on the right. No mouse, no floating, no status bar.

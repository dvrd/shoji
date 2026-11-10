# Configuration

Query and set a running daemon:

```sh
shoji -m config SETTING
shoji -m config SETTING VALUE
shoji -m config --space INDEX SETTING VALUE
```

A setting name with no value prints the current value. `shojirc` is a shell
script of these commands, run after the socket starts. A command in a terminal
applies immediately; put it in `~/.config/shoji/shojirc` to keep it across
restarts. Use the absolute path to `shoji` in that file.

The defaults below are a fresh daemon, before `shojirc`. A bare `Manager` used
by tests leaves resize fade, scroll animation, and scroll frame pacing off;
`state_init` turns those three on. Space-scoped settings copy onto Spaces that
have no override for that name. A later global change leaves an overridden
Space alone.

`config_catalog_matches_daemon_defaults` queries every name below.

## Which windows are tiled

A window is tiled when it is ordered in, a root window, and none of floating,
minimized, hidden, fullscreen, or sticky. An unknown ordered-in or root flag
counts as true. After those checks, `manage=on` or `manage=off` decides.
Otherwise the window is tiled when its role is `AXWindow` and its subrole is
`AXStandardWindow`.

Dialogs, sheets, and save panels report `AXDialog`, so they stay out of the
layout. `manage=on` overrides that role check and still loses while the window
is minimized, hidden, unordered, not a root window, floating, fullscreen, or
sticky.

An accessory application (activation policy 1), or a window whose size is
known to be fixed, is marked floating when Shoji first records it. That
floating flag stays set if the window later becomes resizable.

## Settings

| Setting | Default | Values | Scope |
| --- | --- | --- | --- |
| `layout` | `float` | `bsp`, `stack`, `scroll`, `float` | space |
| `window_gap` | `0` | `0` .. `100000` | space |
| `top_padding` | `0` | `0` .. `100000` | space |
| `bottom_padding` | `0` | `0` .. `100000` | space |
| `left_padding` | `0` | `0` .. `100000` | space |
| `right_padding` | `0` | `0` .. `100000` | space |
| `split_ratio` | `0.5` | `0.1` .. `0.9` | space |
| `split_type` | `auto` | `auto`, `vertical`, `horizontal` | space |
| `auto_balance` | `off` | `on`, `off`, `x-axis`, `y-axis` | space |
| `window_placement` | `second_child` | `first_child`, `second_child` | space |
| `window_insertion_point` | `focused` | `focused`, `first`, `last` | global |
| `window_origin_display` | `default` | `default`, `focused`, `cursor` | global |
| `display_arrangement_order` | `default` | `default`, `vertical`, `horizontal` | global |
| `external_bar` | `off:0:0` | `off:top:bottom`, `main:top:bottom`, or `all:top:bottom` | global |
| `window_shadow` | `on` | `on`, `off`, `float` | global |
| `window_opacity` | `off` | `on`, `off` | global |
| `active_window_opacity` | `1` | `0` .. `1` | global |
| `normal_window_opacity` | `1` | `0` .. `1` | global |
| `window_opacity_duration` | `0` | `0` .. `3600` seconds | global |
| `focus_ring` | `on` | `on`, `off` | global |
| `focus_ring_width` | `3` | `1` .. `16` | global |
| `focus_ring_radius` | `10` | `1` .. `64` | global |
| `focus_ring_color` | `0xff7fc8ff` | `0xAARRGGBB` | global |
| `insert_feedback_color` | `0xffd75f5f` | `0xAARRGGBB` | global |
| `tab_indicator_position` | `left` | `left`, `top` | global |
| `tab_indicator_width` | `4` | `1` .. `32` | global |
| `tab_indicator_gap` | `0` | `0` .. `32` | global |
| `tab_indicator_active_color` | `default` | `default` or `0xAARRGGBB` | global |
| `tab_indicator_inactive_color` | `default` | `default` or `0xAARRGGBB` | global |
| `tab_conceal` | `off` | `on`, `off` | global |
| `scroll_default_column_display` | `normal` | `normal`, `tabbed` | space |
| `scroll_default_column_width` | `ratio:0.5` | `abs:pixels` or `ratio:fraction` | space |
| `scroll_width_presets` | `ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666` | 1 .. 16 sizes | space |
| `scroll_height_presets` | `ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666` | 1 .. 16 sizes | space |
| `scroll_center_focused_column` | `never` | `never`, `always`, `on-overflow` | space |
| `scroll_center_single_column` | `off` | `on`, `off` | space |
| `scroll_warp_pointer` | `off` | `on`, `off` | space |
| `scroll_animation` | `on` | `on`, `off` | global |
| `scroll_frame_pacing` | `on` | `on`, `off` | global |
| `window_resize_animation` | `fade` | `fade`, `off` | global |
| `window_animation_duration` | `0` | `0` .. `3600` | global |
| `window_animation_easing` | `ease_out_circ` | see below | global |
| `window_zoom_persist` | `on` | `on`, `off` | global |
| `mouse_modifier` | `fn` | `alt`, `shift`, `cmd`, `ctrl`, `fn` | global |
| `mouse_action1` | `move` | `none`, `move`, `resize` | global |
| `mouse_action2` | `resize` | `none`, `move`, `resize` | global |
| `mouse_drop_action` | `swap` | `swap`, `stack` | global |
| `focus_follows_mouse` | `off` | `off`, `autofocus`, `autoraise` | global |
| `mouse_follows_focus` | `off` | `on`, `off` | global |
| `scroll_gestures` | `off` | `on`, `off` | global |
| `three_finger_horizontal` | `off` | `on`, `off` | global |
| `stack_swipe` | `off` | `on`, `off` | global |
| `scroll_drag_edge_scroll` | `on` | `on`, `off` | global |
| `scroll_drag_edge_width` | `30` | pixels, `1` .. `500` | global |
| `scroll_drag_edge_delay` | `0.1` | seconds, `0` .. `5` | global |
| `scroll_drag_edge_speed` | `1500` | pixels/second, `1` .. `10000` | global |
| `dynamic_workspaces` | `off` | `on`, `off` | global |
| `workspace_hotplug` | `off` | `on`, `off` | global |
| `windowserver_gate` | daemon only | `on`, `off` | global |

`windowserver_gate` is opt-in and answered by the daemon. A process with no
gate control reports `windowserver_gate needs the daemon`.

`window_animation_easing` accepts `linear`, `ease_in_sine`, `ease_out_sine`,
`ease_in_out_sine`, `ease_in_quad`, `ease_out_quad`, `ease_in_out_quad`,
`ease_in_cubic`, `ease_out_cubic`, `ease_in_out_cubic`, `ease_in_quart`,
`ease_out_quart`, `ease_in_out_quart`, `ease_in_quint`, `ease_out_quint`,
`ease_in_out_quint`, `ease_in_expo`, `ease_out_expo`, `ease_in_out_expo`,
`ease_in_circ`, `ease_out_circ`, `ease_in_out_circ`.

`scroll_animation on` arms the scroll camera spring. The default
`window_animation_duration` of 0 leaves that spring idle. A positive duration
runs it and keeps the spring timing. See [Scroll layout](SCROLL_LAYOUT.md).

`three_finger_horizontal` and `stack_swipe` read the trackpad only on builds
`24G84` and `26B123`. They stay off until set. While the focused column is
tabbed, a new window joins it to the right of the active tab. See
[Scroll layout](SCROLL_LAYOUT.md).

`tab_indicator_active_color default` follows the focus ring.
`tab_indicator_inactive_color default` is dark gray. The focus ring and tab
indicators stay hidden while a scroll spring is moving, until the window
arrives.

## Rules

```sh
shoji -m rule --add 'app=^System Settings$' manage=off
shoji -m rule --list
shoji -m rule --remove LABEL
shoji -m rule --apply LABEL
```

`--remove` and `--apply` take a label or a numeric index. Adding a rule with
the same label replaces the previous one. Match keys `app`, `title`, `role`,
and `subrole` are regular expressions. A trailing `!` on the key excludes
matches (`app!=^Finder$`).

Properties: `manage`, `open-floating`, `open-maximized`, `sticky`,
`native-fullscreen`, and `mouse_follows_focus` take `on` or `off`.
`column-width` takes `abs:pixels` or `ratio:fraction`. `column-display` takes
`normal` or `tabbed`. `opacity` is `0` .. `1`. `sub-layer` takes `below`,
`normal`, `above`, or `auto`. `label`, `space`, `display`, `grid`, and
`scratchpad` take a string. `grid` is six colon-separated numbers. `one-shot`
or `--one-shot` retires the rule after one match.

`manage=on` tiles a window that would otherwise stay out because of its role.
`manage=off` leaves it floating. `open-floating` sets the floating flag and
leaves `manage` unset. Column width and column display apply once the window
is in a scrolling column, and column display changes that whole column. A
`column-display=normal` rule on a window that just joined a tabbed column
shows that column as rows.

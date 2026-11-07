# Driving Gantry from scripts

## Links

Gantry opens `gantry://` links. Use them in Shortcuts, scripts or other apps:

| Link | Result |
| --- | --- |
| `gantry://open/dashboard` | Opens the dashboard. |
| `gantry://open/kubernetes` | Opens the Kubernetes browser. |
| `gantry://open/<section>?host=<name>&item=<id or name>` | Opens a host section and selects an item. The sections are `overview`, `containers`, `images`, `volumes`, `networks`, `machines`, `clusters`, `files` and `system`. |
| `gantry://palette` | Opens the command palette. |
| `gantry://settings` | Opens the settings. |

Without `host`, Gantry uses the first host. The `item` value can be an id, an id prefix or a name.

Example: `open "gantry://open/containers?item=web"`.

## Debug builds

A Debug build also listens on a Unix socket, `$TMPDIR/gantry-automation-<pid>.sock`. The socket takes one link on each line. Several Debug copies of the app can run at the same time, and the socket of each copy goes only to that copy. `scripts/gantry-ctl` finds the socket for you:

```
scripts/gantry-ctl open/clusters?item=dev
scripts/gantry-ctl snapshot /path/window.png   # PNG of the main window
scripts/gantry-ctl state /path/state.json      # current selection as JSON
scripts/gantry-ctl appearance light            # light, dark or system
```

`GANTRY_APP` selects the copy when more than one runs. Its value is a part of the path to the `.app`.

The snapshot needs no screen recording permission. It cannot draw the Liquid Glass material of the sidebar, so the sidebar can look blank.

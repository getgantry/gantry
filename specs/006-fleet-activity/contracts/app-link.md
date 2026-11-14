# Contract: gantry://open/usage

- `gantry://open/usage` opens the Resource Usage table in the key main window and closes the command palette.
- Query items `host` and `item` are ignored for this target.
- `AppLink.parse` returns `.open(target: "usage", host: nil or the value, item: nil or the value)`. `usage` is in `AppLink.globalTargets`.
- `scripts/gantry-ctl open/usage` sends the link. `gantry-ctl state` then reports `"selection": "usage"`.

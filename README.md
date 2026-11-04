# Stercorarius

A macOS menu-bar app that sends a dung beetle rolling across your screens for every Claude Code or
Codex session that is working right now. (*Geotrupes stercorarius* is the dor beetle.)

## How it works

- **Claude Code** keeps a registry of running sessions in `~/.claude/sessions/<pid>.json`, with a
  `status` of `busy`, `idle` or `waiting`. Stercorarius reads it once a second and never writes to
  `~/.claude`.
- **Codex** runs desktop threads and TUI sessions inside shared app-server processes, so
  Stercorarius registers Codex hooks: `UserPromptSubmit` runs `'…/Stercorarius' codex-hook busy`;
  `Stop`, `Interrupt` and `SessionEnd` run `'…/Stercorarius' codex-hook idle`. The hook keeps one
  file per working session in `~/.stercorarius/codex/`.
- Each working session gets a beetle. It fades in at a random point, heading a random way, then
  crosses a random display at a random height: left to right, then mirrored right to left. It
  stays above all windows on every Space and lets clicks through. When the session stops
  working, its beetle fades out.

## Install

```sh
make install
```

This builds `Stercorarius.app` into `~/Applications`, appends four hooks to `~/.codex/hooks.json`
(after saving a backup next to it), and starts the app. Then, once:

1. Trust the hooks: start `codex` and accept "Hooks need review" (or run `/hooks`), or open
   ChatGPT.app > Settings > Hooks.
2. Restart Codex sessions and ChatGPT.app; threads that are already loaded keep their old hooks.

Stercorarius does not start at login; open it from `~/Applications`. The menu-bar ladybug shows
how many sessions are working, sets the beetle size (50% by default, 75% or 100%), and quits the
app.

## Uninstall

```sh
make uninstall
```

Quits the app, removes its hooks from `~/.codex/hooks.json` (with a backup), and moves the app and
`~/.stercorarius` to the Trash. Restart Codex sessions and ChatGPT.app afterwards: threads that are
already loaded keep calling the removed hooks.

## Sprites

`Sources/Stercorarius/Resources/Sprites` holds the sprite pack; its `README.md` and
`preview.html` describe it. Each agent has a PNG atlas plus TexturePacker-style JSON
(`claude-code.*`, `chatgpt-codex.*`): frame rectangles, per-frame `durationMs` and
`renderOffsetPx`, the `animations.move_right` frame order, and `meta.pixelRatio`. Frames show
rightward travel; leftward passes mirror them. To change a beetle, replace its two files and run
`make install`.

## Development

```sh
make build   # debug build, warnings are errors
make test    # Swift tests and installer checks
make lint    # swiftlint, swift format, shellcheck, shfmt
make app     # .build/Stercorarius.app
swift run Stercorarius
```

## Known limitations

- A Codex turn that ends in an API error (rate or usage limit) fires no hook; its beetle keeps
  walking until that thread's next `Stop`, `Interrupt` or `SessionEnd`.
- If another Codex `Stop` hook blocks and the turn continues, the beetle leaves early.
- Claude Code's session registry format is undocumented; an update may need a decoder change.
- Codex threads loaded before installation do not run the new hooks until restarted.

# Shpora

**English** · [Русский](README.ru.md)

A tiny macOS app for quick notes that floats above every window. One hotkey opens a live Markdown file; you type, and it is already saved. Open a second file next to it — for example, call questions on the left and answers on the right.

![Two panes: questions on the left, notes on the right](screenshots/split.png)

## What it does

**The window**
- Shows and hides with a global hotkey (⌃⌥J by default, change it in Settings).
- Stays on top of everything, including full-screen apps, and does not take focus away from the app you are in (a dialer, a browser, a call).
- Remembers its size and place, separately for one and two panes.

**Live files**
- The window *is* the file: no Save button. Changes are written to disk within a fraction of a second, and right away when the window hides, the app quits or the Mac sleeps.
- Safe writes (temp file, then swap): a crash or reboot loses at most the last moment of typing.
- If the file changes elsewhere (Obsidian, any editor), the window picks it up. If both sides edited at the same time, nothing is overwritten: your version is saved as a copy next to the file, and you see a short notice.
- The view follows the caret as you type and press Enter.

**Two panes**
- ⌘D, the split icon or the thin "+" on the right edge opens a second file beside the first. Near the screen edge the window slides left so the pane fits.
- Drag the divider to resize; ⌘[ / ⌘] jump between panes; ⌘W closes the second pane.
- Pick any file from the menu under its name; add or create files from there.

**Little things**
- ⌘T inserts a timestamp line (`#### 09.11 10:42 · `) — handy to start a new entry.
- ⌘O opens the file in its default app, ⌘F searches, ⌘+ / ⌘− / ⌘0 change text size, Esc hides the window.
- Shortcuts work on any keyboard layout (they follow the physical key).
- Three backgrounds: glass, clear glass, solid. Optional Dock and menu-bar icons, open at login.
- Interface in English and Russian.
- Coming from Markie? On first launch Shpora picks up its file list (read-only, Markie is not touched).

| Shortcuts | Look |
|---|---|
| ![Shortcuts settings](screenshots/settings-shortcuts.png) | ![Background and text size](screenshots/settings-look.png) |

## What it doesn't do (on purpose)

- No Markdown rendering: you see and edit the plain text.
- No sync, accounts or cloud — files live where you put them (put them in iCloud Drive or Dropbox if you want sync).
- No version history, daily notes or task lists.
- No ready-made download yet: you build it from source (below).
- macOS 26 or later only.

## Planned

- Auto-update (Sparkle).
- A signed and notarized build to download from Releases, so you don't need Xcode.
- Homebrew install.

Ideas and bug reports are welcome in Issues.

## Build and install

You need macOS 26+, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/nagornik-icloud/shpora.git
cd shpora
scripts/build.sh
```

The script builds a Release version, signs it (your Apple Development certificate if you have one, otherwise ad-hoc) and copies it to `/Applications/Shpora.app`. Then open Shpora and press ⌃⌥J.

## Credits

Global hotkeys: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT).

## License

[MIT](LICENSE)

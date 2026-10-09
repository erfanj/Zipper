# Installing Universal Archiver

## Install

1. Open `UniversalArchiver-<version>.dmg`.
2. Drag **Universal Archiver** onto **Applications**.
3. Open it from Applications. (A build that was not notarized must be opened once with right-click ›
   Open, or allowed in System Settings › Privacy & Security.)

Optional:

* **Finder Quick Actions** — right-click files in Finder › Quick Actions / Services. Enable or hide
  individual actions in System Settings › Keyboard › Keyboard Shortcuts › Services.
* **Default app** — Settings › Integrations › "Make Universal Archiver the default for common
  archives…" (it never changes defaults on its own).
* **Command-line tool** — Settings › Integrations shows the command to link `archiver` into
  `/usr/local/bin`.
* **Legacy formats** — install The Unarchiver's command-line tools (`brew install unar`) for StuffIt,
  Compact Pro, ARC, Zoo, Amiga formats and more; `brew install zpaq lrzip lzop` for those formats.
* **RAR creation** — install RARLAB's `rar` and license it; Universal Archiver will use it.

## Uninstall

1. Quit Universal Archiver and drag it from Applications to the Trash.
2. Optionally remove its data:
   * `~/Library/Application Support/Universal Archiver` (presets, history)
   * `~/Library/Caches/UniversalArchiver` (helper probe cache)
   * `~/Library/Preferences/com.example.universalarchiver.plist` (settings)
   * Saved archive passwords: Keychain Access › search "Universal Archiver" and delete the items.
3. If you linked the CLI: `sudo rm /usr/local/bin/archiver`.

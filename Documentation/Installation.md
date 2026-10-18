# Installing Zipper

## Install

1. Open `Zipper-<version>.dmg`.
2. Drag **Zipper** onto **Applications**.
3. Open it from Applications. (A build that was not notarized must be opened once with right-click ›
   Open, or allowed in System Settings › Privacy & Security.)

Optional:

* **Finder Quick Actions.** Control-click files in Finder and look under Quick Actions (or Services).
  To choose which actions appear, see System Settings › Keyboard › Keyboard Shortcuts › Services, or
  Zipper's Settings › General.
* **Default app.** Settings › General › "Open Archives with Zipper…". Zipper never changes your
  defaults on its own.
* **Command-line tool.** Settings › Advanced › Command line shows the command that links `zipper`
  into `/usr/local/bin`.
* **Legacy formats.** Install The Unarchiver's command-line tools (`brew install unar`) for
  StuffIt, Compact Pro, ARC, Zoo, Amiga formats and more. `brew install zpaq lrzip lzop` adds those
  formats.
* **RAR creation.** Install and license RARLAB's `rar`; Zipper uses it.

## Uninstall

1. Quit Zipper and drag it from Applications to the Trash.
2. Optionally remove its data:
   * `~/Library/Application Support/Zipper` (presets, history)
   * `~/Library/Caches/Zipper` (helper probe cache)
   * `~/Library/Preferences/com.erfanj.zipper.plist` (settings)
   * Saved archive passwords: Keychain Access › search "Zipper" and delete the items.
3. If you linked the CLI: `sudo rm /usr/local/bin/zipper`.

# User guide

Zipper has one main window. Its sidebar lists **Home**, the archives you have open, and
**Activity**. Occasional utilities live in the **Tools** window, and preferences are in **Settings** (⌘,).

## Everyday use

**Open an archive.** Double-click it (once Zipper is your default app), drop it on the window or the
Dock icon, or choose **File › Open…** (⌘O). It opens in the sidebar and you browse it like a Finder
folder, without extracting anything. If you'd rather extract right away, set
**Settings › General › When you open an archive** to *Extract it right away*.

**Extract.** In an open archive, click **Extract All** (⌘E), or select items and click **Extract**.
The files go next to the archive. **Extract To…** (⌥⌘E) asks where. **File › Extract Archive…**
(⇧⌘E) opens the extract sheet with every option:

* **Folders.** *Automatic* puts the contents in a new folder named after the archive, unless the
  archive already holds a single folder (no "folder inside a folder"). You can also choose
  *Always in a new folder* or *Directly in the destination*.
* **If an item exists.** The default is *Keep both*: the new copy gets a number, and nothing is ever
  overwritten silently. You can also choose *Replace*, *Skip*, *Replace older files* or *Ask each time*.

You're asked for a password only when an archive needs one, and only once for all parts of a
multi-part archive. You can save it in your keychain, protected by Touch ID if you like.

**Compress.** Drop files on the window, or use **File › New Archive…** (⌘N), or select them in Finder
and choose **Quick Actions › Compress to ZIP**. The sheet shows:

* **Name** and **Format.** ZIP opens everywhere. 7z is smaller and can hide file names. Disk images
  and Apple Archive are Mac-only. Less common formats are further down the menu.
* **Compression:** *Faster*, *Normal* or *Smaller*.
* **Encrypt with a password.** Use **Suggest Strong Password** and **Copy** to send it separately.
  The sheet tells you what's protected: ZIP encryption hides contents but not names, while 7z with
  *Also hide the file names* hides both.
* **Split into parts**, e.g. for upload limits: `250 MB`, `1.5 GB`, or a common size from the menu.
* **Advanced Options** for the method, exact level, dictionary, solid blocks, threads, Mac metadata,
  symbolic links and exclusions. **Presets** applies a saved combination, and
  *Save Current Settings as Preset…* keeps yours.
* **Suggest Settings** compresses a small sample of your files and recommends a format.

`.DS_Store`, `__MACOSX` and `Thumbs.db` are left out by default. The sheet shows how many items will
be left out and lets you review them.

## Browsing and editing

* **List**, **Columns** and **Icons** views, with sorting by any column in the list. **Search**
  looks through the whole archive.
* **Space** (or ⌘Y) previews the selected file with Quick Look. Double-click (or Return) opens
  folders in place, opens nested archives in Zipper, and opens documents in their default app.
  Apps and scripts are never run; they're shown in Finder instead.
* **Drag items out** to Finder to extract just those. **Drop files in** to add them (you're asked
  first).
* **Archive** menu: Add Files (⌥⌘A), New Folder (⇧⌘N), Rename, Delete (⌘⌫). Every edit rebuilds the
  archive in a temporary file and checks it. Only then does it replace the original, so a failure
  never damages your archive. Encrypted archives stay encrypted.
* **Edit in Default App** (Control-click a file) opens it in its app. When you save, Zipper asks
  whether to update the archive.
* **Info** (⌘I) shows the format, compression, encryption, sizes, savings and the selected item's
  details. **More › Show Analysis** shows where the space goes.
* Signed packages (APK, IPA, JAR, PKG…) aren't edited unless you accept that their signature will no
  longer be valid.

## Activity

The toolbar's **Activity** button and the sidebar show running work: progress, speed, time left,
**Pause** and **Stop**. Stopping never leaves half-written files. The Dock icon shows overall
progress, and when Zipper is in the background you get a notification when work finishes.
**History** lists past operations. It stays on your Mac and never includes file contents or
passwords; you can turn it off in Settings › Privacy.

## Tools (Tools menu, or the toolbar's wrench)

* **Test Integrity** decodes everything and checks stored checksums. Passing means "intact", not
  "safe".
* **Repair** analyses damage, rebuilds a ZIP's directory, uses RAR recovery records (with RARLAB's
  `rar` installed), and recovers readable files into a new folder with a report. The damaged file is
  never changed.
* **Convert**, for example RAR → ZIP, ZIP → 7z or TAR.GZ → TAR.ZST. It warns about anything the new
  format can't keep, and checks every file by SHA-256 against the original.
* **Batch Extract** handles many archives at once. Multi-part sets are extracted once.
* **Checksums** calculates SHA-256/512, CRC-32 and MD5/SHA-1 (legacy), compares them with a pasted
  value, and saves or verifies `sha256sum`-style files.
* **Split & Join** cuts any file into `.001` parts and joins them back with verification.
* **Compare** and **Find Duplicates** compare archives' contents.

## Finder integration

Control-click files in Finder and look under **Quick Actions** (or **Services**). You'll find
*Compress to ZIP*, *Compress to 7z*, *Compress with Options…*, *Extract Here*,
*Extract to New Folder*, *Extract To…*, *Show Archive Contents*, *Test Archive…*,
*Convert Archive…* and *Calculate Checksum…*. **Settings › General** links to where you can choose
which ones appear, and can make Zipper the default app for common archive types. Press Space on an
archive in Finder to preview its contents through Zipper's Quick Look extension.

## Settings worth knowing

* **Compression:** the default format and level for new archives, plus your saved presets
  (export/import).
* **Extraction:** the default destination and folder arrangement. **Safety limits** cover total
  size, single file, item count, compression ratio, nesting and disk reserve; they stop "zip bombs".
  Raise them only for archives you trust.
* **Privacy:** saved passwords (Touch ID protection, removal) and history.
* **Advanced:**
  * **Speed:** *Maximum Performance* uses all cores, *Balanced* the performance cores, *Energy
    Saver* the efficiency cores. Low Power Mode and heat lower the speed automatically.
  * **Old file name encoding** fixes garbled names in old archives (Shift-JIS, GBK, CP866…).
  * The command-line tool, engines and supported formats, and diagnostics.

## Command line

```
zipper compress Project -o Project.7z --encrypt aes256 --hide-names
zipper extract archive.rar -o ~/Downloads --verify
zipper list backup.zip --json
zipper test *.zip
zipper convert old.rar --to zip
zipper hash file.iso --algo sha256
zipper formats
```

To install it: Settings › Advanced › Command line shows a one-line command that links
`Zipper.app/Contents/Helpers/zipper` into `/usr/local/bin`. Run `zipper help` for everything.
Passwords are typed at a hidden prompt or piped with `--password-stdin`, never given as arguments.
Ctrl-C cancels cleanly; press it twice to quit immediately.

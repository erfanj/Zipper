# User guide

## Everyday use

**Open an archive** — double-click it (when Universal Archiver is your default), drop it on the
window or Dock icon, or choose **Open**. You see its contents like a folder, without extracting.
Settings › General lets a double-click extract immediately instead.

**Extract** — click **Extract**. *Smart Extract* puts a single top-level folder directly next to the
archive and wraps loose files in a folder named after the archive. *Extract Here* merges into the
current folder; *Extract to New Folder* always makes a folder. If a file already exists you get
**Keep Both** by default (the new copy gets a number) — Replace, Skip, Replace older files, or Ask
are available in the form and in Settings. You are asked for a password only if the archive needs
one, and only once for all parts of a multi-part archive.

**Compress** — select files in Finder and use Quick Actions › *Compress to ZIP*, or drag them onto
the window and click **Create Archive**. The defaults produce a ZIP anyone can open. Pick a different
**Compression** preset (Fastest, Balanced, Smallest File, Maximum Compatibility, Secure, Mac Backup,
Cross-Platform Sharing) or **Recommend Settings** to have a sample of your files measured.

**Encrypt** — turn on **Encrypt archive**, enter a password or click **Generate Strong Password**,
then **Copy** to send it separately. The form explains what is protected: ZIP AES hides contents but
not names; 7z with *Encrypt file names* hides both.

**Split** — turn on **Split archive** and choose a size (presets for CDs, DVDs, FAT32, Blu-ray, or a
custom value like `250 MB` or `1.5 GB`). Split archives require 7z or ZIP (7-Zip engine).

## Browsing and editing

* List, column, icon and gallery views; sort by any column; search names, extensions and types.
* Select a file to preview it (Quick Look for documents and media, a code view with line numbers
  and Find for text). Large files and very large solid archives are not previewed automatically.
* Drag files out of the browser to extract them to that place; drag files in to add them.
* Edit › Add Files, New Folder, Rename, Delete. Every edit rebuilds the archive in a temporary file,
  verifies it, and only then replaces the original. Encrypted archives keep their encryption.
* *Edit in Default App* opens a file from the archive; when you save it, you are asked whether to
  update the archive.
* Signed packages (APK, IPA, JAR, PKG…) are not edited unless you accept that the signature will
  become invalid.

## Tools

* **Integrity Verification** — decodes everything and checks stored checksums. A pass does not mean
  "safe"; it means "intact".
* **Archive Repair** — analyses damage, estimates what is recoverable, rebuilds a ZIP's directory,
  uses RAR recovery records when the RAR tool is installed, and recovers readable files into a new
  folder with a report. The damaged file is never changed.
* **Convert** — e.g. RAR → ZIP, ZIP → 7z, TAR.GZ → TAR.ZST. Warnings list anything the target
  format can't keep (encryption, hidden names, permissions, extended attributes, links). Every
  converted file is checked by SHA-256 against the original.
* **Checksums** — SHA-256/512, CRC-32, MD5/SHA-1 (labelled legacy); compare with a pasted value;
  save and verify `sha256sum`-style manifests.
* **Split / Join** — byte-split any file into `.001` parts with a SHA-256 manifest, and join them back
  with verification. (Different from multi-part ZIP/7z, which open directly.)
* **Compare Archives**, **Find Duplicates**, **Batch Extract**, **History**.

## Settings worth knowing

* **Interface level** (General): Simple hides specialist tools; Expert shows every compression
  parameter (dictionary, word size, solid blocks, threads).
* **Safety limits** (Extraction): total size, single file, file count, compression ratio, nesting,
  disk reserve. Only raise them for archives you trust.
* **Performance** — Maximum Performance (all cores), Balanced (performance cores), Energy Saver
  (efficiency cores). Low Power Mode and thermal pressure lower the mode automatically.
* **Passwords** (Security): save to the Keychain, require Touch ID, remove saved passwords.
* **Legacy file name encoding** (Advanced): for old archives whose names look garbled (e.g. Japanese
  Shift-JIS, Chinese GBK, Russian CP866).

## Command line

```
archiver compress Project -o Project.7z --encrypt aes256 --hide-names
archiver extract archive.rar -o ~/Downloads --verify
archiver list backup.zip --json
archiver test *.zip
archiver convert old.rar --to zip
archiver hash file.iso --algo sha256
archiver formats
```

Run `archiver help` for everything. Passwords are typed at a hidden prompt or piped with
`--password-stdin`, never given as arguments. Exit codes are listed in the help.

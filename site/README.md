# Zipper website

The landing page for Zipper (The Basics Well Made Series), live at
**<https://erfanj.github.io/zipper/>**. It's plain HTML, CSS and JavaScript, with no build step and no
dependencies.

| File | What it is |
|---|---|
| `index.html` | The page |
| `styles.css` | Design (Light and Dark Mode follow the visitor's Mac) |
| `main.js` | Download button, screenshot tabs, scaling of the window drawings, scroll reveal |
| `config.js` | **The only file you normally edit**: the DMG download link, version and size, and notarization status |
| `assets/` | App icon, favicons, social preview image (`og.jpg`), optional real screenshots |

## Where things live

| Repository | Purpose |
|---|---|
| [`erfanj/Zipper`](https://github.com/erfanj/Zipper) | Source, this `site/` folder (the source of truth for the page) and the DMG [releases](https://github.com/erfanj/Zipper/releases). |
| [`erfanj/erfanj.github.io`](https://github.com/erfanj/erfanj.github.io) | The published website. This folder is copied to its `zipper/` folder, and GitHub Pages serves it at `https://erfanj.github.io/zipper/`. |

Edit the page here, then publish the copy.

## Preview locally

```sh
cd site && python3 -m http.server 8000
```

Then open <http://localhost:8000>.

## Publish a change to the website

```sh
git clone https://github.com/erfanj/erfanj.github.io ../erfanj.github.io   # once
rsync -a --delete --exclude README.md --exclude '.DS_Store' site/ ../erfanj.github.io/zipper/
cd ../erfanj.github.io && git add -A && git commit -m "Update Zipper page" && git push
```

GitHub Pages republishes within a minute or two.

## Publish a new version of Zipper

1. Build the DMG (`Scripts/release.sh`, see `Documentation/Distribution.md`) and publish it as a
   release of `erfanj/Zipper`, with `Zipper-<version>.dmg` and `Zipper-<version>.dmg.sha256`
   attached.
2. Update `download` in `config.js` (`url`, `checksumUrl`, `version`, `size`). Every download button
   on the page links straight to `url`.
3. In `index.html`, replace the old version with the new one (the links, the file name and the
   "Version · size" lines). They're the fallback for visitors without JavaScript.
4. Publish the website (above).

## Use your own domain later

1. In `erfanj/erfanj.github.io`: Settings › Pages › Custom domain, e.g. `basicswellmade.com`.
2. At your DNS provider, add `A` records for the apex domain pointing to `185.199.108.153`,
   `185.199.109.153`, `185.199.110.153` and `185.199.111.153` (or a `CNAME` to `erfanj.github.io`
   for a subdomain).
3. Tick **Enforce HTTPS** once the certificate is issued.
4. Update the `og:url`, `og:image` and `canonical` URLs in `index.html` to the new address.

## After you notarize

Set `notarized: true` in `config.js`. The "Open Anyway" instructions then disappear from the install
section.

## Real screenshots

The app windows are drawn in HTML/CSS so the page looks finished without any images. To use real
captures, see `assets/screenshots/README.md`. Drop the files in and they replace the drawings.

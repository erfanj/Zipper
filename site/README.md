# Zipper website

A static landing page for Zipper (The Basics Well Made Series). It's plain HTML, CSS and JavaScript,
with no build step and no dependencies. It works on GitHub Pages, Cloudflare Pages, Netlify or any
static host.

| File | What it is |
|---|---|
| `index.html` | The page |
| `styles.css` | Design (Light and Dark Mode follow the visitor's Mac) |
| `main.js` | Download button, screenshot tabs, scaling of the window drawings, scroll reveal |
| `config.js` | **The only file you normally edit**: repository and notarization status |
| `assets/` | App icon, favicons, social preview image (`og.jpg`), optional real screenshots |

## Preview locally

```sh
cd site && python3 -m http.server 8000
```

Then open <http://localhost:8000>.

## How the download button works

On load, the page asks GitHub's API for the latest release of the repository in `config.js`. It
links the button to the first `.dmg` asset and shows its version and size, plus the `.sha256` if
there is one. The release workflow (`.github/workflows/release.yml`) attaches both. If the API can't
be reached, the button links to `https://github.com/<repo>/releases/latest` instead.

**The repository in `config.js` must be public.** Visitors can't see releases of a private repo.

## Publish on GitHub Pages

GitHub Pages on a free account needs a public repository. Pick one of these:

### A. Make this repository public

1. Settings › General › Danger Zone › Change visibility › Public.
2. Settings › Pages › Build and deployment › Source: **GitHub Actions**.
3. Merge to `main`. `.github/workflows/pages.yml` publishes `site/` to
   `https://erfanj.github.io/Zipper/`.

### B. Keep the source private and use a public repository for the site and releases

1. Create a public repository, for example `erfanj/zipper-app` (or `basicswellmade.github.io` if
   you'll host the whole series there).
2. Copy the contents of `site/` into its root and push.
3. In that repository: Settings › Pages › Source: **Deploy from a branch** › `main` / `(root)`.
4. Publish DMGs as releases of that public repository, and set `repo` in `config.js` to it.

## Use your own domain

1. Settings › Pages › Custom domain: enter e.g. `zipper.yourdomain.com`, or `yourdomain.com`.
2. At your DNS provider:
   * subdomain: a `CNAME` record pointing to `erfanj.github.io`;
   * apex domain: `A` records to `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and
     `185.199.111.153`.
3. Tick **Enforce HTTPS** once the certificate is issued (it can take up to an hour).
4. Change `og:image` in `index.html` to the absolute URL, e.g.
   `https://yourdomain.com/assets/og.jpg`. Link previews in Messages, Slack and X need an absolute
   URL.

## After you notarize

Set `notarized: true` in `config.js`. The "Open Anyway" instructions then disappear from the install
section.

## Real screenshots

The app windows are drawn in HTML/CSS so the page looks finished without any images. To use real
captures, see `assets/screenshots/README.md`. Drop the files in and they replace the drawings.

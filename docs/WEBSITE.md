# Project website

The landing page lives in `site/`. It is plain HTML and CSS with local images:
no external fonts, analytics, package manager or build step. A small optional
script adds Copy buttons; commands remain selectable without JavaScript.
Only `site/` is uploaded to GitHub Pages.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8000 --directory site --bind 127.0.0.1
```

Open <http://127.0.0.1:8000>. Check the page at desktop and phone widths and
with keyboard navigation. All assets use relative paths so the page also
works under the `/pipe-plot/` project path. Stop the server with Ctrl-C.

## Publish on GitHub Pages

1. In the repository's **Settings → Pages**, choose **GitHub Actions** as the source.
2. Commit and push the website and `.github/workflows/pages.yml` to `main`.
3. The **Deploy project website** workflow publishes the site. It can also be
   started manually from Actions on `main`.

The project address is <https://alchemyst.github.io/pipe-plot/>. The repository's
About section links to it. Subsequent pushes that change `site/` or the Pages
workflow redeploy automatically.
See [GitHub's custom workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Content and assets

- `site/index.html`: copy, links, metadata and page structure.
- `site/style.css`: neutral dark panels and system fonts matching the native app.
- `site/copy.js`: copy buttons with a text-selection fallback when clipboard access is unavailable.
- `site/assets/icon.png`: generated from the project's icon sources in `design/icon/`.
- `site/assets/pipeplot.jpg`: actual native app screenshot captured on
  14 November 2026 with synthetic inlet/outlet temperature samples, explicitly
  identified as synthetic in the page caption. No user measurements are shown.

The source-build instructions reflect the current macOS 27 / Apple Silicon
requirements. The website and README link directly to the v0.2.0 unnotarized
preview and label it as such. GitHub's `/releases/latest` endpoint does not
select prereleases, so keep the explicit versioned download link until a
stable release is available. Update both locations for subsequent releases.
See [the release guide](RELEASING.md) for packaging and installation checks.
Update the canonical and Open Graph URLs if the hosting address changes.

## Initial verification — 14 November 2026

- Browser review at 1280 px and 390 px; no horizontal overflow at either
  width or at 320 px. Images loaded, the build-section link navigated correctly,
  and the keyboard skip link showed focus and moved to the main content.
- Site assets, section anchors, GitHub document targets and moved Markdown
  links checked against the checkout; relative URLs retain `/pipe-plot/`.
- `actionlint` 1.7.12 and `git diff --check` passed.
- No deployment has been run. Links to newly added documents on GitHub become
  available when those files are pushed. The native app was not changed, so
  its build and test suites were not rerun.


## Utility-focused revision — 14 November 2026

Replaced the promotional copy with an explanation of stdin plotting and five
runnable examples. Styling follows the native app's neutral dark surfaces,
system typography and restrained green accents. Examples cite the
[ttyplot README](https://github.com/tenox7/ttyplot#examples),
[wesplot examples](https://github.com/cactusdynamics/wesplot#example-use-cases)
and [pv manual](https://www.ivarch.com/programs/quickref/pv.shtml).
The direct description and documentation structure were also informed by the
[ripgrep README](https://github.com/BurntSushi/ripgrep).

All five displayed commands ran in zsh against the built `pp` and a native
PipePlot process with an isolated database/socket. RSS, load, loopback ping
and each test signal stored five samples before an intentional interrupt;
the pv example completed normally with 20 numeric rate samples and no parser
diagnostics. The pv producer was also checked in bash. Its grouped redirection
avoids zsh's multios behavior sending binary payloads into the numeric pipe.

Browser checks covered 1280, 390 and 320 px with no horizontal overflow,
loaded images and working section navigation. The Copy handler reported
success; the in-app browser's clipboard inspection returned an empty value,
so exact clipboard transfer could not be independently verified there.
Commands remain selectable and the script provides a selection fallback if
clipboard writes are rejected. Local link checks, `node --check site/copy.js`
and `git diff --check` passed. The installation command was not rerun.

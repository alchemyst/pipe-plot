# Contributing to PipePlot

Bug reports, documentation improvements and focused pull requests are welcome.
For substantial changes, open an issue first so we can discuss the approach.

## Report a problem

[Open an issue](https://github.com/alchemyst/pipe-plot/issues) with your macOS
version, PipePlot version or commit, the command you ran, and what you expected
to happen. Include the smallest input that reproduces it. Use synthetic data
and remove private information from logs and screenshots.

## Make a change

Follow the [development guide](docs/DEVELOPMENT.md) to build locally. Keep pull
requests focused and describe the user-visible change and how you verified it.

For Swift changes, run:

```sh
just format-check
just check
```

Exercise changed UI interactions in the actual app, and describe any checks
you could not complete. The [validation guide](docs/VALIDATION.md) covers
native interaction scenarios. Documentation-only changes need working links
and accurate examples; they do not require building the macOS app.

For the landing page, follow [the website guide](docs/WEBSITE.md). The site is
plain HTML and CSS, with no package installation or build step.

Contributions are made under the project's [MIT license](LICENSE).

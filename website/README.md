# OwlLuna website

The site for [OwlLuna](https://github.com/owaisazmal/OwlLuna): what the app does, a note from its developer, [screenshots from its making](app/prototypes/page.tsx), the [Privacy Policy](app/privacy/page.tsx) and the [Support](app/support/page.tsx) page. It's a static Next.js export; nothing runs on a server.

## Running it

```bash
cd website
```

```bash
npm install
```

```bash
npm run dev
```

`npm run build` writes the site to `website/out`.

## Checks

A pull request that touches `website/` runs lint, the typecheck, a build under `/OwlLuna` as on GitHub Pages, a link check and an accessibility pass. To run the last three locally:

```bash
export BASE_PATH=/OwlLuna NEXT_PUBLIC_SITE_URL=https://owaisazmal.github.io/OwlLuna
```

```bash
npm run build && npm run check:links && npm run check:a11y
```

- `npm run lint`: ESLint with Next's rules and jsx-a11y. typescript-eslint can't read TypeScript 7 yet, so lint uses TypeScript 6 (`typescript6` in `package.json`) while the typecheck and build use 7. Keep `typescript6` on 6.0 until that changes.
- `npm run check:links`: serves `out/` under the base path and follows every internal link, image, stylesheet, font and anchor, so a link missing `/OwlLuna` fails. External links aren't checked.
- `npm run check:a11y`: opens each page in Google Chrome, light and dark, with Reduce Motion on, and fails on serious or critical [axe](https://github.com/dequelabs/axe-core) findings. Needs Chrome installed.

## What to change when

Everything that varies is in [lib/site.ts](lib/site.ts):

- `appStoreUrl`: the App Store page. Once set, the buttons link to it.
- `testFlightUrl`: the public beta. While `appStoreUrl` is empty, the home page's main button and the Support page link here. With both empty, the home page says "Coming soon to the App Store".
- `contactEmail`: for privacy and support questions. While empty, the pages point to GitHub Issues.
- `policyUpdated`: the date on the Privacy Policy. Change it whenever the policy's wording changes.

The Privacy Policy describes what the app's code does. If an app change affects what is stored, synced, read or shared, update [app/privacy/page.tsx](app/privacy/page.tsx) in the same pull request.

## Layout

- `app/`: the pages (home, `prototypes/`, `privacy/`, `support/`), the root layout and the design tokens in `globals.css`.
- `components/ui/`: the app's controls rebuilt for the web (cloth and plate buttons, Card, Ledger, Stamp, index cards, covers, study tape, the splash lettering).
- `components/hero/`: the launch splash as the page's opening, with tiles and timings taken from `OwlLuna/Launch/`.
- `components/sections/` and `components/support/`: the parts of the home and Support pages.
- `components/prototypes/`: the screenshots saved while the app was being made. `shots.ts` holds their order, captions and layout. The images are in `public/prototypes/` as WebP in three sizes: `name.webp` (full), `name-m.webp` (up to 1100 px wide) and `name-t.webp` (up to 640 px wide).
- `lib/`: site settings, fonts and motion curves.

The look follows [docs/DESIGN.md](../docs/DESIGN.md). Printed things (tiles, covers, index cards) keep their colours at night; everything else follows the light and dark tokens. Animation uses [Motion](https://motion.dev). With Reduce Motion nothing moves, the hero's ticker has a pause button, and visitors without scripts see the finished scene.

## Fonts

Libre Franklin sets the site's own text. Fraunces, Archivo and Bricolage Grotesque, the three the app bundles, appear only in the hero and in pictures of the app (`--font-app`, `.app-display`, `.caps`). All four come from the `@fontsource-variable` packages and are served from the site, under the SIL Open Font License. The app's three licence texts are in [OwlLuna/Resources/Fonts](../OwlLuna/Resources/Fonts); Libre Franklin's comes with its package.

## Publishing

[.github/workflows/website.yml](../.github/workflows/website.yml) builds the site and publishes it to GitHub Pages whenever `website/` changes on `main`. It needs Settings › Pages › Source set to "GitHub Actions", once. The site is then at `https://owaisazmal.github.io/OwlLuna/`. The workflow reads the address from Pages, so a custom domain needs no change here.

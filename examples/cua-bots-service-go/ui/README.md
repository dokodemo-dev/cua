# Browser UI sources

The service serves one page, one stylesheet, and one script, embedded from
`../internal/api/ui/`. This directory holds the TypeScript that produces
`app.js`; the HTML and CSS are edited in place under `../internal/api/ui/`.

```text
ui/
  src/*.ts        TypeScript sources (bundled)
  build.mjs       esbuild bundle into ../internal/api/ui/app.js
  tsconfig.json   type check only (no emit)
  .oxlintrc.json  lint rules
  .oxfmtrc.json   formatting rules
```

## Commands

```sh
aube install        # once, from this directory
aube run build      # rewrite ../internal/api/ui/app.js
aube run check      # type check, bundle drift, lint, format check
aube run format     # format these sources in place
```

`go build` and `go test` never need Node: the bundle is committed and embedded.
`aube run check` fails when the committed bundle no longer matches `src/`, which
is the only way the two can drift.

## Why the bundle is committed

The service ships as a single Go binary to a VPS that has no Node toolchain.
Generating the bundle at Go build time would make `go test` depend on Node, and
serving sources directly would need a bundler in the browser. Committing
`app.js` keeps the Go build hermetic; the drift check keeps it honest.

## Where a change goes

| Change                             | File                                      |
| ---------------------------------- | ----------------------------------------- |
| Layout, dialog markup              | `../internal/api/ui/index.html`           |
| Colours, spacing, responsive rules | `../internal/api/ui/app.css`              |
| Behaviour, rendering, API calls    | `src/*.ts`                                |
| New endpoint or payload shape      | `../internal/api/*.go`, then `src/api.ts` |

Run `aube run check` before committing. If the UI changes behaviour, also run
`go test ./...` in the parent directory and open the page once against a local
service (see the example's README).
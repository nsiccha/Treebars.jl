# Documentation

The site has four navigation groups, in this order.

| Group | Page | Purpose |
| --- | --- | --- |
| Start | `src/index.md` | Install Treebars and run a complete progress example. |
| Guides | `src/instrumentation.md` | Attach counters and nested work to the intended parent. |
| Guides | `src/phases.md` | Distinguish finished, failed, reused and skipped work. |
| Guides | `src/monitoring.md` | Read a running tree through text, snapshots or a replica. |
| Examples | `src/batch.md` | Process a batch and inspect its retained phase counts. |
| Reference | `src/api.md` | Look up instrumentation, lifecycle and formatting APIs. |
| Reference | `src/observation.md` | Look up text, snapshot and mirror APIs. |
| Reference | `src/web.md` | Look up HTML, polling, WebSocket and language APIs. |

`make.jl` runs `lint.jl`, executes examples and checks exported docstrings.
The batch figure comes from AlgebraOfVega and the executed `phase_overview`.
Generated assets belong in `docs/build/`, never in git. No fits or external
datasets are needed. The example's Reproduce footer records the build's
package, Julia version and source revision.

Shared theme tokens, lint and figure embedding should move to DocsKit when
available. This site uses VitePress defaults and local palette variables;
it does not copy another package's theme or widgets.

## Build

Run `julia --project=docs docs/instantiate.jl`, then
`julia --project=docs docs/make.jl`. The setup script fetches the exact public
commits in `dependencies.toml` into ignored `docs/.deps/`, develops them with
this checkout in one resolve, and instantiates registered dependencies.
CI uses the same commands. No GitHub token is required for dependency reads.
`Manifest.toml`, `.deps/`, `node_modules/` and `build/` remain untracked.

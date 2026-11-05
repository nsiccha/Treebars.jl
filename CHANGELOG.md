# Changelog

All notable changes to Treebars.jl are documented here, newest first.

Every landing that adds or changes public API (an export, a keyword, a method,
or documented behaviour a dependant can call) bumps the patch digit in
`Project.toml` and adds its entry under a new heading at the top of this file.
An entry that breaks something a dependant relies on says **Breaking:** and
what to change. A package or app that calls that API states the version as its
floor, for example `[compat] Treebars = "0.1.1"`, so an environment that pins
an older Treebars commit is refused when it resolves instead of failing at run
time. Changes before 0.1.1 are recorded in the git history only.

## 0.1.6

- New: a progress tree can be shown live in another process.
  `mirror_progress(send, node; interval=0.05)` (also a do-block form) follows
  the tree and passes `ProgressFrame`s to `send`; `progress_replica(target;
  on_interrupt)` plus `apply_frame!(replica, frame)` turn them into an ordinary
  `ProgressNode{StateProgress}` tree under `target`, which every renderer and
  poller draws as it draws the source. `request_interrupt!` on the replica
  calls `on_interrupt(id)`, and `request_interrupt!(mirror, id)` passes the
  request on to the source node. `close`, `isopen` and `flush` work on a
  `ProgressMirror`. Frames carry only what changed; the first and final ones
  carry the whole tree.
- `request_interrupt!` now counts as a change of the tree: an open snapshot
  file that is due writes the "interrupt requested" marker at once instead of
  at the next other change.
- An app's own words for a package's notes (`treebar_texts(…, table => (…))`)
  now also apply to a copy of that table with the same words, such as one in a
  note that came from another process. Two different tables with exactly the
  same words are therefore treated as one.

## 0.1.5

- A pushed answer (`window.treebarUpdatePoller`) is now offered to
  `htmx:beforeSwap` on the polling element before it lands, as htmx offers a
  poll answer. It was swapped directly, so a page's swap gate or rewrite never
  saw it. The detail has a poll answer's fields, without `xhr` since no request
  ran, plus `treebarPushed: true`. A listener can skip the answer
  (`shouldSwap = false` or `preventDefault()`), which still confirms the poller
  live, or change `serverResponse`, `target`, `selectOverride`, `ignoreTitle`
  and the style in `swapOverride` (its modifiers have no effect). A listener
  that reads `detail.xhr` unguarded now throws on a pushed answer, which the
  browser reports; the answer still lands. Guard it.

## 0.1.4

- A poller's first pushed answer (`window.treebarUpdatePoller`) no longer
  aborts a poll already in flight. htmx reports every aborted request as an
  error, so each such push wrote two `console.error` lines and fired
  `htmx:error` twice on a healthy page. That poll now finishes and its answer
  is dropped before htmx reads it: it changes nothing on the page, and the
  page's own `htmx:beforeOnLoad` listeners do not see it. Its bytes are still
  downloaded, at most one poll per time a poller enters push mode. If it fails,
  htmx still reports that, but the poller does not read "Connection lost" on
  its account while the push source is alive. Failed polls of a poller that is
  not pushed are reported as before.

## 0.1.3

- A phase marker's label may be a conditional choosing between string
  literals: `@progress fast ? "Quick fit" : "Full fit"`, or an `if` /
  `elseif` / `else` chain whose every branch is a string. It is evaluated once,
  before any phase runs, like an interpolated label, and works wherever
  `@progress "label"` does (`begin` blocks, loop bodies, `@progress_scope`,
  DynamicObjects property bodies). Before, the marker was read as a wrapper
  around plain code: no phase appeared and its time went to the previous
  phase, with no warning.
- A one-argument `@progress x` inside a `@progress` block that would do
  nothing now fails at macro expansion, naming `@progress "$(x)"` for a
  computed label, `@progress "label" x` for a node of its own, or plain `x`.
  This applies when `x` is a name, a call, an index, or a conditional that is
  not between strings, and `x` contains no loop or nested `@progress`. Such a
  form used to run as plain code and add no node. One-argument loops, `map`,
  comprehensions, `begin … end` blocks, assignments (`@progress name = …`,
  DynamicObjects' property marker), definitions and macro calls are lowered as
  before.

## 0.1.2

- A `@progress node begin … end` block (and `Treebars.@progress_scope node
  begin … end`) finishes its last phase when the block ends. Before, a block
  that ran its phases on a node it did not create left that phase `▶` running,
  its time growing, until something finalized the node, so a caller that kept
  working under the node showed the block's last phase as the current one. On
  an early `return` or `break` the phase control was in finishes the same way.
  A dependant that relies on this states `[compat] Treebars = "0.1.2"`.

## 0.1.1

- `snapshot_progress(node, path; interval=2, phase_overview=false)` keeps the
  `render_text` of a progress tree in a file while a run goes on, so another
  process can follow a headless run: `cat path`, or `bin/treebars watch path`.
  The file is replaced whole every `interval` seconds at most (temp file plus
  rename), never appended to, and starts with a line naming its state (`live`
  or `final`), the writing process and the time. The do-block form
  `snapshot_progress(f, node, path)` runs `f()` and then writes the final
  snapshot; the handle form returns a `ProgressSnapshot` to `close`. A thread
  that changes the tree writes a due snapshot itself, so a run whose threads
  never yield still updates its file.
- `bin/treebars show FILE` prints a snapshot with its age, and reports a live
  snapshot that has not been written for far longer than its interval as
  stale. `bin/treebars watch FILE [SECONDS]` redraws it until it is final.

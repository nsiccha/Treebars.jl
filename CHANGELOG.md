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

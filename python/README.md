# treebars for Python

Treebars progress trees for a Python process that runs without Julia: a JAX or
BlackJAX sampler a Julia package emitted, a data script, a build step. The run
reports its phases and counters as a Treebars tree and keeps a live snapshot
file of it, in exactly the format Treebars.jl's `snapshot_progress` writes. So
another shell follows it with `cat` or `bin/treebars watch`, and a run under a
KB compute token shows on the KB's `/compute` page through `KB_PROGRESS_FILE`.

One module, `treebars.py`, standard library only, Python 3.8 or newer.

## Install

From a Treebars.jl checkout, put this directory on the path:

```python
sys.path.insert(0, "<Treebars.jl>/python")
import treebars as tb
```

or install it with pip at the Treebars.jl commit you want:

```sh
pip install "treebars @ git+https://github.com/nsiccha/Treebars.jl@<commit>#subdirectory=python"
```

The Python version equals the Treebars.jl version it was released with.

## Use

```python
import os
import treebars as tb

with tb.with_progress("state", description="Sampling",
                      snapshot=os.environ.get("KB_PROGRESS_FILE")) as root:
    with tb.with_prepared_phases(root, ["Check density", "Warm-up", "Sample"]) as (check, warmup, sample):
        with tb.with_prepared_progress(check):
            check_density()
        with tb.with_prepared_progress(warmup) as phase:
            if cached():
                tb.reuse_progress(phase)
            else:
                warm_up()
        with tb.with_prepared_progress(sample):
            with tb.with_progress(sample, len(seeds), description="Seeds") as p:
                for seed in seeds:
                    tb.update_progress(p, "seed %d" % seed)
                    run(seed)
                    tb.update_progress(p, tb.IncrementBy(1))
```

Run with short stand-in work and `interval=0.2`, the file read like this during
the second seed, and then once the run ended:

```
treebars snapshot · live · pid 424597 on gordito · written 2026-11-15T10:43:56Z (unix 1794739436) · every 0.2s
▶ Sampling [4.8s]
├─ ✓ Check density [0.4s]
├─ ✓ Warm-up [1.2s]
└─ ▶ Sample [3.2s]
   └─ ▶ Seeds (1/2) — seed 52 [3.2s] · ETA ~3.2s
```

```
treebars snapshot · final · pid 424597 on gordito · written 2026-11-15T10:43:56Z (unix 1794739436)
✓ Sampling [5s]
├─ ✓ Check density [0.4s]
├─ ✓ Warm-up [1.2s]
└─ ✓ Sample [3.4s]
   └─ ✓ Seeds (2/2) — seed 52 [3.4s]
```

The names are Treebars.jl's:

| Python | What it does |
| --- | --- |
| `with_progress(parent, N=None, *, description, transient=False)` | A node for the `with` block, finished when it ends and failed when it raises. `parent` is a node, `"state"` for a root, or `None` (progress off: the block gets `None`). An integer `N` gives a counter with an ETA. |
| `with_progress("state", ..., snapshot=path, interval=2.0)` | A root that keeps a snapshot file and writes it `final` after the root ended. `snapshot=None` writes no file, so `os.environ.get("KB_PROGRESS_FILE")` writes one exactly under a compute token. |
| `with_prepared_phases(parent, labels)` | Phases shown pending before any runs: a list of labels, or a dict of key to label. Phases never entered end skipped; the running one fails on an exception. |
| `with_prepared_progress(phase)` | Run one prepared phase. |
| `update_progress(node, value)` | An integer sets the counter (a message on a node without `N`), a string sets the message, `IncrementBy(n)` advances, no value advances by one. |
| `reuse_progress(node)` | The phase's result already existed (a cache hit): shown `↺`, not as finished work. |
| `snapshot_progress(node, path, *, interval=2.0)` | Follow an existing node; a context manager, or `close()` it. `final` means the snapshot closed, not that every node ended. |
| `render_text(node)` | The tree as text, exactly as Treebars.jl's `render_text` prints it. |

Every function takes `None` for a node and then does nothing. Nodes are safe to
update from several threads.

## The snapshot file

The first line names the snapshot's state (`live` or `final`), the writing
process, the UTC write time and, while live, its write interval; the rest is
the tree. The file is replaced whole (a temporary file in the same directory,
then a rename) at most once per `interval` seconds, by a background thread and
by whichever thread changes the tree, so it never grows with the length of the
run and a reader never sees half a file. A path that cannot be written raises
when the snapshot opens, before any work runs; a later failed write is logged
and stops the snapshot while the run carries on. Snapshots still open when
Python exits are closed then.

Not in the Python writer: the phase overview, interrupt requests, and the
cross-process mirror. Use Treebars.jl for those.

## Tests

`python3 -m unittest discover -s python` runs the module's tests. Treebars.jl's
test suite runs them too (`test/items_python.jl`), and checks that this module
renders a tree exactly as `render_text` does.

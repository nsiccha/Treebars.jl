"""Treebars progress trees for Python processes.

A Python-only run (a JAX or BlackJAX sampler emitted by a Julia package, a
data script) reports its phases and counters as a Treebars tree, and keeps a
live snapshot file of that tree that another process reads while the run goes
on: ``cat``, Treebars' ``bin/treebars show|watch``, or the KB's ``/compute``
page through ``KB_PROGRESS_FILE``. No Julia process is involved.

The vocabulary is Treebars.jl's, so the same words describe both languages::

    import os
    import treebars as tb

    with tb.with_progress("state", description="Sampling",
                          snapshot=os.environ.get("KB_PROGRESS_FILE")) as root:
        with tb.with_prepared_phases(root, ["Check density", "Sample"]) as (check, sample):
            with tb.with_prepared_progress(check):
                check_density()
            with tb.with_prepared_progress(sample):
                with tb.with_progress(sample, len(seeds), description="Seeds") as p:
                    for seed in seeds:
                        run(seed)
                        tb.update_progress(p, tb.IncrementBy(1))

The snapshot file has exactly the format of ``Treebars.snapshot_progress``: a
header line naming its state (``live`` or ``final``), the writing process and
the UTC write time, then the tree as ``Treebars.render_text`` prints it. It is
replaced whole (a temporary file, then a rename), so it never grows with the
length of the run and a reader never sees a half-written file.

The module uses only the Python standard library.
"""

import atexit
import datetime
import itertools
import logging
import math
import os
import socket
import threading
import time

# The Python module's own version; the Treebars.jl commit it is installed from
# fixes its behaviour, and its test suite pins it to that commit's render_text.
__version__ = "0.1.0"

__all__ = [
    "IncrementBy",
    "ProgressNode",
    "ProgressSnapshot",
    "render_text",
    "reuse_progress",
    "short_duration",
    "snapshot_progress",
    "update_progress",
    "with_prepared_phases",
    "with_prepared_progress",
    "with_progress",
]

_logger = logging.getLogger("treebars")


def _now_ms():
    return time.time_ns() // 1_000_000


class IncrementBy:
    """Counter step for :func:`update_progress`, as ``Treebars.IncrementBy``."""

    __slots__ = ("n",)

    def __init__(self, n=1):
        if isinstance(n, bool) or not isinstance(n, int):
            raise TypeError("IncrementBy takes an integer step, got %r" % (n,))
        self.n = n

    def __repr__(self):
        return "IncrementBy(%d)" % self.n


class _Tree:
    """What every node of one tree shares: its lock and its open snapshots."""

    __slots__ = ("lock", "snapshots")

    def __init__(self):
        self.lock = threading.RLock()
        self.snapshots = ()

    def changed(self):
        for s in self.snapshots:
            s._changed()


class ProgressNode:
    """One node of a progress tree.

    Create nodes through :func:`with_progress` and :func:`with_prepared_phases`,
    which end them on every exit. The attributes are read-only views.
    """

    __slots__ = ("_tree", "_parent", "_children", "_description", "_N", "_i",
                 "_message", "_started_at", "_finalized_at", "_failed", "_reused",
                 "_transient")

    def __init__(self, tree, parent, description, N, transient, pending):
        if N is not None and (isinstance(N, bool) or not isinstance(N, int)):
            raise TypeError("a counter total is an integer or None, got %r" % (N,))
        if not isinstance(description, str):
            raise TypeError("description is a string, got %r" % (description,))
        self._tree = tree
        self._parent = parent
        self._children = []
        self._description = description
        self._N = N
        self._i = 0
        self._message = ""
        self._started_at = None if pending else _now_ms()
        self._finalized_at = None
        self._failed = False
        self._reused = False
        self._transient = transient

    # -- read-only views -------------------------------------------------------
    @property
    def description(self):
        return self._description

    @property
    def N(self):
        return self._N

    @property
    def i(self):
        return self._i

    @property
    def message(self):
        return self._message

    @property
    def parent(self):
        return self._parent

    @property
    def children(self):
        with self._tree.lock:
            return tuple(self._children)

    @property
    def state(self):
        """One of ``pending``, ``running``, ``finished``, ``failed``, ``skipped``, ``reused``."""
        with self._tree.lock:
            return self._state()

    def _state(self):
        if self._finalized_at is None:
            return "pending" if self._started_at is None else "running"
        if self._failed:
            return "failed"
        if self._reused:
            return "reused"
        return "skipped" if self._started_at is None else "finished"

    def duration_ms(self):
        """Elapsed milliseconds: 0 before the node started, frozen once it ended."""
        with self._tree.lock:
            return self._duration_ms(_now_ms())

    def _duration_ms(self, now):
        if self._started_at is None:
            return 0
        end = now if self._finalized_at is None else self._finalized_at
        return end - self._started_at

    def __repr__(self):
        return "ProgressNode(%s)" % _summary(self, _now_ms())

    # -- lifecycle (callers go through the wrappers) ---------------------------
    def _child(self, description, N, transient, pending):
        with self._tree.lock:
            child = ProgressNode(self._tree, self, description, N, transient, pending)
            self._children.append(child)
        self._tree.changed()
        return child

    def _start(self):
        with self._tree.lock:
            if self._started_at is None and self._finalized_at is None:
                self._started_at = _now_ms()
        self._tree.changed()

    def _detach(self):
        parent = self._parent
        if self._transient and parent is not None:
            try:
                parent._children.remove(self)
            except ValueError:
                pass

    def _finalize(self):
        with self._tree.lock:
            if not (self._reused and self._finalized_at is not None):
                t = _now_ms()
                if self._started_at is None:
                    self._started_at = t
                self._finalized_at = t
            for child in list(self._children):
                st = child._state()
                if st == "running":
                    child._finalize()
                elif st == "pending":
                    child._skip()
            self._detach()
        self._tree.changed()

    def _fail(self):
        with self._tree.lock:
            t = _now_ms()
            self._failed = True
            if self._started_at is None:
                self._started_at = t
            self._finalized_at = t
            for child in list(self._children):
                if child._state() == "running":
                    child._fail()
            # A failed transient node stays attached, so the failure stays visible.
        self._tree.changed()

    def _skip(self):
        with self._tree.lock:
            if self._started_at is None and self._finalized_at is None:
                self._finalized_at = _now_ms()
                for child in list(self._children):
                    if child._state() == "pending":
                        child._skip()
                self._detach()
        self._tree.changed()

    def _reuse(self):
        with self._tree.lock:
            if self._finalized_at is not None:
                return
            self._reused = True
            self._finalized_at = _now_ms()
            for child in list(self._children):
                st = child._state()
                if st == "running":
                    child._finalize()
                elif st == "pending":
                    child._reuse()
            self._detach()
        self._tree.changed()

    def _update(self, value):
        with self._tree.lock:
            if isinstance(value, IncrementBy):
                self._i = self._i + value.n if self._N is None else min(max(self._i + value.n, 0), self._N)
            elif isinstance(value, bool):
                raise TypeError(_UPDATE_SPELLINGS % (value,))
            elif isinstance(value, int):
                if self._N is None:
                    self._message = str(value)
                else:
                    self._i = min(max(value, 0), self._N)
            elif isinstance(value, str):
                self._message = value
            else:
                raise TypeError(_UPDATE_SPELLINGS % (value,))
        self._tree.changed()


_UPDATE_SPELLINGS = ("update_progress takes an integer counter position, a message "
                     "string, IncrementBy(n) or None; got %r")


class _Disabled:
    """A ``with`` target that yields ``None``: progress is off."""

    def __enter__(self):
        return None

    def __exit__(self, *exc):
        return False


class _NodeScope:
    """Ends a node when its ``with`` block ends: finished, or failed on an exception."""

    __slots__ = ("node", "snapshot")

    def __init__(self, node, snapshot=None):
        self.node = node
        self.snapshot = snapshot

    def __enter__(self):
        return self.node

    def __exit__(self, exc_type, exc, tb):
        try:
            if exc_type is not None and not issubclass(exc_type, GeneratorExit):
                self.node._fail()
            self.node._finalize()
        finally:
            if self.snapshot is not None:
                self.snapshot.close()
        return False


def with_progress(parent, N=None, *, description="Running...", transient=False,
                  snapshot=None, interval=2.0):
    """Start a node and end it when the ``with`` block ends.

    ``parent`` is a :class:`ProgressNode` (the new node becomes its child),
    ``"state"`` (the new node is a root) or ``None`` (progress is off: the
    block receives ``None`` and runs as usual). ``N`` is a counter total; an
    integer gives a determinate counter with an ETA, ``None`` an indeterminate
    node. ``transient=True`` detaches a child once it finishes. The node is
    finished when the block ends and failed when it raises.

    On a root, ``snapshot=path`` keeps a snapshot file of the tree (see
    :func:`snapshot_progress`) and writes it ``final`` after the root ended, so
    the last record shows the root's terminal state. ``snapshot=None`` writes
    no file, so ``snapshot=os.environ.get("KB_PROGRESS_FILE")`` writes one
    exactly when the run holds a compute token.
    """
    if parent is None:
        return _Disabled()
    if isinstance(parent, ProgressNode):
        if snapshot is not None:
            raise ValueError("snapshot= belongs on a root (parent='state'); "
                             "use snapshot_progress(node, path) to follow an existing node")
        return _NodeScope(parent._child(description, N, transient, False))
    if isinstance(parent, str) and parent == "state":
        root = ProgressNode(_Tree(), None, description, N, False, False)
        snap = None if snapshot is None else snapshot_progress(root, snapshot, interval=interval)
        return _NodeScope(root, snap)
    raise TypeError("with_progress takes a ProgressNode, \"state\" for a root, or None; got %r" % (parent,))


class _PhasesScope:
    __slots__ = ("phases", "nodes")

    def __init__(self, phases, nodes):
        self.phases = phases
        self.nodes = nodes

    def __enter__(self):
        return self.phases

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None and not issubclass(exc_type, GeneratorExit):
            for p in self.nodes:
                if p is not None and p.state == "running":
                    p._fail()
        for p in self.nodes:
            if p is not None and p.state == "pending":
                p._skip()
        return False


def with_prepared_phases(parent, labels, *, N=None, transient=False):
    """Show a known sequence of phases as pending before any of them runs.

    ``labels`` is a list of phase labels, or a dict mapping keys to labels.
    The block receives the pending phase nodes (a list, or a dict with the
    same keys); enter each with :func:`with_prepared_progress`. When the block
    ends, phases never entered become skipped; when it raises, the phase that
    was running fails. ``N`` and ``transient`` apply to every phase. With
    ``parent=None`` every phase is ``None``.
    """
    keyed = isinstance(labels, dict)
    items = list(labels.items()) if keyed else [(None, x) for x in labels]
    for _, label in items:
        if not isinstance(label, str):
            raise TypeError("phase labels are strings, got %r" % (label,))
    if parent is None:
        nodes = [None] * len(items)
    elif isinstance(parent, ProgressNode):
        nodes = [parent._child(label, N, transient, True) for _, label in items]
    else:
        raise TypeError("with_prepared_phases takes a ProgressNode or None; got %r" % (parent,))
    phases = {k: n for (k, _), n in zip(items, nodes)} if keyed else list(nodes)
    return _PhasesScope(phases, nodes)


class _PhaseScope:
    __slots__ = ("node",)

    def __init__(self, node):
        self.node = node

    def __enter__(self):
        if self.node is not None:
            self.node._start()
        return self.node

    def __exit__(self, exc_type, exc, tb):
        if self.node is not None:
            if exc_type is not None and not issubclass(exc_type, GeneratorExit):
                self.node._fail()
            self.node._finalize()
        return False


def with_prepared_progress(phase):
    """Run a prepared phase: start it, then finish it, or fail it on an exception."""
    if phase is not None and not isinstance(phase, ProgressNode):
        raise TypeError("with_prepared_progress takes a ProgressNode or None; got %r" % (phase,))
    return _PhaseScope(phase)


def update_progress(node, value=IncrementBy(1)):
    """Report into a running node.

    An integer sets the counter position (on a node without a total it is
    shown as the message), a string sets the message, ``IncrementBy(n)``
    advances the counter, and no value advances it by one. ``node=None`` does
    nothing.
    """
    if node is None or value is None:
        return node
    node._update(value)
    return node


def reuse_progress(node):
    """Mark a pending or running node reused: its result already existed (a cache hit).

    Pending children become reused, running children finish. A node that
    already ended stays as it was. ``None`` does nothing.
    """
    if node is not None:
        node._reuse()
    return node


# -- text rendering ------------------------------------------------------------

_MARKERS = {"failed": "✗", "skipped": "⊘", "reused": "↺", "finished": "✓",
            "pending": "·", "running": "▶"}

_WEEK = 7 * 24 * 3600 * 1000
_PERIODS = ((_WEEK, "week"), (24 * 3600 * 1000, "day"), (3600 * 1000, "h"),
            (60 * 1000, "m"), (1000, "s"), (1, "ms"))


def _subminute(ms):
    if ms < 100:
        return "%dms" % ms
    text = repr(math.floor(ms / 100) / 10)
    return (text[:-2] if text.endswith(".0") else text) + "s"


def _period_text(value, unit):
    if unit in ("week", "day"):
        return "%d %s%s" % (value, unit, "" if value == 1 else "s")
    if unit == "ms":
        return "%rs" % ((value // 100) / 10) if value >= 100 else "%dms" % value
    return "%d%s" % (value, unit)


def short_duration(ms):
    """A duration in milliseconds as Treebars shows it: ``9ms``, ``13.9s``, ``3m 12s``."""
    if isinstance(ms, bool) or not isinstance(ms, int):
        raise TypeError("short_duration takes integer milliseconds, got %r" % (ms,))
    if ms == 0:
        return "0s"
    if ms < 60_000:
        return _subminute(ms)
    parts = []
    rest = ms
    for size, unit in _PERIODS:
        value, rest = divmod(rest, size)
        if value:
            parts.append(_period_text(value, unit))
    return " ".join(parts[:2])


def _eta_ms(node, elapsed):
    N, i = node._N, node._i
    if N is None or node._state() != "running" or i <= 0 or i >= N:
        return None
    return round(elapsed * (N - i) / i)


def _summary(node, now):
    parts = [_MARKERS[node._state()]]
    if node._description:
        parts.append(node._description)
    if node._N is not None:
        parts.append("(%d/%d)" % (node._i, node._N))
    if node._message:
        parts.append("— " + node._message)
    elapsed = node._duration_ms(now)
    if node._started_at is not None:
        parts.append("[%s]" % short_duration(elapsed))
    eta = _eta_ms(node, elapsed)
    if eta is not None:
        parts.append("· ETA ~" + short_duration(eta))
    return " ".join(parts)


def _bare(node):
    return not node._description and not node._message and node._N is None


def _displayed_children(node):
    out = []
    for child in node._children:
        if _bare(child):
            out.extend(_displayed_children(child))
        else:
            out.append(child)
    return out


def _render(node, now):
    lines = [_summary(node, now)]

    def walk(n, prefix):
        children = _displayed_children(n)
        for k, child in enumerate(children):
            last = k == len(children) - 1
            lines.append(prefix + ("└─ " if last else "├─ ") + _summary(child, now))
            walk(child, prefix + ("   " if last else "│  "))

    walk(node, "")
    return "\n".join(lines)


def render_text(node):
    """The tree below ``node`` as text, exactly as ``Treebars.render_text`` prints it.

    Each line is ``<state> <description> [(i/N)] [— message] [duration]`` with
    ``·`` pending, ``▶`` running, ``✓`` finished, ``↺`` reused, ``✗`` failed and
    ``⊘`` skipped; a running counter adds ``· ETA ~<duration>``. A node with no
    description, message or total shows no row of its own; its children move
    up a level. ``None`` renders as ``(no progress tree)``.
    """
    if node is None:
        return "(no progress tree)"
    with node._tree.lock:
        return _render(node, _now_ms())


# -- snapshot files --------------------------------------------------------------

_SNAPSHOT_IDS = itertools.count()
_OPEN = set()
_OPEN_LOCK = threading.Lock()


def _seconds_text(x):
    return str(int(x)) if float(x).is_integer() else repr(float(x))


class ProgressSnapshot:
    """A live snapshot file opened by :func:`snapshot_progress`.

    ``close()`` writes the final snapshot and stops updating the file; it is
    also a context manager that closes on exit. ``is_open`` tells whether it
    is still updated.
    """

    def __init__(self, node, path, interval):
        self.node = node
        self.path = os.path.abspath(path) if path is not None else None
        self.interval = float(interval)
        self._interval_ns = int(round(self.interval * 1e9))
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._last_ns = time.monotonic_ns()
        self._open = False
        self._thread = None
        if self.path is not None:
            self._tmp = os.path.join(os.path.dirname(self.path), ".%s.%d-%d.tmp" % (
                os.path.basename(self.path), os.getpid(), next(_SNAPSHOT_IDS)))

    @property
    def is_open(self):
        return self._open

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __repr__(self):
        return "ProgressSnapshot(%r, %s)" % (self.path, "live" if self._open else "closed")

    def _header(self, state):
        t = time.time()
        stamp = datetime.datetime.fromtimestamp(math.floor(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
        header = "treebars snapshot · %s · pid %d on %s · written %sZ (unix %d)" % (
            state, os.getpid(), socket.gethostname(), stamp, math.floor(t))
        return header + " · every %ss" % _seconds_text(self.interval) if state == "live" else header

    def _write(self, state):
        text = render_text(self.node)
        with open(self._tmp, "w", encoding="utf-8", newline="\n") as io:
            io.write(self._header(state) + "\n" + text + "\n")
        os.replace(self._tmp, self.path)
        self._last_ns = time.monotonic_ns()

    def _stop(self):
        self._open = False
        tree = self.node._tree
        with tree.lock:
            tree.snapshots = tuple(s for s in tree.snapshots if s is not self)
        with _OPEN_LOCK:
            _OPEN.discard(self)
        self._wake.set()

    def _write_or_stop(self, state):
        try:
            self._write(state)
        except Exception:
            self._stop()
            try:
                os.remove(self._tmp)
            except OSError:
                pass
            _logger.exception("Treebars could not write the progress snapshot %s; it is no longer updated",
                              self.path)

    def _due(self):
        return time.monotonic_ns() >= self._last_ns + self._interval_ns

    def _changed(self):
        # The changing thread writes when the last write is `interval` old and
        # nobody else is writing, so a run whose other threads are busy still
        # updates its file.
        if self._open and self._due() and self._lock.acquire(blocking=False):
            try:
                if self._open and self._due():
                    self._write_or_stop("live")
            finally:
                self._lock.release()

    def _loop(self):
        while self._open:
            wait_s = (self._last_ns + self._interval_ns - time.monotonic_ns()) / 1e9
            if wait_s > 0:
                self._wake.wait(wait_s)
                self._wake.clear()
                continue
            with self._lock:
                if self._open and self._due():
                    self._write_or_stop("live")

    def _start(self):
        with self._lock:
            self._write("live")  # raises before any work runs
            self._open = True
            tree = self.node._tree
            with tree.lock:
                tree.snapshots = tree.snapshots + (self,)
            with _OPEN_LOCK:
                _OPEN.add(self)
        self._thread = threading.Thread(target=self._loop, name="treebars-snapshot", daemon=True)
        self._thread.start()

    def close(self):
        """Write the final snapshot and stop updating the file. Idempotent."""
        with self._lock:
            if self._open:
                self._stop()
                self._write_or_stop("final")
        self._wake.set()


def snapshot_progress(node, path, *, interval=2.0):
    """Keep a text snapshot of ``node``'s tree in ``path`` while the run goes on.

    Returns a :class:`ProgressSnapshot`; use it in a ``with`` block or
    ``close()`` it to write the final snapshot. The first write happens before
    this returns, so a path that cannot be written raises here, before any
    work runs. Later writes come at most once per ``interval`` seconds, from a
    background thread and from whichever thread changes the tree. A later
    write that fails is logged and stops the snapshot; the run carries on.
    Snapshots still open when Python exits are closed then.

    ``final`` means the snapshot closed, not that every node ended: close it
    after the node's ``with`` block, or open the root with
    ``with_progress("state", ..., snapshot=path)``, which does that for you.
    ``node=None`` or ``path=None`` writes no file.
    """
    if not interval > 0:
        raise ValueError("snapshot_progress interval must be positive, got %r" % (interval,))
    if node is not None and not isinstance(node, ProgressNode):
        raise TypeError("snapshot_progress takes a ProgressNode or None; got %r" % (node,))
    s = ProgressSnapshot(node, path, interval)
    if node is not None and path is not None:
        s._start()
    return s


@atexit.register
def _close_open_snapshots():
    with _OPEN_LOCK:
        open_now = list(_OPEN)
    for s in open_now:
        s.close()

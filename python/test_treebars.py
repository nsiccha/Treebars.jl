"""Tests for the Python snapshot writer: ``python3 -m unittest discover -s python``.

The Julia test item ``test/items_python.jl`` runs this suite and also checks
that the Python renderer prints exactly what ``Treebars.render_text`` prints.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import treebars as tb  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(os.path.dirname(HERE), "bin", "treebars")
HEADER = re.compile(
    r"^treebars snapshot · (live|final) · pid (\d+) on (\S+) · "
    r"written \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \(unix (\d+)\)( · every ([0-9.]+)s)?$")


def strip_durations(text):
    return re.sub(r" \[[^\]]*\]", "", text)


class Lifecycle(unittest.TestCase):
    def test_states_and_render(self):
        with tb.with_progress("state", description="Sampling") as root:
            with tb.with_prepared_phases(root, ["Check", "Sample", "Write"]) as (check, sample, write):
                self.assertEqual([p.state for p in (check, sample, write)], ["pending"] * 3)
                with tb.with_prepared_progress(check):
                    self.assertEqual(check.state, "running")
                with tb.with_prepared_progress(sample):
                    with tb.with_progress(sample, 3, description="Seeds") as seeds:
                        for _ in range(3):
                            tb.update_progress(seeds, tb.IncrementBy(1))
                    tb.update_progress(sample, "4 chains")
            self.assertEqual(write.state, "skipped")
            live = tb.render_text(root)
        self.assertEqual(root.state, "finished")
        self.assertEqual(strip_durations(live), "\n".join([
            "▶ Sampling",
            "├─ ✓ Check",
            "├─ ✓ Sample — 4 chains",
            "│  └─ ✓ Seeds (3/3)",
            "└─ ⊘ Write",
        ]))
        # A skipped phase never ran, so it shows no duration at all.
        self.assertNotIn("[", tb.render_text(root).splitlines()[-1])

    def test_failure_fails_the_running_phase_and_skips_the_rest(self):
        with self.assertRaises(RuntimeError):
            with tb.with_progress("state", description="run") as root:
                with tb.with_prepared_phases(root, {"a": "First", "b": "Second"}) as phases:
                    with tb.with_prepared_progress(phases["a"]):
                        raise RuntimeError("boom")
        self.assertEqual(root.state, "failed")
        self.assertEqual(phases["a"].state, "failed")
        self.assertEqual(phases["b"].state, "skipped")
        self.assertEqual(strip_durations(tb.render_text(root)), "✗ run\n├─ ✗ First\n└─ ⊘ Second")

    def test_reuse(self):
        with tb.with_progress("state", description="run") as root:
            with tb.with_prepared_phases(root, ["Compile", "Fit"]) as (compile_, fit):
                tb.reuse_progress(compile_)
                with tb.with_prepared_progress(fit) as phase:
                    tb.reuse_progress(phase)
        self.assertEqual([compile_.state, fit.state], ["reused", "reused"])
        lines = tb.render_text(root).splitlines()
        self.assertEqual(lines[1], "├─ ↺ Compile")          # never entered: no duration
        self.assertTrue(re.match(r"└─ ↺ Fit \[\S+\]$", lines[2]))  # entered: keeps its time

    def test_counters_messages_and_bare_wrappers(self):
        with tb.with_progress("state", description="root") as root:
            with tb.with_progress(root, description="") as bare:      # no row of its own
                with tb.with_progress(bare, 10, description="draws") as draws:
                    tb.update_progress(draws, 12)                       # clamped to N
                    tb.update_progress(draws, -3)                       # clamped to 0
                    tb.update_progress(draws, 4)
                with tb.with_progress(bare, description="indeterminate") as ind:
                    tb.update_progress(ind, 7)                          # shown as the message
                    tb.update_progress(ind)                             # counts without a total
        self.assertEqual((draws.i, ind.i, ind.message), (4, 1, "7"))
        self.assertEqual(strip_durations(tb.render_text(root)),
                         "✓ root\n├─ ✓ draws (4/10)\n└─ ✓ indeterminate — 7")
        for bad in (0.5, True, object()):
            with self.assertRaises(TypeError):
                tb.update_progress(root, bad)

    def test_transient_children_leave_when_done(self):
        with tb.with_progress("state", description="root") as root:
            for _ in range(3):
                with tb.with_progress(root, description="step", transient=True):
                    self.assertEqual(len(root.children), 1)
            self.assertEqual(root.children, ())

    def test_disabled(self):
        with tb.with_progress(None, description="off") as p:
            self.assertIsNone(p)
            self.assertIsNone(tb.update_progress(p, 3))
            with tb.with_prepared_phases(p, ["a", "b"]) as phases:
                self.assertEqual(phases, [None, None])
                with tb.with_prepared_progress(phases[0]) as phase:
                    self.assertIsNone(phase)
        self.assertEqual(tb.render_text(None), "(no progress tree)")
        s = tb.snapshot_progress(None, "/nonexistent/x")
        self.assertFalse(s.is_open)
        s.close()

    def test_eta_only_while_a_counter_runs(self):
        with tb.with_progress("state", description="root") as root:
            with tb.with_progress(root, 4, description="steps") as steps:
                self.assertNotIn("ETA", tb.render_text(root))           # 0/4: no rate yet
                steps._started_at -= 3000                               # 3 s in
                tb.update_progress(steps, 1)
                line = tb.render_text(root).splitlines()[1]
                self.assertRegex(line, r"^└─ ▶ steps \(1/4\) \[3s\] · ETA ~9s$")
                tb.update_progress(steps, 4)
                self.assertNotIn("ETA", tb.render_text(root))           # 4/4: done
        self.assertNotIn("ETA", tb.render_text(root))

    def test_concurrent_updates(self):
        with tb.with_progress("state", description="root") as root:
            with tb.with_progress(root, 4000, description="ticks") as ticks:
                def work():
                    for _ in range(1000):
                        tb.update_progress(ticks, tb.IncrementBy(1))
                threads = [threading.Thread(target=work) for _ in range(4)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join()
        self.assertEqual(ticks.i, 4000)


class Durations(unittest.TestCase):
    def test_table(self):
        table = {0: "0s", 1: "1ms", 99: "99ms", 100: "0.1s", 999: "0.9s", 1000: "1s",
                 13_999: "13.9s", 14_000: "14s", 60_000: "1m", 60_500: "1m 0.5s",
                 61_500: "1m 1s", 3_600_000: "1h", 3_660_000: "1h 1m",
                 86_400_000: "1 day", 90_000_000: "1 day 1h", 1_300_000_000: "2 weeks 1 day",
                 -500: "-500ms"}
        for ms, text in table.items():
            self.assertEqual(tb.short_duration(ms), text, ms)


class Snapshots(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "run.progress")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def read(self):
        with open(self.path, encoding="utf-8") as f:
            return f.read()

    def test_live_then_final(self):
        with tb.with_progress("state", description="Sampling", snapshot=self.path, interval=0.05) as root:
            first = self.read()
            with tb.with_progress(root, 5, description="draws") as draws:
                for k in range(5):
                    time.sleep(0.03)
                    tb.update_progress(draws, tb.IncrementBy(1))
                    if k == 2:
                        time.sleep(0.12)  # the background thread writes meanwhile
                        mid = self.read()
        header, body = first.split("\n", 1)
        m = HEADER.match(header)
        self.assertIsNotNone(m, header)
        self.assertEqual((m.group(1), int(m.group(2)), m.group(6)), ("live", os.getpid(), "0.05"))
        self.assertEqual(strip_durations(body), "▶ Sampling\n")
        self.assertRegex(mid, r"▶ draws \(3/5\)")
        final = self.read()
        header, body = final.split("\n", 1)
        self.assertEqual(HEADER.match(header).group(1), "final")
        self.assertNotIn("every", header)
        # The root ended before the final write, so the last record shows it.
        self.assertEqual(strip_durations(body), "✓ Sampling\n└─ ✓ draws (5/5)\n")
        self.assertEqual(os.listdir(self.dir), ["run.progress"])

    def test_handle_on_an_existing_node(self):
        with tb.with_progress("state", description="root") as root:
            with tb.snapshot_progress(root, self.path, interval=60) as s:
                self.assertTrue(s.is_open)
                with tb.with_progress(root, description="child"):
                    pass
            self.assertFalse(s.is_open)
            body = self.read().split("\n", 1)[1]
            self.assertEqual(strip_durations(body), "▶ root\n└─ ✓ child\n")
        s.close()  # idempotent

    def test_unwritable_path_raises_before_work(self):
        with tb.with_progress("state", description="root") as root:
            with self.assertRaises(OSError):
                tb.snapshot_progress(root, os.path.join(self.dir, "missing", "run.progress"))
        with self.assertRaises(ValueError):
            tb.snapshot_progress(root, self.path, interval=0)

    def test_snapshot_needs_a_root(self):
        with tb.with_progress("state", description="root") as root:
            with self.assertRaises(ValueError):
                tb.with_progress(root, description="child", snapshot=self.path)

    def test_none_path_writes_nothing(self):
        with tb.with_progress("state", description="root", snapshot=None):
            pass
        self.assertEqual(os.listdir(self.dir), [])

    @unittest.skipUnless(os.name == "posix" and os.path.exists(CLI), "bin/treebars needs a POSIX shell")
    def test_cli_reads_the_python_snapshot(self):
        def show():
            r = subprocess.run(["sh", CLI, "show", self.path], capture_output=True, text=True,
                               encoding="utf-8")
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout
        with tb.with_progress("state", description="Sampling", snapshot=self.path, interval=1):
            out = show()
            self.assertIn("▶ Sampling", out)
            self.assertRegex(out, r"-- live · written \d+s ago")
        out = show()
        self.assertIn("✓ Sampling", out)
        self.assertRegex(out, r"-- final · written \d+s ago")
        r = subprocess.run(["sh", CLI, "watch", self.path], capture_output=True, text=True,
                           encoding="utf-8", timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)  # watch exits 0 on a final snapshot


if __name__ == "__main__":
    unittest.main()

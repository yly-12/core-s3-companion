"""Exercise the actual updater shell in isolated directories; stub only app launch.

Run with: python3 scripts/test-update-helper.py
"""
import pathlib
import subprocess
import tempfile
import unittest


HELPER = pathlib.Path(__file__).resolve().parents[1] / "macos/CoreS3Companion/App/update-helper.sh"


class UpdateHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="companion updater ")
        self.root = pathlib.Path(self.temporary.name)
        self.target = self.root / "Companion ' $ literal.app"
        self.work = self.root / "transaction"
        self.work.mkdir()
        self.staged = self.work / "new.app"
        for app, version in [(self.target, "old"), (self.staged, "new")]:
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/version").write_text(version)
        self.result = self.root / "result.txt"
        self.launch_log = self.root / "launches"
        self.launcher = self.root / "launcher.sh"
        self.launcher.write_text(
            '#!/bin/sh\nversion=$(/bin/cat "$2/Contents/version")\n'
            'printf "%s\\n" "$version" >> "$(dirname "$0")/launches"\nexit 0\n'
        )
        self.launcher.chmod(0o755)
        self.script = self.root / "helper.sh"
        # A shell-quoted literal is used only for the test stub's fixed path.
        quoted = "'" + str(self.launcher).replace("'", "'\\''") + "'"
        self.source = HELPER.read_text().replace("/usr/bin/open", quoted)

    def tearDown(self):
        self.temporary.cleanup()

    def run_helper(self, parent_pid=2147483647):
        self.script.write_text(self.source)
        return subprocess.run(
            ["/bin/sh", str(self.script), str(parent_pid), str(self.target), str(self.staged),
             str(self.work), str(self.result)], capture_output=True, text=True, errors="replace", timeout=10
        )

    def version(self):
        return (self.target / "Contents/version").read_text()

    def test_installs_relaunches_and_removes_transaction(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version(), "new")
        self.assertEqual(self.launch_log.read_text(), "new\n")
        self.assertEqual(self.result.read_text(), "ok\n")
        self.assertFalse(self.work.exists())
        self.assertEqual(list(self.root.glob("*.backup-*.app")), [])

    def test_relaunch_failure_restores_and_reopens_old_app(self):
        self.launcher.write_text(self.launcher.read_text().replace(
            "exit 0", '[ "$version" != new ] || exit 1\nexit 0'))
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.version(), "old")
        self.assertEqual(self.launch_log.read_text(), "new\nold\n")
        self.assertTrue(self.result.read_text().startswith("error:"))

    def test_failed_rename_restores_old_app(self):
        mover = self.root / "move.sh"
        mover.write_text('#!/bin/sh\ncase "$1" in *.update-*.app) exit 1;; esac\nexec /bin/mv "$@"\n')
        mover.chmod(0o755)
        self.source = self.source.replace("/bin/mv", "'" + str(mover) + "'")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.version(), "old")
        self.assertEqual(self.launch_log.read_text(), "old\n")

    def test_waits_for_original_process_before_replacement(self):
        import time
        parent = subprocess.Popen(["/bin/sleep", "10"])
        self.script.write_text(self.source)
        child = subprocess.Popen(
            ["/bin/sh", str(self.script), str(parent.pid), str(self.target), str(self.staged),
             str(self.work), str(self.result)], stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        try:
            deadline = time.monotonic() + 5
            while not (self.work / "ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.work / "ready").exists())
            self.assertEqual(self.version(), "old")
            self.assertIsNone(child.poll())
            parent.terminate()
            parent.wait()
            _, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual(self.version(), "new")
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait()
            if child.poll() is None:
                child.terminate()
                child.wait()

    def test_exit_timeout_preserves_running_app(self):
        parent = subprocess.Popen(["/bin/sleep", "10"])
        try:
            self.source = self.source.replace("/bin/sleep 1", "/usr/bin/true")
            result = self.run_helper(parent.pid)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.version(), "old")
            self.assertFalse(self.launch_log.exists())
            self.assertFalse(self.work.exists())
        finally:
            parent.terminate()
            parent.wait()

    def test_preexisting_candidate_is_not_deleted(self):
        candidate = self.root / (self.target.stem + ".update-transaction.app")
        candidate.mkdir()
        sentinel = candidate / "keep"
        sentinel.write_text("existing")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.version(), "old")
        self.assertEqual(sentinel.read_text(), "existing")

    def test_rollback_failure_preserves_backup_and_reports_its_path(self):
        mover = self.root / "move.sh"
        mover.write_text('#!/bin/sh\ncase "$1" in *.update-*.app|*.backup-*.app) exit 1;; esac\nexec /bin/mv "$@"\n')
        mover.chmod(0o755)
        self.source = self.source.replace("/bin/mv", "'" + str(mover) + "'")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        backup = self.root / (self.target.stem + ".backup-transaction.app")
        self.assertEqual((backup / "Contents/version").read_text(), "old")
        self.assertIn(str(backup), self.result.read_text())
        self.assertEqual(self.launch_log.read_text(), "old\n")


if __name__ == "__main__":
    unittest.main()

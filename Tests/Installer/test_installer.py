"""Exercise channel locking without building, installing or launching the app."""

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class InstallerLockTests(unittest.TestCase):
    def setUp(self):
        # Production cache paths live under the real home directory. Keep that
        # invariant without replacing HOME or using the real installer cache.
        self.temporary = tempfile.TemporaryDirectory(prefix=".sotto-installer-test-", dir=Path.home())
        self.addCleanup(self.temporary.cleanup)
        self.scratch = Path(self.temporary.name)
        source = (ROOT / "install.sh").read_text()
        definitions, entrypoint = source.rsplit('\nmain "$@"', 1)
        self.assertFalse(entrypoint.strip())
        self.definitions = self.scratch / "installer-functions.sh"
        self.definitions.write_text(definitions)
        self.cache = self.scratch / "cache"

    def command(self, body):
        return ["bash", "-c", 'source "$1"; cache_root="$2"; ' + body,
                "installer-test", str(self.definitions), str(self.cache)]

    def run_script(self, body):
        return subprocess.run(self.command(body), capture_output=True, text=True, timeout=5)

    def test_rejects_same_channel_and_allows_other_channel(self):
        holder = subprocess.Popen(
            self.command('acquire_installer_lock stable; echo ready; read -r release'),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline(), "ready\n")
            blocked = self.run_script("acquire_installer_lock stable")
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("Another stable installer", blocked.stderr)
            self.assertTrue((self.cache / "stable.lock/pid").is_file())
            independent = self.run_script("acquire_installer_lock beta")
            self.assertEqual(independent.returncode, 0, independent.stderr)
            self.assertFalse((self.cache / "beta.lock").exists())
            holder.communicate("release\n", timeout=5)
            self.assertEqual(holder.returncode, 0)
            self.assertFalse((self.cache / "stable.lock").exists())
        finally:
            if holder.poll() is None:
                holder.kill()
            holder.communicate()

    def test_failure_releases_lock_and_preserves_status(self):
        result = self.run_script("acquire_installer_lock stable; exit 23")
        self.assertEqual(result.returncode, 23)
        self.assertFalse((self.cache / "stable.lock").exists())

    def test_refuses_symlinked_cache(self):
        outside = self.scratch / "outside"
        outside.mkdir()
        self.cache.symlink_to(outside, target_is_directory=True)
        result = self.run_script("acquire_installer_lock stable")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()

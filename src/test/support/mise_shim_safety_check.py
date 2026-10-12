"""Exercise shipped shell entrypoints with real mise; never touch host state."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv.pop(1))


def is_wrapper(path):
    with path.open("rb") as stream:
        return b"aiur-build-gate-command-wrapper-marker" in stream.read(4096)


class MiseShimSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="3627-mise-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.wrapper = self.root / "workspace/.aiur-runtime/build-bin"
        self.wrapper.mkdir(parents=True)
        shutil.copyfile(REPO / "src/priv/build_gate_command_wrapper.bash", self.wrapper / "mise")
        (self.wrapper / "mise").chmod(0o755)
        # Find a real mise without consulting inherited wrapper identity.
        self.real = next((Path(p) / "mise" for p in os.environ["PATH"].split(":")
                          if (Path(p) / "mise").is_file()
                          and not is_wrapper(Path(p) / "mise")), None)
        self.assertIsNotNone(self.real, "real mise required for regression check")
        self.real = self.real.resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("MISE_", "__MISE", "XDG_", "AIUR_"))}
        self.env.update(HOME=str(self.root), PATH=f"{self.wrapper}:{self.real.parent}:/usr/bin:/bin",
                        BASH_ENV="", MISE_DATA_DIR=str(self.root / "data"),
                        MISE_CACHE_DIR=str(self.root / "cache"), MISE_CONFIG_DIR=str(self.root / "config"),
                        MISE_STATE_DIR=str(self.root / "state"), MISE_SYSTEM_CONFIG_DIR=str(self.root / "system"),
                        MISE_SYSTEM_DATA_DIR=str(self.root / "system-data"),
                        MISE_TRUSTED_CONFIG_PATHS=str(self.root), MISE_CEILING_PATHS=str(self.root), MISE_OFFLINE="1", MISE_AUTO_INSTALL="0")
        self.env.update({k: str(self.wrapper / "mise") for k in ("MISE_BIN", "__MISE_BIN", "__MISE_EXE")})
        tool_bin = self.root / "data/installs/node/22.0.0/bin"
        tool_bin.mkdir(parents=True)
        for name in ("node", "npm"):
            (tool_bin / name).write_text("#!/bin/sh\nexit 0\n")
            (tool_bin / name).chmod(0o755)
        (self.root / "mise.toml").write_text('[tools]\nnode="22.0.0"\n')
        self.shims = self.root / "data/shims"

    def run_cmd(self, args):
        return subprocess.run(args, cwd=self.root, env=self.env, text=True, capture_output=True)

    def assert_safe(self):
        shims = sorted(self.shims.glob("*"))
        self.assertEqual([p.name for p in shims], ["node", "npm"])
        for shim in shims:
            self.assertEqual(shim.resolve(), self.real)

    def test_posix_passthrough_reshim(self):
        result = self.run_cmd([str(self.wrapper / "mise"), "reshim"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_safe()

    def test_bash_hook_reshim(self):
        self.env["AIUR_BUILD_GATE_DIR"] = str(self.root / "gate")
        self.env["AIUR_BUILD_GATE_BIN"] = str(self.wrapper)
        self.env["BASH_ENV"] = str(REPO / "src/priv/build_gate.bash")
        result = self.run_cmd(["/bin/bash", "-c", "mise reshim"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_safe()

    def doctor(self, *args):
        self.env["AIUR_RELEASE_DIR"] = str(self.root / "release")
        return self.run_cmd(["bash", str(REPO / "packaging/npm/aiur-cli/libexec/aiur-engine.sh"), "doctor", *args])

    def test_doctor_reports_chained_dangling_workspace_shim_without_repair(self):
        self.shims.mkdir(parents=True)
        (self.root / "alias").symlink_to("missing/.aiur-runtime/build-bin/mise")
        (self.shims / "mix").symlink_to("../../alias")
        result = self.doctor()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("unsafe mise shim", result.stderr)
        self.assertIn("doctor --repair", result.stderr)
        self.assertEqual(os.readlink(self.shims / "mix"), "../../alias")

    def test_doctor_repair_requires_explicit_flag_and_uses_real_mise(self):
        self.shims.mkdir(parents=True)
        for name in ("node", "npm"):
            (self.shims / name).symlink_to(self.wrapper / "mise")
        result = self.doctor("--repair")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_safe()
        self.assertEqual(self.doctor().returncode, 0)


unittest.main(verbosity=2)

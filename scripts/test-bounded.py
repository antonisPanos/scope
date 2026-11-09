#!/usr/bin/env python3
"""Run the bounded suite only on a disposable GitHub-hosted macOS runner."""
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent.parent
PACKAGE = PROJECT / "Packages" / "ScopeEngine"
BUILD_LIMIT = 2 * 1024**3
FIXTURE_LIMIT = 2 * 1024**2
FIXTURE_ITEMS = 128
PROFILE = r'''(version 1)
(allow default)
(deny file-write* (require-not (subpath (param "TEST_ROOT"))))
(deny file-read* (require-all (subpath (param "REAL_HOME"))
    (require-not (subpath (param "PROJECT"))) (require-not (subpath (param "ROOT")))
    ; ANCESTOR_METADATA_EXCEPTIONS
))
(deny file-read-data (require-all (subpath (param "REAL_HOME"))
    (require-not (subpath (param "PROJECT"))) (require-not (subpath (param "ROOT")))))
(deny process-exec (require-not (require-any (literal (param "HELPER")) (literal "/usr/bin/env"))))
(deny network*)
'''


def usage(path):
    """Allocated bytes and entries, without following symlinks."""
    total, count = 0, 0
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            try:
                info = os.lstat(os.path.join(base, name))
            except FileNotFoundError:
                continue
            total += info.st_blocks * 512
            count += 1
    return total, count


def run(command, env, root, fixtures, log, timeout):
    deadline = time.monotonic() + timeout
    failure = None
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, cwd=PACKAGE, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"watchdog exceeded {timeout} seconds")
                allocated, _ = usage(root)
                fixture_bytes, fixture_items = usage(fixtures)
                if allocated > BUILD_LIMIT:
                    raise RuntimeError("scratch allocation exceeded 2 GiB monitoring threshold")
                if fixture_bytes > FIXTURE_LIMIT or fixture_items > FIXTURE_ITEMS:
                    raise RuntimeError("fixture allocation or item monitoring threshold exceeded")
                time.sleep(0.5)
        except (OSError, RuntimeError) as error:
            failure = error
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    if failure is not None:
        raise failure
    allocated, _ = usage(root)
    fixture_bytes, fixture_items = usage(fixtures)
    if allocated > BUILD_LIMIT or fixture_bytes > FIXTURE_LIMIT or fixture_items > FIXTURE_ITEMS:
        raise RuntimeError("allocation or item monitoring threshold exceeded at process exit")
    if process.returncode:
        raise RuntimeError(f"command exited {process.returncode}")
    return text


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
            os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise RuntimeError("bounded tests are supported only on disposable GitHub-hosted macOS CI")
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="scope-bounded-", dir=runner_temp)).resolve()
    try:
        test_root = root / "test"
        fixtures = test_root / "fixtures"
        tmp = test_root / "tmp"
        fixtures.mkdir(parents=True)
        tmp.mkdir()
        env = os.environ.copy()
        env.update(SCOPE_TEST_PROFILE="bounded", SCOPE_BOUNDED_ROOT=str(fixtures), TMPDIR=str(tmp),
                   CLANG_MODULE_CACHE_PATH=str(root / "clang-cache"),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(root / "module-cache"))
        build = root / "build"
        common = ["--scratch-path", str(build), "--cache-path", str(root / "swiftpm-cache"),
                  "--config-path", str(root / "swiftpm-config"), "--security-path", str(root / "swiftpm-security")]
        run(["/usr/bin/xcrun", "swift", "build", "--build-tests"] + common,
            env, root, fixtures, root / "build.log", 600)
        candidates = {path.resolve() for path in build.glob("**/*.xctest/Contents/MacOS/*") if path.is_file()}
        if len(candidates) != 1:
            raise RuntimeError(f"expected one test bundle executable, found {len(candidates)}")
        swift = subprocess.run(["/usr/bin/xcrun", "--find", "swift"], check=True, text=True,
                               capture_output=True, timeout=10).stdout.strip()
        helper = Path(swift).resolve().parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
        if not helper.is_file():
            raise RuntimeError("Swift Testing helper is unavailable")
        platform = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-platform-path"],
                                  check=True, text=True, capture_output=True, timeout=10).stdout.strip()
        frameworks = Path(platform) / "Developer/Library/Frameworks"
        libraries = Path(platform) / "Developer/usr/lib"
        if not (frameworks / "Testing.framework/Testing").is_file() or not libraries.is_dir():
            raise RuntimeError("macOS SDK Testing framework or runtime libraries are unavailable")
        home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        # realpath() inspects each directory above ROOT. Permit only metadata
        # on its literal home ancestors; their directory contents stay denied.
        ancestors = [path for path in root.parents if path == home or home in path.parents]
        ancestor_rules = "\n    ".join(
            f'(require-not (literal (param "ANCESTOR_{index}")))' for index in range(len(ancestors)))
        profile = PROFILE.replace("; ANCESTOR_METADATA_EXCEPTIONS", ancestor_rules)
        ancestor_parameters = [value for index, path in enumerate(ancestors)
                               for value in ("-D", f"ANCESTOR_{index}={path}")]
        # Set dyld paths after sandbox-exec, which may strip them under SIP.
        # Only env and the selected helper are executable inside the sandbox.
        command = ["/usr/bin/sandbox-exec", "-p", profile,
                   "-D", "ROOT=" + str(root), "-D", "TEST_ROOT=" + str(test_root),
                   "-D", "PROJECT=" + str(PROJECT), "-D", "REAL_HOME=" + str(home),
                   "-D", "HELPER=" + str(helper)] + ancestor_parameters + ["/usr/bin/env",
                   "DYLD_FRAMEWORK_PATH=" + str(frameworks), "DYLD_LIBRARY_PATH=" + str(libraries), str(helper),
                   "--test-bundle-path", str(next(iter(candidates))), "--testing-library", "swift-testing",
                   "--no-parallel"]
        output = run(command, env, root, fixtures, root / "test.log", 120)
        match = re.search(r"Test run with ([1-9][0-9]*) tests? passed", output)
        if "BoundedFaultTests" not in output or not match or int(match.group(1)) < 9:
            raise RuntimeError("the bounded test run did not confirm that tests executed")
        if any(fixtures.iterdir()):
            raise RuntimeError("a bounded fixture was not cleaned up")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"bounded profile failed: {error}", file=sys.stderr)
        sys.exit(1)

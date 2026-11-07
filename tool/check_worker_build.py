#!/usr/bin/env python3
"""Exercise Flutter's worker asset pipeline in disposable consumer projects."""

import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def check(flutter: str) -> None:
    reader = Path(__file__).resolve().parents[1]
    asset = "packages/papyrus_reader/assets/epub_worker"

    with tempfile.TemporaryDirectory(prefix="papyrus worker ") as directory:
        temporary = Path(directory)
        package = temporary / "reader"
        host = temporary / "host"
        package.mkdir()
        for name in ("lib", "bin"):
            shutil.copytree(reader / name, package / name)
        for name in (
            "pubspec.yaml",
            "LICENSE",
            "tool/epub_worker.dart",
            "assets/epub_worker",
        ):
            destination = package / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(reader / name, destination)

        def run(*arguments: str, cwd: Path = host, succeeds: bool = True):
            result = subprocess.run(
                arguments,
                cwd=cwd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if (result.returncode == 0) != succeeds:
                raise RuntimeError(f"{' '.join(arguments)}\n{result.stdout}")
            return result.stdout

        run(
            flutter,
            "create",
            "--platforms=web",
            "--empty",
            "--project-name=worker_host",
            str(host),
            cwd=temporary,
        )
        manifest = host / "pubspec.yaml"
        manifest.write_text(
            manifest.read_text().replace(
                "dependencies:\n",
                "dependencies:\n  papyrus_reader:\n    path: ../reader\n",
                1,
            )
        )
        run(flutter, "pub", "get")

        def build() -> str:
            run(flutter, "build", "web", "--no-pub")
            return (host / "build/web/assets" / asset).read_text()

        original = build()
        assert "Licenses for the compiled EPUB worker" in original
        assert "// Dart SDK" in original
        assert not (
            host / "build/web/assets/packages/papyrus_reader/assets/epub_worker.js"
        ).exists()
        print("PASS: clean consumer generates worker and notices", flush=True)

        processor = package / "lib/src/engine/epub/worker/epub_processor.dart"
        source = processor.read_text()
        marker = "WORKER_INCREMENTAL_CHECK"
        assert "Unknown EPUB worker command:" in source
        processor.write_text(source.replace("Unknown EPUB worker command:", marker))
        assert marker in build(), "Imported source change did not rebuild worker"
        processor.write_text(source)
        print(
            "PASS: imported source invalidates worker (including paths with spaces)",
            flush=True,
        )

        config_source = manifest.read_text()
        version = re.search(r"^// archive (.+)$", original, re.MULTILINE).group(1)
        alternate = "4.0.9" if version != "4.0.9" else "4.2.0"
        manifest.write_text(
            config_source
            + f"\ndependency_overrides:\n  archive: {alternate}\n  image: 4.8.0\n"
        )
        run(flutter, "pub", "get")
        assert f"// archive {alternate}\n" in build()
        print("PASS: worker uses consumer's resolved dependency version", flush=True)

        # Reported dependencies also cover notice-only inputs, which dart2js omits.
        license_file = package / "LICENSE"
        license_file.write_text(license_file.read_text() + "\nWORKER_LICENSE_CHECK\n")
        assert "// WORKER_LICENSE_CHECK" in build()
        print("PASS: notice changes invalidate worker", flush=True)

        entrypoint = package / "tool/epub_worker.dart"
        entry_source = entrypoint.read_text()
        entrypoint.write_text(entry_source + "\ninvalid worker source !!!\n")
        failure = run(flutter, "build", "web", "--no-pub", succeeds=False)
        assert "Transformer process terminated" in failure
        entrypoint.write_text(entry_source)
        print("PASS: worker compilation errors fail the application build", flush=True)

        run(flutter, "build", "bundle", "--no-pub")
        assert not (host / "build/flutter_assets" / asset).exists()
        print("PASS: native bundle excludes browser worker", flush=True)

        run("git", "init", "-q", cwd=package)
        run("git", "add", ".", cwd=package)
        run(
            "git",
            "-c",
            "user.name=Worker build test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "Worker fixture",
            cwd=package,
        )
        revision = run("git", "rev-parse", "HEAD", cwd=package).strip()
        manifest.write_text(
            manifest.read_text().replace(
                "    path: ../reader",
                f"    git:\n      url: {package.as_uri()}\n      ref: {revision}",
            )
        )
        run(flutter, "pub", "get")
        assert f"// archive {alternate}\n" in build()
        print("PASS: Git-pinned consumer needs no manual generation step", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    arguments = parser.parse_args()
    executable = shutil.which(arguments.flutter)
    if executable is None:
        parser.error(f"Flutter executable not found: {arguments.flutter}")
    check(str(Path(executable).absolute()))

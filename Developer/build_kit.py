"""Build the documented customer distribution and verify every member."""
import argparse
import hashlib
import json
import os
import shutil
import tempfile
from contextlib import ExitStack
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile, ZipInfo

VENDOR_ARCHIVES = {
    "Tools/DSASupportTool-CMD.zip": "17297b8abb8193d7552c4a0023723ed0fee29b93849b97c91dc69300e6520c42",
    "Tools/DSASupportTool-GUI.zip": "090e62db8cd47663a314a0778083a18941dfe885715fa18a28d795508b9ed68f",
}

MEMBERS = (
    "README.md",
    "Tools/README.md",
    "Analysis/README.md",
    "Analysis/Export-WprReports.ps1",
    "START-HERE.md",
    "SWP-Perf.ps1",
    "SWP-SignIn.wprp",
    "SWP-SignIn-128MiB.wprp",
    "Customer-Runbook.md",
    "Validation-summary.json",
    *VENDOR_ARCHIVES,
    "Documentation/Handbook.md",
    "Documentation/DSTool-collection.example.json",
    "Documentation/SWP-Perf-Handbook.docx",
    "Documentation/SWP-Perf-Handbook.pdf",
    "Documentation/Participant-sheet.pdf",
    "Documentation/Administrator-participant.pdf",
    "Documentation/Administrator-participant.md",
    "skills/analyze-swp-performance/SKILL.md",
    "Developer/README.md",
    "Developer/CollectionScript.Tests.ps1",
    "Developer/render_handbook.py",
    "Developer/build_kit.py",
)


def sha256(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


DIST = Path("dist/SWP-Customer-Kit.zip")
PACKAGE_INFO = "Package-info.json"


def write_member(archive, name, source):
    # Fixed metadata and stored bytes make checkout time, OS and zlib irrelevant.
    entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    entry.create_system = 3
    entry.external_attr = 0o100644 << 16
    digest = hashlib.sha256()
    with archive.open(entry, "w") as target:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
            target.write(block)
    return digest.hexdigest()


def assemble(root, staged):
    hashes = {}
    seed = None
    with ExitStack() as inputs, ZipFile(staged, "x") as archive:
        for name in MEMBERS:
            path = root / name
            if path.resolve() != path:
                raise ValueError(f"Linked package input: {name}")
            if name in VENDOR_ARCHIVES and not path.exists():
                if seed is None:
                    previous = root / DIST
                    if previous.resolve() != previous or not previous.is_file():
                        raise FileNotFoundError(f"Supply {name} as described in Tools/README.md")
                    seed = inputs.enter_context(ZipFile(previous))
                stream = seed.open(name)
            else:
                stream = path.open("rb")
            with stream:
                hashes[name] = write_member(archive, name, stream)
            if name in VENDOR_ARCHIVES and hashes[name] != VENDOR_ARCHIVES[name]:
                raise ValueError(f"Vendor archive differs from the pinned build: {name}")

        validated = json.loads((root / "Validation-summary.json").read_text(encoding="utf-8-sig"))
        tested_hash = validated["collectorSHA256"].lower()
        info = {
            "packagedCollectorSHA256": hashes["SWP-Perf.ps1"],
            "validatedCollectorSHA256": tested_hash,
            "collectorMatchesRecordedValidation": hashes["SWP-Perf.ps1"] == tested_hash,
        }
        data = (json.dumps(info, indent=2) + "\n").encode("utf-8")
        hashes[PACKAGE_INFO] = write_member(archive, PACKAGE_INFO, BytesIO(data))
        if not info["collectorMatchesRecordedValidation"]:
            print("Collector changed since the recorded Windows validation. See Package-info.json.")

    with ZipFile(staged) as archive:
        if archive.namelist() != list(hashes):
            raise ValueError("Archive member list differs from the distribution list")
        for name, expected in hashes.items():
            with archive.open(name) as stream:
                if sha256(stream) != expected:
                    raise ValueError(f"Archive content mismatch: {name}")


def build(root, output, mode):
    root = root.resolve()
    if output.suffix.lower() != ".zip":
        raise ValueError("Choose a destination ending in .zip")
    checksum = Path(str(output) + ".sha256.txt")
    if mode == "new" and (output.exists() or checksum.exists()):
        raise FileExistsError("Choose an unused archive and checksum destination")
    if mode == "check" and not (output.is_file() and checksum.is_file()):
        raise FileNotFoundError("The tracked kit or checksum is missing.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        staged = Path(temp) / "kit.zip"
        assemble(root, staged)
        with staged.open("rb") as stream:
            digest = sha256(stream)
        line = f"{digest}  {output.name}\n".encode("ascii")
        if mode == "new":
            with output.open("xb") as target:
                try:
                    with staged.open("rb") as source:
                        shutil.copyfileobj(source, target)
                except BaseException:
                    target.close()
                    output.unlink()
                    raise
            with checksum.open("xb") as target:
                target.write(line)
        else:
            archive_current = False
            if output.is_file():
                with output.open("rb") as source:
                    archive_current = sha256(source) == digest
            checksum_current = checksum.is_file() and checksum.read_bytes() == line
            if mode == "check" and not (archive_current and checksum_current):
                raise ValueError("Tracked customer kit or checksum is stale. Run --refresh.")
            if not archive_current:
                os.replace(staged, output)
            if not checksum_current:
                staged_sum = Path(temp) / "checksum.txt"
                staged_sum.write_bytes(line)
                os.replace(staged_sum, checksum)
    print(f"{output}  {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path, help="Write a new archive at an unused path")
    group.add_argument("--refresh", action="store_true", help="Update the tracked kit and checksum")
    group.add_argument("--check", action="store_true", help="Verify the tracked kit is current")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    mode = "new" if args.output else "refresh" if args.refresh else "check"
    build(root, args.output.resolve() if args.output else root / DIST, mode)

"""Build the documented customer distribution and verify every member."""
import argparse
import hashlib
import json
import shutil
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

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


def build(root, output):
    if output.suffix.lower() != ".zip":
        raise ValueError("Choose a destination ending in .zip")
    checksum = Path(str(output) + ".sha256.txt")
    if output.exists() or checksum.exists():
        raise FileExistsError("Choose an unused archive and checksum destination")
    root = root.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in MEMBERS:
        path = root / name
        if name in VENDOR_ARCHIVES and not path.is_file():
            raise FileNotFoundError(f"Supply {name} as described in Tools/README.md")
        if path.resolve() != path or not path.is_file():
            raise ValueError(f"Missing file or linked source: {name}")
        with path.open("rb") as stream:
            hashes[name] = sha256(stream)
        if name in VENDOR_ARCHIVES and hashes[name] != VENDOR_ARCHIVES[name]:
            raise ValueError(f"Vendor archive differs from the verified build: {name}")
    validation = json.loads((root / "Validation-summary.json").read_text(encoding="utf-8-sig"))
    if hashes["SWP-Perf.ps1"] != validation["collectorSHA256"].lower():
        raise ValueError("Collector SHA-256 differs from the release validation summary")

    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        staged = Path(temp) / "kit.zip"
        with ZipFile(staged, "x") as archive:
            for name in MEMBERS:
                mode = ZIP_STORED if name.endswith((".zip", ".docx", ".pdf")) else ZIP_DEFLATED
                archive.write(root / name, name, compress_type=mode)
        with ZipFile(staged) as archive:
            if archive.namelist() != list(MEMBERS):
                raise ValueError("Archive member list differs from the distribution list")
            for name in MEMBERS:
                with archive.open(name) as stream:
                    if sha256(stream) != hashes[name]:
                        raise ValueError(f"Archive content mismatch: {name}")
        with staged.open("rb") as stream:
            digest = sha256(stream)
        # Create new deliverables exclusively, including if another build finishes first.
        with output.open("xb") as target:
            try:
                with staged.open("rb") as stream:
                    shutil.copyfileobj(stream, target)
            except BaseException:
                target.close()
                output.unlink()
                raise
        with output.open("rb") as stream:
            if sha256(stream) != digest:
                raise OSError(f"Failed readback of {output}")
        with checksum.open("x", encoding="ascii") as stream:
            stream.write(f"{digest}  {output.name}\n")
    print(f"{output}  {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(Path(__file__).resolve().parents[1], args.output.resolve())

"""Compare both revisions on the same standard MCAP input and budgets."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "_interop_deps"))
from mcap.reader import NonSeekingReader, make_reader
from mcap.writer import CompressionType, IndexType, Writer

BASELINE = "e99a19f101092c982189d85d9536cf47eb5587c4"
FILE_BUDGET = 64 * 1024 * 1024
ATTACHMENT_SIZE = FILE_BUDGET + 65536


def hashes(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(part)
    return digest.hexdigest()


def write_recording(path, payload=None):
    with path.open("wb") as output:
        writer = Writer(
            output, compression=CompressionType.NONE, index_types=IndexType.NONE,
            use_chunking=False, repeat_schemas=False, repeat_channels=False,
            use_statistics=False, use_summary_offsets=False, enable_data_crcs=True,
        )
        writer.start(library="Synthetic fixture from the Foxglove Python MCAP Writer")
        channel = writer.register_channel("/events", "application/octet-stream", 0)
        if payload is None:
            writer.add_message(channel, 30, b"second", 30, sequence=3)
        else:
            writer.add_message(channel, 10, b"before", 10, sequence=1)
            writer.add_attachment(11, 12, "calibration.bin", "application/octet-stream", payload)
            writer.add_metadata("run", {"source": "same input comparison"})
            writer.add_message(channel, 20, b"after", 19, sequence=2)
        writer.finish()


def build(root):
    subprocess.run([os.environ.get("MOON", "moon"), "build", "cmd/mcap",
                    "--target", "js", "--deny-warn"], cwd=root, check=True)
    return root / "_build/js/debug/build/cmd/mcap/mcap.js"


def cli(executable, *args, failure=None):
    result = subprocess.run(
        [os.environ.get("NODE", "node"), str(executable), *map(str, args)],
        capture_output=True, text=True, encoding="utf-8",
    )
    if failure:
        assert result.returncode == 2 and failure in result.stderr, result
        return {"exit": result.returncode, "error": json.loads(result.stderr)["error"]}
    assert result.returncode == 0, result
    return json.loads(result.stdout)


def wasm_cli(input_file, operation, *args):
    result = subprocess.run(
        [os.environ.get("NODE", "node"), str(ROOT / "tools/attachment_wasm.mjs"),
         str(input_file), operation, *map(str, args)],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
    )
    assert result.returncode == 0, result
    parsed = json.loads(result.stdout)
    assert parsed["status"] == "ok", parsed
    return parsed


def verify_merge(path, payload_hash):
    with path.open("rb") as source:
        reader = NonSeekingReader(source, validate_crcs=True)
        messages = list(reader.iter_messages(log_time_order=False))
    assert [(channel.topic, message.log_time, message.publish_time, message.sequence, message.data)
            for _, channel, message in messages] == [
        ("/events", 10, 10, 1, b"before"), ("/events", 20, 19, 2, b"after"),
        ("/events", 30, 30, 3, b"second"),
    ]
    with path.open("rb") as source:
        reader = make_reader(source, validate_crcs=True)
        summary = reader.get_summary()
        assert summary.statistics.message_count == 3
        assert summary.statistics.attachment_count == 1
        assert summary.attachment_indexes[0].data_size == ATTACHMENT_SIZE
        item = next(reader.iter_attachments())
        assert item.name == "calibration.bin"
        assert item.create_time == 11 and item.log_time == 12
        assert len(item.data) == ATTACHMENT_SIZE
        assert hashlib.sha256(item.data).hexdigest() == payload_hash
        assert next(reader.iter_metadata()).metadata["source"] == "same input comparison"


def verify_export_limit(candidate, work):
    path = work / "many-attachments.mcap"
    with path.open("wb") as output:
        writer = Writer(output, compression=CompressionType.NONE,
                        index_types=IndexType.NONE, use_chunking=False,
                        enable_data_crcs=True)
        writer.start(library="Synthetic attachment export limit fixture")
        for i in range(1001):
            writer.add_attachment(i, i, f"{i}.bin", "application/octet-stream", b"x")
        writer.finish()
    assert cli(candidate, "attachment-catalog", path)["total"] == 1001
    directory = work / "export-limit"
    directory.mkdir()
    rejection = cli(candidate, "attachment-export", path, directory,
                    failure="at most 1000 attachments")
    assert not any(directory.iterdir()), "over-limit export created output"
    return {"input_attachments": 1001, "published_files": 0, **rejection}


def exercise(baseline, candidate, work):
    large = work / "large.mcap"
    small = work / "small.mcap"
    payload = bytes(range(256)) * (ATTACHMENT_SIZE // 256)
    payload_hash = hashlib.sha256(payload).hexdigest()
    write_recording(large, payload)
    write_recording(small)
    del payload
    input_hash = hashes(large)
    filters = [large, "--topic", "/events", "--start", "20", "--end", "20"]
    old_query = cli(baseline, "query", *filters, failure="fallback")
    unchanged_query = cli(candidate, "query", *filters, failure="fallback")
    assert old_query == unchanged_query
    query = cli(candidate, "scan-query", *filters)
    assert query["messages"] == [
        {"channel_id": 1, "topic": "/events", "log_time": "20", "publish_time": "19",
         "sequence": 2, "data_hex": b"after".hex()},
    ]
    assert not query["diagnostics"]["full_validation"]
    assert int(query["diagnostics"]["bytes_read"]) < 4096
    assert cli(candidate, "validate-range", large) == {
        "valid": True, "messages": "2", "data_crc_verified": True,
    }

    listed = cli(candidate, "attachment-list", large)
    assert int(listed["diagnostics"]["bytes_read"]) < 4096
    attachment, = listed["attachments"]
    assert int(attachment["data_size"]) == ATTACHMENT_SIZE
    offset = attachment["offset"]
    extracted = work / "attachment.bin"
    result = cli(candidate, "attachment-extract", large, offset, extracted)
    assert result["attachment_crc_verified"] is True
    assert extracted.stat().st_size == ATTACHMENT_SIZE and hashes(extracted) == payload_hash
    cli(candidate, "attachment-extract", large, offset, extracted, failure="exist")
    assert hashes(extracted) == payload_hash
    wasm_query = wasm_cli(large, "query", "/events", "20", "20")
    assert wasm_query["messages"] == query["messages"]
    wasm_list = wasm_cli(large, "list")
    assert wasm_list["attachments"] == listed["attachments"]
    preview = wasm_cli(large, "range", offset, "65534", "8")
    assert preview["data_hex"] == bytes(range(254, 256)).hex() + bytes(range(6)).hex()
    assert not preview["payload_crc_verified"]
    wasm_output = work / "wasm-attachment.bin"
    wasm_extract = wasm_cli(large, "extract", offset, wasm_output)
    assert wasm_extract["payload_crc_verified"]
    assert hashes(wasm_output) == payload_hash
    export_dir = work / "exports"
    export_dir.mkdir()
    batch = cli(candidate, "attachment-export", large, export_dir)
    assert len(batch["receipts"]) == 1
    assert hashes(Path(batch["receipts"][0]["destination"])) == payload_hash

    runs = work / "runs"
    runs.mkdir()
    old_output = work / "baseline.mcap"
    merge = ["external-merge", large, small, "--temp-dir", runs, "--output"]
    old_merge = cli(baseline, *merge, old_output, failure="exceeds configured limit")
    assert not old_output.exists()
    new_output = work / "candidate.mcap"
    cli(candidate, *merge, new_output)
    assert cli(candidate, "validate-range", new_output) == {
        "valid": True, "messages": "3", "data_crc_verified": True,
    }
    verify_merge(new_output, payload_hash)

    corrupt = work / "corrupt.mcap"
    shutil.copyfile(large, corrupt)
    payload_offset = int(offset) + int(attachment["record_bytes"]) - ATTACHMENT_SIZE - 4
    with corrupt.open("r+b") as stream:
        stream.seek(payload_offset)
        stream.write(b"\xff")
    rejected = work / "rejected.bin"
    bad_extract = cli(candidate, "attachment-extract", corrupt, offset,
                      rejected, failure="attachment CRC mismatch")
    assert not rejected.exists()
    bad_merge = cli(candidate, "external-merge", corrupt, small, "--temp-dir",
                    runs, "--output", rejected, failure="attachment CRC mismatch")
    assert not rejected.exists()
    # Restore the attachment byte, then change only the DataEnd checksum.
    with corrupt.open("r+b") as stream:
        stream.seek(payload_offset)
        stream.write(b"\x00")
        stream.seek(-41, os.SEEK_END)
        checksum = stream.read(1)[0]
        stream.seek(-1, os.SEEK_CUR)
        stream.write(bytes([checksum ^ 1]))
    bad_data_crc = cli(candidate, "validate-range", corrupt, failure="data CRC mismatch")
    assert hashes(large) == input_hash

    return {
        "baseline_commit": BASELINE, "input": "synthetic unchunked MCAP without indexes",
        "python_mcap": importlib.metadata.version("mcap"),
        "input_bytes": large.stat().st_size, "input_sha256": input_hash,
        "attachment_bytes": ATTACHMENT_SIZE, "attachment_sha256": payload_hash,
        "unchanged_ordinary_record_limit_bytes": 16 * 1024 * 1024,
        "baseline_query": old_query, "candidate_legacy_query": unchanged_query,
        "candidate_scan_query": query["diagnostics"],
        "candidate_attachment_list": listed["diagnostics"],
        "attachment_extraction_crc_verified": True,
        "baseline_merge": old_merge, "candidate_merge_reference_readback": True,
        "corrupt_extraction": bad_extract, "corrupt_merge": bad_merge,
        "corrupt_data_crc": bad_data_crc,
        "destination_preserved": True, "candidate_full_validation": True,
        "wasm_real_file_query_and_extraction": True,
        "wasm_extracted_sha256": hashes(wasm_output),
        "node_export_reference_hash": payload_hash,
        "batch_export_limit": verify_export_limit(candidate, work),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()
    checkout = args.baseline.resolve()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    assert commit == BASELINE, f"wrong baseline: {commit}"
    assert not subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=checkout, text=True
    ).strip(), "baseline contains changes"
    baseline = build(checkout)
    candidate = build(ROOT)
    directory = ROOT / "_interop"
    directory.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="attachment-stream-", dir=directory) as work:
        work = Path(work).resolve()
        assert work.is_relative_to(directory.resolve())
        report = exercise(baseline, candidate, work)
    candidate_revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True,
    )
    candidate_changes = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=no"],
        cwd=ROOT, capture_output=True, text=True,
    )
    report["candidate_commit"] = (
        candidate_revision.stdout.strip() if candidate_revision.returncode == 0 else None
    )
    report["candidate_tracked_changes"] = (
        bool(candidate_changes.stdout.strip()) if candidate_changes.returncode == 0 else None
    )
    report["workflow_sha256"] = hashes(Path(__file__))
    report_path = directory / "attachment-stream-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

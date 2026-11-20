"""Count effective MoonBit changes relative to the fixed upstream baseline."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "e99a19f101092c982189d85d9536cf47eb5587c4"


def git(*args):
    return subprocess.check_output(
        ["git", "-c", "core.quotepath=false", *args],
        cwd=ROOT, encoding="utf-8",
    )


def count(base, candidate):
    base_commit = git("rev-parse", f"{base}^{{commit}}").strip()
    candidate_commit = git("rev-parse", f"{candidate}^{{commit}}").strip()
    diff = git("diff", "--no-ext-diff", "--no-renames", "--unified=0",
               base_commit, candidate_commit, "--", "*.mbt")
    result = {
        "implementation_added": 0, "implementation_deleted": 0,
        "test_added": 0, "test_deleted": 0,
    }
    current_path = None
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current_path = None
        elif line.startswith("--- a/"):
            current_path = line[6:]
        elif line.startswith("+++ b/"):
            current_path = line[6:]
        elif current_path and line[:1] in ("+", "-"):
            value = line[1:].strip()
            if not value or value.startswith("//"):
                continue
            path = Path(current_path)
            is_test = path.name.endswith(("_test.mbt", "_wbtest.mbt")) or "tests" in path.parts
            category = "test" if is_test else "implementation"
            direction = "added" if line[0] == "+" else "deleted"
            result[f"{category}_{direction}"] += 1
    result["implementation_net_added"] = (
        result["implementation_added"] - result["implementation_deleted"]
    )
    result["base_commit"] = base_commit
    result["candidate_commit"] = candidate_commit
    result["count_rule"] = (
        "Changed .mbt lines excluding blanks and // comments; tests counted separately. "
        "Generated .mbti, other languages, documents and unchanged upstream code excluded. "
        "Added and net-added counts are distinct; formatting can affect line counts."
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=BASELINE)
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rendered = json.dumps(count(args.base, args.candidate), indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8", newline="\n")
    print(rendered, end="")


if __name__ == "__main__":
    main()

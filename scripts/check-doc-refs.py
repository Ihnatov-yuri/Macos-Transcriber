#!/usr/bin/env python3
"""Checks that the docs still point at code that exists.

Every `testName` (or `testPrefix*`), `SomethingTests` class and source path
(`.swift`, `.sh`, `.py`, `.c`, `.yml`) quoted in backticks in README.md and
docs/*.md must still be in the repository. Historical documents are skipped.

    scripts/check-doc-refs.py        exit 1 and list every stale reference
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Written about the app as it was; they are not kept in step with the code.
HISTORICAL = {"docs/PLAN-original.md", "docs/building-a-local-transcriber.md"}

files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                       text=True, check=True).stdout.split()
tests = "\n".join((ROOT / f).read_text(encoding="utf-8")
                  for f in files if f.startswith("TranscriberrTests/") and f.endswith(".swift"))
test_funcs = set(re.findall(r"func (test\w+)", tests))
test_classes = set(re.findall(r"class (\w+Tests)\b", tests))

docs = ["README.md"] + sorted(f for f in files
                              if f.startswith("docs/") and f.endswith(".md") and f not in HISTORICAL)
code = re.compile(r"`([^`\n]+)`")
path_like = re.compile(r"^[\w./-]+\.(swift|sh|py|c|yml)$")

stale = []
for doc in docs:
    for lineno, line in enumerate((ROOT / doc).read_text(encoding="utf-8").splitlines(), 1):
        for ref in code.findall(line):
            ref = ref.strip().removeprefix("./")
            if re.fullmatch(r"test\w+\*?", ref):
                name = ref.rstrip("*")
                ok = any(t.startswith(name) for t in test_funcs) if ref.endswith("*") else name in test_funcs
            elif re.fullmatch(r"\w+Tests", ref):
                # A test class, a test file's name, or the test target itself.
                ok = (ref in test_classes or f"TranscriberrTests/{ref}.swift" in files
                      or any(f.startswith(ref + "/") for f in files))
            elif path_like.match(ref):
                # Docs quote paths relative to the repo or to Transcriberr/.
                ok = any(f == ref or f.endswith("/" + ref) for f in files)
            else:
                continue
            if not ok:
                stale.append(f"{doc}:{lineno}: `{ref}` not found")

for s in stale:
    print(s)
print(f"checked {len(docs)} documents: {'FAIL' if stale else 'OK'}")
sys.exit(1 if stale else 0)

"""Engine-source patches that can be shared publicly: no line of the original engine source is included.

A normal patch carries the engine lines it removes and its context lines, which are Epic Engine Code. A hashpatch
instead identifies every original line it touches by line number + SHA-256, and every added line that also exists
in the original files (moved code) by a reference to that original line. Only lines that appear nowhere in the
original source are carried as text. Applying it needs your own copy of exactly the same engine source: every
touched file is checked against the SHA-256 of its text first (line endings normalised to LF, so a git checkout with
CRLF conversion matches too).

    python hashpatch.py make  <git diff file> <original engine root> <out.json>    (authors: from a unified diff)
    python hashpatch.py apply <in.json> <engine root>                               (builders: edits files in place)
    python hashpatch.py check <in.json> <engine root>                               (dry run: verifies hashes only)

Engine root = the folder that contains Engine/. Files are written with the original line endings (CRLF or LF).

Files the patch creates (new files in the diff, "--- /dev/null") are stored with "create": true and no hash. Their
lines follow the same rule, so any line that also exists in the original files is a reference, not text. apply
refuses if such a file already exists. New files are written with LF line endings. A patch without new files comes
out the same as with the ITR1 version of this script.
"""
import hashlib
import json
import os
import re
import sys


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def read_lines(path):
    raw = open(path, "rb").read()
    text = raw.decode("utf-8-sig") if raw.startswith(b"\xef\xbb\xbf") else raw.decode("utf-8")
    crlf = text.count("\r\n")
    eol = "\r\n" if crlf > text.count("\n") / 2 else "\n"          # written back with the dominant line ending
    return raw, text.replace("\r\n", "\n").split("\n"), eol, raw.startswith(b"\xef\xbb\xbf")


def parse_diff(path):
    """[(file, [(old_start, [(op, text)])])] from a unified (git) diff."""
    files, cur, hunk, new = [], None, None, set()
    from_null = False
    for line in open(path, encoding="utf-8").read().split("\n"):
        line = line.rstrip("\r")
        if line.startswith("diff --git"):
            cur, hunk, from_null = None, None, False
        elif line.startswith("--- ") and cur is None:
            from_null = line == "--- /dev/null"
        elif line.startswith("+++ "):
            cur = (line[6:] if line.startswith("+++ b/") else line[4:], [])
            files.append(cur)
            if from_null:
                new.add(cur[0])
        elif line.startswith("@@") and cur is not None:
            m = re.match(r"@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", line)
            hunk = (int(m.group(1)), [])
            cur[1].append(hunk)
        elif hunk is not None and cur is not None and line[:1] in (" ", "-", "+"):
            hunk[1].append((line[0], line[1:]))
    return files, new


def make(diff, root, out):
    files, new = parse_diff(diff)
    originals = {}
    for f, _ in files:
        if f in new:
            if os.path.exists(os.path.join(root, f)):
                sys.exit(f"{f}: the diff creates it, but it exists in the original root")
            originals[f] = (None, [])
            continue
        _, lines, _, _ = read_lines(os.path.join(root, f))
        originals[f] = (sha("\n".join(lines)), lines)
    index = {}                                  # original line text -> (file, 1-based line), for moved lines
    for f, (_, lines) in originals.items():
        if f in new:
            continue
        for i, l in enumerate(lines):
            if l.strip():
                index.setdefault(l, (f, i + 1))
    doc = {"format": "hashpatch/1", "files": []}
    literal = referenced = 0
    for f, hunks in files:
        fsha, lines = originals[f]
        edits = []
        for start, ops in hunks:
            ln = start                          # 1-based line in the original
            edit = None
            if f in new:
                ln = 1                          # "@@ -0,0 +1,N @@": the whole file is one addition at line 1
            for op, text in ops:
                if op == " ":
                    if lines[ln - 1] != text:
                        sys.exit(f"{f}:{ln}: context mismatch (diff not made against these originals)")
                    edit = None
                    ln += 1
                    continue
                if edit is None:
                    edit = {"line": ln, "remove": [], "add": []}
                    edits.append(edit)
                if op == "-":
                    if lines[ln - 1] != text:
                        sys.exit(f"{f}:{ln}: removed line mismatch")
                    edit["remove"].append(sha(text))
                    ln += 1
                else:
                    if text in index:
                        rf, rl = index[text]
                        edit["add"].append({"ref": [rf, rl]})
                        referenced += 1
                    else:
                        edit["add"].append({"text": text})
                        literal += 1
        if f in new:
            doc["files"].append({"path": f, "create": True, "edits": edits})
        else:
            doc["files"].append({"path": f, "sha256": fsha, "edits": edits})
    json.dump(doc, open(out, "w", encoding="utf-8", newline="\n"), indent=1)
    print(f"{len(files)} files, {sum(len(x['edits']) for x in doc['files'])} edits; added lines: {literal} new text, "
          f"{referenced} referenced from the original source -> {out}")


def apply(inp, root, write=True):
    doc = json.load(open(inp, encoding="utf-8"))
    assert doc["format"] == "hashpatch/1"
    loaded = {}
    for f in doc["files"]:
        if f.get("create"):
            if os.path.exists(os.path.join(root, f["path"])):
                sys.exit(f"{f['path']}: the patch creates this file, but it already exists; already patched?")
            loaded[f["path"]] = ([], "\n", False)
            continue
        raw, lines, eol, bom = read_lines(os.path.join(root, f["path"]))
        got = sha("\n".join(lines))
        if got != f["sha256"]:
            sys.exit(f"{f['path']}: not the expected original (sha256 {got}); already patched, or a different engine version")
        loaded[f["path"]] = (lines, eol, bom)
    originals = {p: list(v[0]) for p, v in loaded.items()}
    created = {f["path"] for f in doc["files"] if f.get("create")}

    def ref_line(rf, rl):
        if rf in created:
            sys.exit(f"{rf}: a reference points into a file the patch creates (malformed patch)")
        if rf not in originals:
            raw, lines, _, _ = read_lines(os.path.join(root, rf))
            originals[rf] = lines
        return originals[rf][rl - 1]

    for f in doc["files"]:
        lines, eol, bom = loaded[f["path"]]
        for e in sorted(f["edits"], key=lambda e: -e["line"]):     # bottom up: earlier line numbers stay valid
            i = e["line"] - 1
            for k, h in enumerate(e["remove"]):
                if sha(lines[i + k]) != h:
                    sys.exit(f"{f['path']}:{e['line'] + k}: line hash mismatch")
            new = [a["text"] if "text" in a else ref_line(*a["ref"]) for a in e["add"]]
            lines[i:i + len(e["remove"])] = new
        if f.get("create") and lines and lines[-1] != "":
            lines.append("")                                       # end a new file with a newline
        if write:
            data = eol.join(lines).encode("utf-8")
            out = os.path.join(root, f["path"])
            if f.get("create"):
                os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write((b"\xef\xbb\xbf" if bom else b"") + data)
    print(("patched" if write else "check ok:") + f" {len(doc['files'])} files")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "make" and len(sys.argv) == 5:
        make(*sys.argv[2:])
    elif cmd in ("apply", "check") and len(sys.argv) == 4:
        apply(sys.argv[2], sys.argv[3], write=cmd == "apply")
    else:
        sys.exit(__doc__)

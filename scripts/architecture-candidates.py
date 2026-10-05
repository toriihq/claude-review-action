#!/usr/bin/env python3
"""Textual candidates for the architecture review. A floor, not a ceiling."""
import os
import re
import subprocess
from pathlib import Path

WORKDIR = Path(os.environ.get("ARCHITECTURE_WORKDIR", ".")).resolve()
OUT = Path("/tmp/architecture-candidates.md")
DIFFS = [Path("/tmp/pr-diff.txt")]
extra = Path("/tmp/pr-diffs")
if extra.is_dir():
    DIFFS.extend(sorted(extra.rglob("*.diff")))

SKIP_NAMES = {
    "if", "for", "map", "set", "get", "add", "run", "log", "err", "error",
    "data", "type", "name", "test", "describe", "it", "expect", "return",
    "const", "function", "async", "await", "from", "import", "export",
    "true", "false", "null", "undefined", "string", "number", "boolean",
}
SKIP_DIRS = {"node_modules", ".git", "dist", "coverage", "build", ".yarn", "vendor"}
SRC_EXT = {".ts", ".tsx", ".js", ".jsx", ".sql"}

def added_by_file():
    files = {}
    current = None
    for diff in DIFFS:
        if not diff.is_file() or diff.stat().st_size == 0:
            continue
        for line in diff.read_text(errors="replace").splitlines():
            if line.startswith("diff --git "):
                parts = line.split(" b/", 1)
                current = parts[1] if len(parts) == 2 else None
                if current:
                    files.setdefault(current, [])
                continue
            if current and line.startswith("+") and not line.startswith("+++"):
                files[current].append(line[1:])
    return {k: v for k, v in files.items() if v and Path(k).suffix in SRC_EXT and "lock" not in k}

def names_from(lines):
    found = []
    patterns = [
        r"(?:export\s+)?(?:async\s+)?function\s+(\w+)",
        r"(?:export\s+)?(?:const|let)\s+(\w+)\s*=\s*(?:async\s+)?(?:function|\()",
        r"^\s*(?:public|private|protected|static|async\s+)*(\w+)\s*\([^;]*\)\s*\{",
    ]
    for line in lines:
        for pat in patterns:
            for name in re.findall(pat, line):
                if len(name) >= 6 and name.lower() not in SKIP_NAMES and name not in found:
                    found.append(name)
    return found[:8]

def literals_from(lines):
    found = []
    for line in lines:
        for lit in re.findall(r"""['"]([^'"\n]{12,80})['"]""", line):
            if "${" in lit or lit.startswith("http") or lit in found:
                continue
            if re.fullmatch(r"[\w./ -]+", lit) is None:
                continue
            found.append(lit)
    return found[:6]

def roots():
    chosen = [WORKDIR / name for name in ("projects", "packages") if (WORKDIR / name).is_dir()]
    return chosen or [WORKDIR]

def grep(pattern, fixed):
    cmd = ["grep", "-R", "-n", "-I", "--binary-files=without-match"]
    for skip in SKIP_DIRS:
        cmd.append(f"--exclude-dir={skip}")
    cmd += ["--include=*.ts", "--include=*.tsx", "--include=*.js", "--include=*.jsx"]
    cmd += ["-F", "-e", pattern] if fixed else ["-E", "-e", pattern]
    cmd += [str(r) for r in roots()]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
    except (subprocess.TimeoutExpired, OSError):
        return []
    hits = []
    for line in proc.stdout.splitlines():
        if line.startswith("Binary file"):
            continue
        hits.append(line)
        if len(hits) >= 4:
            break
    return hits

def rel(path):
    try:
        return str(Path(path).resolve().relative_to(WORKDIR))
    except ValueError:
        return path

def siblings(path):
    folder = WORKDIR / Path(path).parent
    if not folder.is_dir():
        return []
    out = []
    for child in sorted(folder.iterdir()):
        if not child.is_file() or child.suffix not in SRC_EXT:
            continue
        if str(child.relative_to(WORKDIR)) == path:
            continue
        out.append(str(child.relative_to(WORKDIR)))
        if len(out) >= 6:
            break
    return out

def main():
    files = added_by_file()
    lines = ["### Candidates you must judge", ""]
    if not files:
        lines.append("No source lines were added. Duplication may still be `none`.")
        OUT.write_text("\n".join(lines) + "\n")
        return
    lines.append("Changed files:")
    all_names = []
    all_lits = []
    sibs = []
    for path, body in list(files.items())[:12]:
        names = names_from(body)
        all_names.extend(n for n in names if n not in all_names)
        all_lits.extend(lit for lit in literals_from(body) if lit not in all_lits)
        sibs.extend(s for s in siblings(path) if s not in sibs)
        shown = ", ".join(names) if names else "no new named function"
        lines.append(f"- `{path}` — {shown}")
    lines.append("")
    lines.append("Sibling files to read (a differently worded copy usually lives here):")
    if sibs:
        lines.extend(f"- `{s}`" for s in sibs[:12])
    else:
        lines.append("- none in the same directory")
    lines.append("")
    lines.append("Textual hits. Judge every hit. Say when the words match but the job does not.")
    hit_count = 0
    queries = [(name, rf"\b{re.escape(name)}\b", False) for name in all_names[:8]]
    queries += [(lit, lit, True) for lit in all_lits[:6]]
    for label, pattern, fixed in queries:
        hits = grep(pattern, fixed)
        own = [h for h in hits if label not in h.split(":", 1)[0] or True]
        # drop hits that are only inside a changed file's own added name declaration by keeping all and letting the model judge
        shown = own[:4]
        if not shown:
            continue
        hit_count += len(shown)
        lines.append(f"- `{label}`")
        for hit in shown:
            # grep prints absolute path
            parts = hit.split(":", 2)
            if len(parts) >= 3:
                lines.append(f"  - `{rel(parts[0])}:{parts[1]}` {parts[2].strip()[:160]}")
            else:
                lines.append(f"  - `{hit[:200]}`")
    if hit_count == 0:
        lines.append("- no textual hit")
    lines.append("")
    lines.append("No textual hit is not `none`. Read each changed file and the siblings above.")
    lines.append("If two functions do the same job in different words, that is still duplication. Add it.")
    OUT.write_text("\n".join(lines) + "\n")

if __name__ == "__main__":
    main()

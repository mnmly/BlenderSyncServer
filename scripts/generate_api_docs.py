#!/usr/bin/env python3
"""Generate API.md from Swift /// doc comments and Python docstrings.

Self-contained: stdlib only. Run from the repo root:
    python3 scripts/generate_api_docs.py
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT_ROOT = REPO / "Sources" / "BlenderSyncServer"
PY_ROOT = REPO / "blender-addon" / "bl_camera_sync"
OUT = REPO / "API.md"


# ---------------------------------------------------------------------------
# Swift
# ---------------------------------------------------------------------------

# Matches a public declaration line. Captures the signature up to the first
# `{`, `=`, or end-of-line. Skips lines that are clearly inside a body by
# requiring the `public` keyword at the start of the trimmed line.
PUBLIC_DECL = re.compile(
    r"^\s*public\s+(?:final\s+|static\s+|indirect\s+|override\s+|convenience\s+|fileprivate\s+|internal\s+)*"
    r"(?P<kind>actor|class|struct|enum|protocol|extension|typealias|func|var|let|init|subscript|case)\b"
)


def extract_swift(path: Path) -> list[dict]:
    """Return a list of {kind, signature, doc, line} for each public symbol."""
    lines = path.read_text().splitlines()
    out: list[dict] = []

    # File-level header: leading /// block at the top.
    file_doc: list[str] = []
    i = 0
    while i < len(lines) and (lines[i].strip().startswith("///") or not lines[i].strip()):
        s = lines[i].strip()
        if s.startswith("///"):
            file_doc.append(s[3:].lstrip())
        elif s == "" and file_doc:
            # blank line ends the header block unless next is also ///
            if i + 1 < len(lines) and lines[i + 1].strip().startswith("///"):
                file_doc.append("")
            else:
                break
        i += 1
    if file_doc:
        out.append({"kind": "file", "signature": path.name, "doc": "\n".join(file_doc).rstrip(), "line": 1})

    # Walk file, collecting /// blocks that immediately precede a public decl.
    doc_buf: list[str] = []
    for idx, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped.startswith("///"):
            doc_buf.append(stripped[3:].lstrip())
            continue
        if stripped == "" or stripped.startswith("//"):
            # Comments other than /// reset the buffer; blank lines also reset.
            doc_buf = []
            continue
        m = PUBLIC_DECL.match(raw)
        if m and doc_buf:
            sig = _collect_signature(lines, idx)
            out.append({
                "kind": m.group("kind"),
                "signature": sig,
                "doc": "\n".join(doc_buf).rstrip(),
                "line": idx + 1,
            })
        doc_buf = []
    return out


def _collect_signature(lines: list[str], idx: int) -> str:
    """Collect a declaration signature, possibly spanning lines.

    Strategy: keep collecting while parentheses or angle brackets are unbalanced
    (multi-line function signatures). Once balanced, stop — single-line property
    and case declarations finish on the first line.
    """
    parts: list[str] = []
    depth_paren = 0
    depth_angle = 0
    for j in range(idx, min(idx + 20, len(lines))):
        raw = lines[j].rstrip()
        # Strip trailing `// comment` but NOT `/// doc` (which never appears mid-decl anyway).
        s = re.sub(r"\s+//(?!/)[^\n]*$", "", raw).rstrip()
        parts.append(s.strip())
        depth_paren += s.count("(") - s.count(")")
        # Generics: `<` and `>` are also used as operators, but on declaration
        # lines they're balanced type params, so this heuristic holds.
        depth_angle += s.count("<") - s.count(">")
        if depth_paren <= 0 and depth_angle <= 0:
            break
    sig = " ".join(p for p in parts if p)
    # Strip trailing single-line body `{ ... }` or just `{`.
    sig = re.sub(r"\s*\{[^{}]*\}\s*$", "", sig)
    sig = re.sub(r"\s*\{\s*$", "", sig).strip()
    return sig


# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

def extract_python(path: Path) -> list[dict]:
    src = path.read_text()
    tree = ast.parse(src, filename=str(path))
    out: list[dict] = []

    mod_doc = ast.get_docstring(tree)
    if mod_doc:
        out.append({"kind": "module", "signature": path.name, "doc": mod_doc, "line": 1})

    def visit(node: ast.AST, qualname: str = ""):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # Skip private (leading underscore) except dunder.
                name = child.name
                if name.startswith("_") and not (name.startswith("__") and name.endswith("__")):
                    continue
                doc = ast.get_docstring(child)
                if not doc:
                    continue
                sig = _py_sig(child, qualname)
                out.append({"kind": "func", "signature": sig, "doc": doc, "line": child.lineno})
            elif isinstance(child, ast.ClassDef):
                doc = ast.get_docstring(child)
                qual = f"{qualname}.{child.name}" if qualname else child.name
                if doc:
                    out.append({
                        "kind": "class",
                        "signature": f"class {qual}",
                        "doc": doc,
                        "line": child.lineno,
                    })
                # Recurse for methods.
                visit(child, qual)

    visit(tree)
    return out


def _py_sig(node: ast.FunctionDef | ast.AsyncFunctionDef, qualname: str) -> str:
    args = []
    a = node.args
    posonly = getattr(a, "posonlyargs", [])
    for arg in posonly + a.args:
        args.append(arg.arg)
    if a.vararg:
        args.append("*" + a.vararg.arg)
    for arg in a.kwonlyargs:
        args.append(arg.arg)
    if a.kwarg:
        args.append("**" + a.kwarg.arg)
    qual = f"{qualname}." if qualname else ""
    prefix = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
    return f"{prefix} {qual}{node.name}({', '.join(args)})"


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

KIND_LABEL = {
    "actor": "Actor",
    "class": "Class",
    "struct": "Struct",
    "enum": "Enum",
    "protocol": "Protocol",
    "extension": "Extension",
    "typealias": "Type alias",
    "func": "Function",
    "var": "Property",
    "let": "Property",
    "init": "Initializer",
    "subscript": "Subscript",
    "case": "Case",
    "module": "Module",
    "file": "Overview",
}


def main() -> int:
    swift_files = sorted(SWIFT_ROOT.glob("*.swift"))
    py_files = sorted(PY_ROOT.glob("*.py"))

    parts: list[str] = ["# BlenderSyncServer API", "",
                       "Auto-generated from source comments by `scripts/generate_api_docs.py`.",
                       "Edit the source doc comments, not this file.", "", "---", ""]

    parts.append("# Swift package")
    parts.append("")
    for p in swift_files:
        entries = extract_swift(p)
        parts.append(render_section(p, entries))

    parts.append("---")
    parts.append("")
    parts.append("# Blender addon (`bl_camera_sync`)")
    parts.append("")
    for p in py_files:
        entries = extract_python(p)
        parts.append(render_section(p, entries))

    OUT.write_text("\n".join(parts).rstrip() + "\n")
    print(f"wrote {OUT.relative_to(REPO)} "
          f"({sum(len(extract_swift(p)) for p in swift_files)} Swift entries, "
          f"{sum(len(extract_python(p)) for p in py_files)} Python entries)")
    return 0


def render_section(path: Path, entries: list[dict]) -> str:
    if not entries:
        return ""
    rel = path.relative_to(REPO)
    lines = [f"## `{rel}`", ""]
    for e in entries:
        label = KIND_LABEL.get(e["kind"], e["kind"].capitalize())
        if e["kind"] in ("file", "module"):
            lines.append("### Overview")
        else:
            sig = e["signature"]
            lines.append(f"### {label} — `{sig}`")
        lines.append("")
        if e["doc"]:
            lines.append(e["doc"].rstrip())
            lines.append("")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())

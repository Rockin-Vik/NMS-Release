#!/usr/bin/env python3
"""Generate custom-rules/README.md from ruletypes.h and clusters.json.

Names, types, compiled defaults, and notes come from the header. Cluster
assignment and related-rule groups are the only hand-maintained data in
clusters.json — they are what the header does not give you. A new Custom rule
that is not in clusters.json lands under Unclustered and fails --check.

  python Release-NMS-Deploy/custom-rules/generate.py
  python Release-NMS-Deploy/custom-rules/generate.py --check

Do not hand-edit custom-rules/README.md.

Guards: ``--check`` and the loaders reject unclustered rules, stale cluster-map
names, related names not in the header, related groups spanning clusters,
README drift, a rule listed in two clusters or related groups, duplicate cluster
titles, duplicate JSON keys anywhere in ``clusters.json``, and preprocessor
lines inside ``RULE_CATEGORY(Custom)``.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
HEADER = REPO_ROOT / "Release-NMS-Server" / "common" / "ruletypes.h"
OUTPUT = SCRIPT_DIR / "README.md"
CLUSTERS_FILE = SCRIPT_DIR / "clusters.json"

UNCLUSTERED_TITLE = "Unclustered"
UNCLUSTERED_BLURB = (
    "Parsed from the Custom block but missing from `clusters.json`. "
    "Add an assignment before committing — `--check` fails while this section is non-empty."
)

RULE_LINE = re.compile(
    r"^RULE_(INT|BOOL|REAL|STRING)\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(.*)\)$"
)
NOTE_TAIL = re.compile(r""",\s*"((?:[^"\\]|\\.)*)"\s*$""")


@dataclass(frozen=True)
class Rule:
    type: str
    category: str
    name: str
    default: str
    notes: str
    line: int


def _reject_duplicate_json_keys(path: Path, pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: dict[str, Any] = {}
    for key, value in pairs:
        if key in seen:
            raise SystemExit(f"{path}: duplicate JSON key: {key!r}")
        seen[key] = value
    return seen


def load_cluster_config(
    path: Path,
) -> tuple[list[tuple[str, str, frozenset[str]]], list[frozenset[str]]]:
    text = path.read_text(encoding="utf-8")
    try:
        raw: Any = json.loads(
            text,
            object_pairs_hook=lambda pairs: _reject_duplicate_json_keys(path, pairs),
        )
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON: {exc}") from exc

    if not isinstance(raw, dict):
        raise SystemExit(f"{path}: root must be a JSON object")

    expected_keys = {"clusters", "related_groups"}
    actual_keys = set(raw.keys())
    if actual_keys != expected_keys:
        parts: list[str] = []
        missing = expected_keys - actual_keys
        extra = actual_keys - expected_keys
        if missing:
            parts.append(f"missing top-level keys: {', '.join(sorted(missing))}")
        if extra:
            parts.append(f"unexpected top-level keys: {', '.join(sorted(extra))}")
        raise SystemExit(f"{path}: {'; '.join(parts)}")

    clusters_raw = raw["clusters"]
    related_raw = raw["related_groups"]
    if not isinstance(clusters_raw, list):
        raise SystemExit(f"{path}: clusters must be an array")
    if not isinstance(related_raw, list):
        raise SystemExit(f"{path}: related_groups must be an array")

    clusters: list[tuple[str, str, frozenset[str]]] = []
    seen_in_clusters: dict[str, str] = {}
    seen_titles: set[str] = set()

    for index, cluster in enumerate(clusters_raw):
        if not isinstance(cluster, dict):
            raise SystemExit(f"{path}: clusters[{index}] must be an object")
        for key in ("title", "blurb", "rules"):
            if key not in cluster:
                label = cluster.get("title", index)
                raise SystemExit(f"{path}: cluster {label!r} missing {key!r}")
        title = cluster["title"]
        blurb = cluster["blurb"]
        rules = cluster["rules"]
        if not isinstance(title, str):
            raise SystemExit(f"{path}: clusters[{index}].title must be a string")
        if title in seen_titles:
            raise SystemExit(f"Duplicate cluster title: {title!r}")
        seen_titles.add(title)
        if not isinstance(blurb, str):
            raise SystemExit(f"{path}: cluster {title!r}: blurb must be a string")
        if not isinstance(rules, list):
            raise SystemExit(f"{path}: cluster {title!r}: rules must be an array")
        if not rules:
            raise SystemExit(f"{path}: cluster {title!r}: rules must not be empty")
        rule_names: list[str] = []
        for rule_index, name in enumerate(rules):
            if not isinstance(name, str):
                raise SystemExit(
                    f"{path}: cluster {title!r}: rules[{rule_index}] must be a string"
                )
            if name in seen_in_clusters:
                raise SystemExit(
                    f"Rule {name} is in two clusters: {seen_in_clusters[name]!r} and {title!r}"
                )
            seen_in_clusters[name] = title
            rule_names.append(name)
        clusters.append((title, blurb, frozenset(rule_names)))

    related_groups: list[frozenset[str]] = []
    seen_in_related: dict[str, frozenset[str]] = {}

    for index, group in enumerate(related_raw):
        if not isinstance(group, list):
            raise SystemExit(f"{path}: related_groups[{index}] must be an array")
        if not group:
            raise SystemExit(f"{path}: related_groups[{index}] must not be empty")
        names: list[str] = []
        for name_index, name in enumerate(group):
            if not isinstance(name, str):
                raise SystemExit(
                    f"{path}: related_groups[{index}][{name_index}] must be a string"
                )
            names.append(name)
        frozen = frozenset(names)
        for name in frozen:
            if name in seen_in_related:
                raise SystemExit(f"Rule {name} is in two related groups")
            seen_in_related[name] = frozen
        related_groups.append(frozen)

    return clusters, related_groups


def parse_custom_block(text: str) -> tuple[list[Rule], list[Rule]]:
    """Return (custom_rules, stray_rules_declared_inside_the_block)."""
    lines = text.splitlines()
    start = None
    end = None
    for i, raw in enumerate(lines):
        if raw.strip() == "RULE_CATEGORY(Custom)":
            start = i
        elif start is not None and raw.strip() == "RULE_CATEGORY_END()":
            end = i
            break
    if start is None or end is None:
        raise SystemExit(f"Could not find RULE_CATEGORY(Custom) in {HEADER}")

    custom: list[Rule] = []
    stray: list[Rule] = []
    for i in range(start + 1, end):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("#"):
            raise SystemExit(
                f"{HEADER}:{i + 1}: conditional compilation inside RULE_CATEGORY(Custom) "
                "is not supported by the catalog generator"
            )
        match = RULE_LINE.match(stripped)
        if not match:
            raise SystemExit(f"{HEADER}:{i + 1}: unparseable rule line:\n  {stripped}")
        kind, category, name, rest = match.groups()
        note_match = NOTE_TAIL.search(rest)
        if note_match:
            default = rest[: note_match.start()].strip()
            notes = note_match.group(1).replace('\\"', '"')
        else:
            default = rest.strip()
            notes = ""
        rule = Rule(kind, category, name, default, notes, i + 1)
        if category == "Custom":
            custom.append(rule)
        else:
            stray.append(rule)
    return custom, stray


def cluster_index(
    clusters: list[tuple[str, str, frozenset[str]]],
) -> dict[str, str]:
    seen: dict[str, str] = {}
    for title, _blurb, names in clusters:
        for name in names:
            if name in seen:
                raise SystemExit(
                    f"Rule {name} is in two clusters: {seen[name]!r} and {title!r}"
                )
            seen[name] = title
    return seen


def related_index(related_groups: list[frozenset[str]]) -> dict[str, frozenset[str]]:
    seen: dict[str, frozenset[str]] = {}
    for group in related_groups:
        for name in group:
            if name in seen:
                raise SystemExit(f"Rule {name} is in two related groups")
            seen[name] = group
    return seen


def md_plain_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def md_note_cell(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("|", "\\|")
        .replace("\n", " ")
    )


def md_code_span(value: str) -> str:
    escaped = value.replace("|", "\\|").replace("\n", " ")
    if "`" in escaped:
        return f"`` {escaped} ``"
    return f"`{escaped}`"


def related_cell(name: str, related: dict[str, frozenset[str]]) -> str:
    group = related.get(name)
    if not group:
        return "—"
    others = " ".join(f"`{n}`" for n in sorted(group) if n != name)
    return others or "—"


def render(
    custom: list[Rule],
    stray: list[Rule],
    assignments: dict[str, str],
    clusters: list[tuple[str, str, frozenset[str]]],
    related_groups: list[frozenset[str]],
) -> str:
    related = related_index(related_groups)
    by_cluster: dict[str, list[Rule]] = {title: [] for title, _blurb, _names in clusters}
    by_cluster[UNCLUSTERED_TITLE] = []
    for rule in custom:
        by_cluster[assignments.get(rule.name, UNCLUSTERED_TITLE)].append(rule)

    with_notes = sum(1 for r in custom if r.notes)
    unclustered = by_cluster[UNCLUSTERED_TITLE]
    mapped_names = set(assignments)
    parsed_names = {r.name for r in custom}
    stale = sorted(mapped_names - parsed_names)

    lines: list[str] = [
        "# Custom rule catalog",
        "",
        "> Generated by `custom-rules/generate.py` from "
        f"`Release-NMS-Server/common/ruletypes.h` and `Release-NMS-Deploy/custom-rules/clusters.json`. "
        "Do not edit this file by hand.",
        ">",
        "> **`clusters.json` is the only hand-edited input** besides the header. Cluster assignment "
        "and related-rule groups live there.",
        ">",
        "> **Defaults are compiled defaults**, not live `rule_values`. "
        "The first diagnostic question is still: which rule, and what is it set to in the DB?",
        ">",
        "> Narrative and gotchas stay in [CODEBASE.md](../CODEBASE.md). This file is the lookup index.",
        "",
        f"- Custom rules parsed: **{len(custom)}**",
        f"- With an inline note: **{with_notes}**",
        f"- Unclustered: **{len(unclustered)}**",
        "",
        "Regenerate:",
        "",
        "```",
        "python Release-NMS-Deploy/custom-rules/generate.py",
        "```",
        "",
        "## Clusters",
        "",
    ]

    for title, blurb, names in clusters:
        rules = by_cluster[title]
        lines.append(f"- [{title}](#{_slug(title)}) — {len(rules)} rules")
        if len(rules) != len(names):
            missing = sorted(names - {r.name for r in rules})
            extra = sorted({r.name for r in rules} - names)
            if missing:
                lines.append(f"  - mapped but not in header: {', '.join(missing)}")
            if extra:
                lines.append(
                    f"  - in header but not mapped here (should be impossible): {', '.join(extra)}"
                )
    if unclustered:
        lines.append(
            f"- [{UNCLUSTERED_TITLE}](#{_slug(UNCLUSTERED_TITLE)}) — {len(unclustered)} rules"
        )
    lines.append("")

    sections: list[tuple[str, str, list[Rule]]] = [
        (title, blurb, by_cluster[title]) for title, blurb, _names in clusters
    ]
    if unclustered:
        sections.append((UNCLUSTERED_TITLE, UNCLUSTERED_BLURB, unclustered))

    for title, blurb, rules in sections:
        lines.extend(
            [
                f"## {title}",
                "",
                blurb,
                "",
                "| Rule | Type | Default | Related | Notes |",
                "| --- | --- | --- | --- | --- |",
            ]
        )
        for rule in rules:
            default = rule.default
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{rule.name}`",
                        rule.type,
                        md_code_span(default),
                        md_plain_cell(related_cell(rule.name, related)),
                        md_note_cell(rule.notes) or "—",
                    ]
                )
                + " |"
            )
        lines.append("")

    if stray:
        lines.extend(
            [
                "## Declared inside the Custom block, but not `Custom:`",
                "",
                "These macros sit between `RULE_CATEGORY(Custom)` and `RULE_CATEGORY_END()` "
                "but name a different category. They are stock-category rules parked in the "
                "wrong block — called out so they are not mistaken for Custom knobs.",
                "",
                "| Line | Category | Rule | Type | Default | Notes |",
                "| --- | --- | --- | --- | --- | --- |",
            ]
        )
        for rule in stray:
            lines.append(
                "| "
                + " | ".join(
                    [
                        str(rule.line),
                        rule.category,
                        f"`{rule.name}`",
                        rule.type,
                        md_code_span(rule.default),
                        md_note_cell(rule.notes) or "—",
                    ]
                )
                + " |"
            )
        lines.append("")

    if stale:
        lines.extend(
            [
                "## Stale cluster map entries",
                "",
                "These names are in `CLUSTERS` but were not parsed from the header:",
                "",
            ]
        )
        for name in stale:
            lines.append(f"- `{name}`")
        lines.append("")

    return "\n".join(lines)


def _slug(title: str) -> str:
    # Mirror github-slugger: lowercase, drop punctuation, then map EACH space to
    # a hyphen without collapsing runs ("A / B" -> "a--b").
    cleaned = re.sub(r"[^a-z0-9 \-]", "", title.lower())
    return cleaned.replace(" ", "-")


def check(
    custom: list[Rule],
    stray: list[Rule],
    assignments: dict[str, str],
    clusters: list[tuple[str, str, frozenset[str]]],
    related_groups: list[frozenset[str]],
) -> int:
    parsed = {r.name for r in custom}
    mapped = set(assignments)
    unclustered = sorted(parsed - mapped)
    stale = sorted(mapped - parsed)
    related_names = {n for group in related_groups for n in group}
    related_unknown = sorted(related_names - parsed)
    # A related group is finer than a cluster, so it must not straddle two.
    straddling = [
        sorted(group)
        for group in related_groups
        if len({assignments.get(n) for n in group}) > 1
    ]
    errors = 0
    if unclustered:
        print("Unclustered Custom rules:", ", ".join(unclustered), file=sys.stderr)
        errors += 1
    if stale:
        print("Stale CLUSTERS entries:", ", ".join(stale), file=sys.stderr)
        errors += 1
    if related_unknown:
        print("RELATED_GROUPS names not in header:", ", ".join(related_unknown), file=sys.stderr)
        errors += 1
    for group in straddling:
        print("RELATED_GROUPS group spans clusters:", ", ".join(group), file=sys.stderr)
        errors += 1
    if not errors:
        # The drift guard proper: the committed file must equal a fresh render.
        rendered = render(custom, stray, assignments, clusters, related_groups)
        on_disk = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else None
        if on_disk != rendered:
            print(
                f"{OUTPUT.relative_to(REPO_ROOT)} is stale or hand-edited; regenerate with "
                "`python Release-NMS-Deploy/custom-rules/generate.py`",
                file=sys.stderr,
            )
            errors += 1
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if any Custom rule is unclustered, the map has stale names, "
        "a related group spans clusters, or custom-rules/README.md differs from a fresh render.",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Write markdown to stdout instead of custom-rules/README.md.",
    )
    args = parser.parse_args()

    clusters, related_groups = load_cluster_config(CLUSTERS_FILE)
    custom, stray = parse_custom_block(HEADER.read_text(encoding="utf-8"))
    assignments = cluster_index(clusters)

    if args.check:
        errors = check(custom, stray, assignments, clusters, related_groups)
        if stray:
            print(
                "Note: non-Custom macros inside the Custom block: "
                + ", ".join(f"{r.category}:{r.name}" for r in stray),
                file=sys.stderr,
            )
        return 1 if errors else 0

    markdown = render(custom, stray, assignments, clusters, related_groups)
    if args.stdout:
        sys.stdout.reconfigure(newline="\n")
        sys.stdout.write(markdown)
        return 0
    OUTPUT.write_text(markdown, encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)} ({len(custom)} Custom rules)")
    if stray:
        print(
            "Flagged inside Custom block but not Custom: "
            + ", ".join(f"{r.category}:{r.name}" for r in stray)
        )
    unclustered = [r.name for r in custom if r.name not in assignments]
    if unclustered:
        print("Unclustered (assign in clusters.json): " + ", ".join(unclustered))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

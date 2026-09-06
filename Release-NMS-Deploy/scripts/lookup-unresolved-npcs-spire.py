#!/usr/bin/env python3
"""Read-only Spire lookup for Mischief NPCs the local dump resolver missed.

Queries the public hosted PEQ API (spire.eqemu.dev) for each row in
unresolved-npcs.txt, then checks whether the same id/name exists in
release-peq.zip. Does not write seed SQL or change the resolver.

  python Release-NMS-Deploy/scripts/lookup-unresolved-npcs-spire.py

Override the API with NMS_SPIRE_URL (default https://spire.eqemu.dev/api/v1).
Hosted PEQ can be newer than this repo's frozen dump — treat spire_only hits
as research, not seed input.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

_spec = importlib.util.spec_from_file_location(
    "import_loot_buckets", SCRIPT_DIR / "import-loot-buckets.py"
)
_import_mod = importlib.util.module_from_spec(_spec)
sys.modules["import_loot_buckets"] = _import_mod
_spec.loader.exec_module(_import_mod)

CACHE_PATH = _import_mod.CACHE_PATH
DEFAULT_DUMP = _import_mod.DEFAULT_DUMP
DEFAULT_UNRESOLVED = _import_mod.DEFAULT_UNRESOLVED
ZONE_ALIASES = _import_mod.ZONE_ALIASES
ZONE_EQUIV = _import_mod.ZONE_EQUIV
load_or_build_index = _import_mod.load_or_build_index
norm_npc = _import_mod.norm_npc
norm_zone = _import_mod.norm_zone
npc_name_keys = _import_mod.npc_name_keys
resolve_zone = _import_mod.resolve_zone

DEFAULT_SPIRE = os.environ.get("NMS_SPIRE_URL", "https://spire.eqemu.dev/api/v1").rstrip("/")
DEFAULT_IN = DEFAULT_UNRESOLVED / "unresolved-npcs.txt"
DEFAULT_OUT = DEFAULT_UNRESOLVED / "spire-unresolved-npcs.txt"
USER_AGENT = "NMS-Release unresolved-npc lookup (read-only research)"
WEAK_TOKENS = frozenset(
    {
        "a",
        "an",
        "the",
        "of",
        "lord",
        "lady",
        "king",
        "queen",
        "priest",
        "noble",
        "knight",
        "golem",
        "spider",
        "bear",
        "drake",
        "wurm",
        "bandit",
        "harvester",
        "archaeologist",
        "alchemist",
        "ritualist",
        "templar",
        "archon",
        "diviner",
        "gypsy",
        "champion",
        "defender",
        "guardian",
        "caretaker",
        "keeper",
        "sentinel",
        "warden",
        "elder",
        "burrower",
        "anglerfish",
        "imprecator",
        "spectre",
        "berserker",
        "warlord",
        "watcher",
        "master",
        "experiment",
        "thieves",
        "jester",
    }
)
MAX_CANDIDATES = 8


@dataclass
class SheetRow:
    sheet: str
    row: str
    name: str
    zone: str
    bucket: str
    reason: str


@dataclass
class Candidate:
    npc_id: int
    name: str
    level: int
    loottable_id: int
    merchant_id: int
    unique_spawn: int
    rare_spawn: int
    raid_target: int
    untargetable: int
    zones: set[str] = field(default_factory=set)


def parse_unresolved(path: Path) -> list[SheetRow]:
    rows: list[SheetRow] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("#") or raw.startswith("sheet\t"):
            continue
        parts = raw.split("\t")
        if len(parts) < 6:
            continue
        rows.append(
            SheetRow(
                sheet=parts[0],
                row=parts[1],
                name=parts[2],
                zone=parts[3],
                bucket=parts[4],
                reason=parts[5],
            )
        )
    return rows


def _alias_zone(label: str) -> str | None:
    if not label:
        return None
    n = norm_zone(label)
    stripped = norm_zone(re.sub(r"[\[\(].*?[\]\)]", "", label))
    stripped = re.sub(r"\s+\d+(\.0)?$", "", stripped).strip()
    if n in ZONE_ALIASES:
        return ZONE_ALIASES[n]
    if stripped in ZONE_ALIASES:
        return ZONE_ALIASES[stripped]
    for key, short in ZONE_ALIASES.items():
        kn = norm_zone(key)
        if kn == n or kn == stripped:
            return short
    return None


def sheet_zone_sn(label: str, index) -> str | None:
    if index is not None:
        found = resolve_zone(label, index)
        if found:
            return found
    return _alias_zone(label)


def zone_set(sn: str | None) -> set[str]:
    if not sn:
        return set()
    return set(ZONE_EQUIV.get(sn, {sn}))


def search_terms(name: str) -> list[str]:
    terms: list[str] = []
    seen: set[str] = set()

    def add(raw: str) -> None:
        text = re.sub(r"[^\w]+", "_", raw.strip())
        text = re.sub(r"_+", "_", text).strip("_")
        key = text.lower()
        if text and key not in seen and len(text) >= 3:
            seen.add(key)
            terms.append(text)

    add(name)
    add(norm_npc(name))
    for key in npc_name_keys(name)[:4]:
        add(key)
    tokens = [t for t in re.split(r"[^\w]+", norm_npc(name)) if t]
    distinctive = [t for t in tokens if t not in WEAK_TOKENS and len(t) >= 5]
    if len(distinctive) == 1:
        add(distinctive[0])
    elif len(distinctive) >= 2:
        add("_".join(distinctive[:3]))
    return terms[:5]


def _core_name(value: str) -> str:
    text = norm_npc(value)
    text = re.sub(r"[^\w\s]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    for prefix in ("a ", "an ", "the "):
        if text.startswith(prefix):
            text = text[len(prefix) :]
            break
    return text


def name_matches(sheet_name: str, npc_name: str) -> bool:
    sheet_keys = set(npc_name_keys(sheet_name))
    npc_keys = set(npc_name_keys(npc_name))
    if sheet_keys & npc_keys:
        return True
    sheet_core = _core_name(sheet_name)
    npc_core = _core_name(npc_name)
    if not sheet_core or not npc_core:
        return False
    if sheet_core == npc_core:
        return True
    shorter, longer = sorted((sheet_core, npc_core), key=len)
    return len(shorter) >= 10 and longer.startswith(shorter + " ")


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def spawn_zones(npc: dict) -> set[str]:
    zones: set[str] = set()
    entries = npc.get("spawnentries") or npc.get("Spawnentries") or []
    for entry in _as_list(entries):
        group = entry.get("spawngroup") or entry.get("Spawngroup") or {}
        spawn2 = group.get("spawn_2") or group.get("Spawn2") or group.get("spawn2")
        for row in _as_list(spawn2):
            zone = (row.get("zone") or "").lower()
            if zone:
                zones.add(zone)
    return zones


def flags(cand: Candidate) -> str:
    bits = []
    if cand.unique_spawn:
        bits.append("unique")
    if cand.rare_spawn:
        bits.append("rare")
    if cand.raid_target:
        bits.append("raid")
    if cand.merchant_id:
        bits.append("merchant")
    if cand.untargetable:
        bits.append("untargetable")
    return ",".join(bits) or "-"


class SpireClient:
    def __init__(self, base: str, sleep_s: float, timeout: float):
        self.base = base.rstrip("/")
        self.sleep_s = sleep_s
        self.timeout = timeout
        self._last = 0.0

    def get(self, path: str, params: dict[str, str]) -> object:
        if self.sleep_s and self._last:
            wait = self.sleep_s - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
        url = f"{self.base}{path}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        last_err = None
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    body = resp.read()
                self._last = time.monotonic()
                return json.loads(body.decode("utf-8"))
            except urllib.error.HTTPError as exc:
                last_err = exc
                if exc.code in {429, 500, 502, 503, 504} and attempt < 3:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                last_err = exc
                if attempt < 3:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise
        raise RuntimeError(last_err)

    def npc_search(self, term: str, limit: int) -> list[dict]:
        payload = self.get(
            "/npc_types",
            {
                "where": f"name_like_{term}",
                "includes": "Spawnentries.Spawngroup.Spawn2",
                "limit": str(limit),
            },
        )
        if isinstance(payload, dict) and payload.get("error"):
            raise RuntimeError(payload["error"])
        if not isinstance(payload, list):
            return []
        return payload


def to_candidate(npc: dict) -> Candidate:
    return Candidate(
        npc_id=int(npc.get("id") or 0),
        name=str(npc.get("name") or ""),
        level=int(npc.get("level") or 0),
        loottable_id=int(npc.get("loottable_id") or 0),
        merchant_id=int(npc.get("merchant_id") or 0),
        unique_spawn=int(npc.get("unique_spawn_by_name") or 0),
        rare_spawn=int(npc.get("rare_spawn") or 0),
        raid_target=int(npc.get("raid_target") or 0),
        untargetable=int(npc.get("untargetable") or 0),
        zones=spawn_zones(npc),
    )


def rank_key(cand: Candidate, want_zones: set[str]) -> tuple:
    zone_hit = 0 if (want_zones and cand.zones & want_zones) else 1
    notable = 0 if (cand.unique_spawn or cand.rare_spawn or cand.raid_target) else 1
    playable = 0 if (not cand.merchant_id and not cand.untargetable) else 1
    return (zone_hit, playable, notable, cand.npc_id)


def lookup_row(client: SpireClient, row: SheetRow, want_zones: set[str], limit: int) -> list[Candidate]:
    found: dict[int, Candidate] = {}
    for term in search_terms(row.name):
        try:
            hits = client.npc_search(term, limit)
        except Exception as exc:
            print(f"  spire error ({term}): {exc}", file=sys.stderr, flush=True)
            continue
        for npc in hits:
            cand = to_candidate(npc)
            if not cand.npc_id or not name_matches(row.name, cand.name):
                continue
            prev = found.get(cand.npc_id)
            if prev is None or len(cand.zones) > len(prev.zones):
                found[cand.npc_id] = cand
        if found:
            break
    cands = sorted(found.values(), key=lambda c: rank_key(c, want_zones))
    return cands[:MAX_CANDIDATES]


def dump_name_hits(index, name: str) -> list:
    if index is None:
        return []
    by_id = {}
    for key in npc_name_keys(name):
        for npc in index.npcs_by_name.get(key, ()):
            by_id[npc.id] = npc
    return list(by_id.values())


def classify(
    cands: list[Candidate],
    want_zones: set[str],
    dump_npcs: list,
    index,
) -> str:
    if not cands:
        if dump_npcs:
            return "dump_only"
        return "no_hit"
    best = cands[0]
    dump_npc = index.npcs_by_id.get(best.npc_id) if index is not None else None
    zone_hit = bool(want_zones and best.zones & want_zones)
    if dump_npc is not None:
        dump_zone_hit = bool(want_zones and dump_npc.zones & want_zones) or not dump_npc.zones
        if dump_zone_hit:
            return "dump_same_id"
        return "dump_other_zone"
    if dump_npcs:
        if any((n.zones & want_zones) or not n.zones for n in dump_npcs):
            return "dump_name_missed"
        return "dump_other_zone"
    if zone_hit:
        return "spire_only"
    if best.zones:
        return "spire_other_zone"
    return "spire_no_spawn"


def fmt_zones(zones: set[str]) -> str:
    return ",".join(sorted(zones)) if zones else "-"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_IN)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--dump", type=Path, default=Path(os.environ.get("NMS_PEQ_DUMP", DEFAULT_DUMP)))
    parser.add_argument("--cache", type=Path, default=CACHE_PATH)
    parser.add_argument("--spire", default=DEFAULT_SPIRE)
    parser.add_argument("--sleep", type=float, default=0.15)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--limit", type=int, default=25, help="Spire rows per name query")
    parser.add_argument("--max-rows", type=int, default=0, help="Process only the first N sheet rows")
    parser.add_argument("--no-dump", action="store_true")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"missing unresolved list: {args.input}", file=sys.stderr)
        return 1

    rows = parse_unresolved(args.input)
    if args.max_rows:
        rows = rows[: args.max_rows]
    if not rows:
        print("no unresolved rows", file=sys.stderr)
        return 1

    index = None
    if not args.no_dump and args.dump.is_file():
        index = load_or_build_index(args.dump, args.cache)
    elif not args.no_dump:
        print(f"dump missing, Spire-only: {args.dump}", file=sys.stderr, flush=True)

    client = SpireClient(args.spire, args.sleep, args.timeout)
    counts: Counter[str] = Counter()
    lines = [
        "# Spire lookup vs local dump. Not seed input.",
        "# verdict: dump_same_id | dump_name_missed | dump_other_zone | dump_only | "
        "spire_only | spire_other_zone | spire_no_spawn | no_hit",
        "\t".join(
            [
                "sheet",
                "row",
                "name",
                "zone",
                "zone_sn",
                "bucket",
                "verdict",
                "spire_id",
                "spire_name",
                "lvl",
                "loottable_id",
                "spire_zones",
                "flags",
                "zone_match",
                "dump_id",
                "dump_zones",
                "dump_loottable",
                "dump_name_hits",
            ]
        ),
    ]

    print(f"rows={len(rows)} spire={args.spire}", flush=True)
    for i, row in enumerate(rows, 1):
        zone_sn = sheet_zone_sn(row.zone, index)
        want = zone_set(zone_sn)
        print(f"[{i}/{len(rows)}] {row.name} / {row.zone}", flush=True)
        cands = lookup_row(client, row, want, args.limit)
        dump_hits = dump_name_hits(index, row.name)
        verdict = classify(cands, want, dump_hits, index)
        counts[verdict] += 1
        if not cands:
            lines.append(
                "\t".join(
                    [
                        row.sheet,
                        row.row,
                        row.name,
                        row.zone,
                        zone_sn or "-",
                        row.bucket,
                        verdict,
                        "-",
                        "-",
                        "-",
                        "-",
                        "-",
                        "-",
                        "-",
                        "-",
                        fmt_zones({z for n in dump_hits for z in n.zones}),
                        "-",
                        str(len(dump_hits)),
                    ]
                )
            )
            continue
        for cand in cands:
            dump_npc = index.npcs_by_id.get(cand.npc_id) if index is not None else None
            zone_match = "yes" if (want and cand.zones & want) else "no"
            lines.append(
                "\t".join(
                    [
                        row.sheet,
                        row.row,
                        row.name,
                        row.zone,
                        zone_sn or "-",
                        row.bucket,
                        verdict,
                        str(cand.npc_id),
                        cand.name,
                        str(cand.level),
                        str(cand.loottable_id),
                        fmt_zones(cand.zones),
                        flags(cand),
                        zone_match,
                        str(dump_npc.id) if dump_npc else "-",
                        fmt_zones(dump_npc.zones) if dump_npc else "-",
                        str(dump_npc.loottable_id) if dump_npc else "-",
                        str(len(dump_hits)),
                    ]
                )
            )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"wrote {args.out}", flush=True)
    print("verdict counts:", flush=True)
    for key, count in counts.most_common():
        print(f"  {count:4} {key}", flush=True)
    print(
        "  "
        + f"{sum(counts.values()):4} rows  "
        + "(only dump_same_id / dump_name_missed are resolver misses; "
        + "spire_only is hosted-PEQ-newer-than-dump)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

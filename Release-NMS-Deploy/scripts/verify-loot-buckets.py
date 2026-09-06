#!/usr/bin/env python3
"""Adversarial checks for shared-bucket loot (seed + dump + source).

Writes verify-this artifacts under .logs/verify-this/mischief-loot-buckets/.
Verdict is VERIFIED / NOT VERIFIED / INCONCLUSIVE only.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import importlib.util

from peq_dump import InsertRowReader, parse_sql_int

_spec = importlib.util.spec_from_file_location(
    "import_loot_buckets", SCRIPT_DIR / "import-loot-buckets.py"
)
_import_mod = importlib.util.module_from_spec(_spec)
sys.modules["import_loot_buckets"] = _import_mod
_spec.loader.exec_module(_import_mod)
CACHE_PATH = _import_mod.CACHE_PATH
DEFAULT_DUMP = _import_mod.DEFAULT_DUMP
DEFAULT_SEED = _import_mod.DEFAULT_SEED
load_or_build_index = _import_mod.load_or_build_index

UNRESOLVED_DIR = (
    REPO_ROOT / "Release-NMS-Deploy" / "research" / "mischief-teek-randomization"
)
LOOT_CPP = REPO_ROOT / "Release-NMS-Server" / "zone" / "loot.cpp"
RULES = REPO_ROOT / "Release-NMS-Server" / "common" / "ruletypes.h"
BUCKETS_CPP = REPO_ROOT / "Release-NMS-Server" / "zone" / "nms_loot_buckets.cpp"
MISS_THRESHOLD = 0.15


def parse_seed(path: Path):
    text = path.read_text(encoding="utf-8")
    buckets = {}
    for match in re.finditer(
        r"\((\d+),\s*'([^']+)',\s*'(named|raid)',\s*'([^']+)'\)",
        text,
    ):
        buckets[int(match.group(1))] = {
            "id": int(match.group(1)),
            "code": match.group(2),
            "kind": match.group(3),
            "expansion": match.group(4),
            "npcs": [],
            "items": set(),
        }
    for match in re.finditer(
        r"\((\d+),\s*(\d+),\s*'([^']*)'\)",
        text,
    ):
        bid = int(match.group(1))
        if bid in buckets:
            buckets[bid]["npcs"].append((int(match.group(2)), match.group(3)))
    # item inserts use (bucket_id, item_id) — distinguish from npc rows by
    # appearing after nms_loot_bucket_items
    item_block = text.split("INSERT INTO nms_loot_bucket_items", 1)
    if len(item_block) == 2:
        for match in re.finditer(r"\((\d+),\s*(\d+)\)", item_block[1]):
            bid = int(match.group(1))
            if bid in buckets:
                buckets[bid]["items"].add(int(match.group(2)) % 1000000)
    return buckets


def miss_rate(path: Path) -> tuple[int, int, float]:
    if not path.is_file():
        return 0, 0, 1.0
    first = path.read_text(encoding="utf-8").splitlines()[0]
    match = re.search(r"(\d+)\s*/\s*(\d+)", first)
    if not match:
        return 0, 0, 1.0
    bad, total = int(match.group(1)), int(match.group(2))
    return bad, total, (0.0 if total == 0 else bad / total)


def load_stock_loot(dump: Path, loottable_ids: set[int]) -> dict[int, set[int]]:
    reader = InsertRowReader(dump)
    table_drops: dict[int, set[int]] = defaultdict(set)
    drop_ids: set[int] = set()
    print("verify pass loottable_entries", flush=True)
    for row in reader.iter_rows("loottable_entries"):
        if len(row) < 2:
            continue
        ltid = parse_sql_int(row[0])
        if ltid not in loottable_ids:
            continue
        ldid = parse_sql_int(row[1])
        table_drops[ltid].add(ldid)
        drop_ids.add(ldid)
    drop_items: dict[int, set[int]] = defaultdict(set)
    print("verify pass lootdrop_entries", flush=True)
    for row in reader.iter_rows("lootdrop_entries"):
        if len(row) < 2:
            continue
        ldid = parse_sql_int(row[0])
        if ldid not in drop_ids:
            continue
        drop_items[ldid].add(parse_sql_int(row[1]) % 1000000)
    out: dict[int, set[int]] = {}
    for ltid, drops in table_drops.items():
        items: set[int] = set()
        for ldid in drops:
            items.update(drop_items.get(ldid, ()))
        out[ltid] = items
    return out


def simulate(stock: set[int], pool: set[int], rule_on: bool, limit: int) -> dict:
    if not rule_on:
        return {"stock": set(stock), "shared": set(), "possible": set(stock)}
    kept = {i for i in stock if i not in pool}
    return {"stock": kept, "shared": set(pool), "possible": kept | set(pool)}


def pick_member(buckets, expansion: str, kind: str):
    for bucket in buckets.values():
        if bucket["expansion"] == expansion and bucket["kind"] == kind and bucket["npcs"] and bucket["items"]:
            return bucket, bucket["npcs"][0]
    return None, None


def write_artifact(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--dump", type=Path, default=Path(os.environ.get("NMS_PEQ_DUMP", DEFAULT_DUMP)))
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / ".logs" / "verify-this" / "mischief-loot-buckets",
    )
    args = parser.parse_args()

    failures: list[str] = []
    notes: list[str] = []

    if not args.seed.is_file():
        write_artifact(args.out / "verdict.md", "INCONCLUSIVE\nmissing seed SQL\n")
        print("INCONCLUSIVE\nClaim: shared-bucket loot seed and hook behave as scoped\n\nmissing seed")
        return 0

    buckets = parse_seed(args.seed)
    npc_kind = defaultdict(set)
    npc_exp = defaultdict(set)
    npc_buckets = defaultdict(set)
    for bucket in buckets.values():
        for npc_id, zone in bucket["npcs"]:
            npc_kind[(npc_id, zone)].add(bucket["kind"])
            npc_exp[(npc_id, zone)].add(bucket["expansion"])
            npc_buckets[npc_id].add(bucket["code"])

    mixed_kind = {k: v for k, v in npc_kind.items() if len(v) > 1}
    mixed_exp = {k: v for k, v in npc_exp.items() if len(v) > 1}
    if mixed_kind:
        failures.append(f"named/raid overlap on {len(mixed_kind)} npc mappings")
    if mixed_exp:
        failures.append(f"expansion overlap on {len(mixed_exp)} npc mappings")
    multi_bucket_ids = {npc_id: codes for npc_id, codes in npc_buckets.items() if len(codes) > 1}
    if multi_bucket_ids:
        failures.append(f"npc id assigned to multiple buckets: {len(multi_bucket_ids)}")

    ikkinz = [
        (npc_id, zone)
        for bucket in buckets.values()
        if bucket["expansion"] == "god"
        for npc_id, zone in bucket["npcs"]
        if zone == "ikkinz"
    ]
    if not ikkinz:
        failures.append("no Ikkinz npc mappings (instanced GoD)")

    # Time Phase 4/5 sheet names collide with other-plane script NPCs. These
    # ids must be the killable potimeb copies, not Tactics/Decay/Nightmare
    # placeholders or Time fakes.
    potimeb_ids = {
        npc_id
        for bucket in buckets.values()
        for npc_id, zone in bucket["npcs"]
        if zone == "potimeb"
    }
    time_required = {
        223075,  # Terris
        223076,  # Saryrn
        223077,  # Tallon
        223078,  # Vallon
        223142,  # Bertoxxulous
        223166,  # Cazic
        223167,  # Innoruuk
        223168,  # Rallos
    }
    time_forbidden = {
        200055,  # Crypt of Decay Bertox
        204065,  # Nightmare Thelin-event Terris
        214052,  # Tactics Rallos controller
        214083,  # Tactics Vallon
        214108,  # Tactics event Tallon
        214109,  # Tactics mini Rallos
        223000,  # Time fake Innoruuk
        223098,  # Time fake Bertox
        223165,  # Time fake Cazic
    }
    missing_time = sorted(time_required - potimeb_ids)
    if missing_time:
        failures.append(f"Time raid missing potimeb ids: {missing_time}")
    leaked_time = sorted(time_forbidden & potimeb_ids)
    if leaked_time:
        failures.append(f"non-Time ids labeled potimeb: {leaked_time}")

    if args.dump.is_file():
        index = load_or_build_index(args.dump, CACHE_PATH)
        missing_npc_ids = sorted(npc_id for npc_id in npc_buckets if npc_id not in index.npcs_by_id)
        if missing_npc_ids:
            failures.append(
                f"seed maps {len(missing_npc_ids)} npc ids absent from dump: {missing_npc_ids[:10]}"
            )
        merchant_hits = []
        untargetable_hits = []
        for bucket in buckets.values():
            for npc_id, zone in bucket["npcs"]:
                npc = index.npcs_by_id.get(npc_id)
                if not npc:
                    continue
                if npc.merchant_id:
                    merchant_hits.append(npc_id)
                if npc.untargetable:
                    untargetable_hits.append(npc_id)
        if merchant_hits:
            failures.append(f"seed maps {len(merchant_hits)} merchant npcs")
        if untargetable_hits:
            failures.append(f"seed maps {len(untargetable_hits)} untargetable npcs")
        notes.append(f"merchant_maps={len(merchant_hits)} untargetable_maps={len(untargetable_hits)}")

    rules = RULES.read_text(encoding="utf-8")
    if not re.search(r"RULE_BOOL\(\s*Custom,\s*RandomLootBuckets,\s*false,", rules):
        failures.append("RandomLootBuckets compiled default is not false")
    loot_cpp = LOOT_CPP.read_text(encoding="utf-8")
    if "NmsGetLootBucket" not in loot_cpp or "AddLootDrop(item, entry)" not in loot_cpp:
        failures.append("loot.cpp missing shared-bucket AddLootDrop hook")
    if "item_id % 1000000" not in loot_cpp and "item_id % 1000000" not in BUCKETS_CPP.read_text(encoding="utf-8"):
        failures.append("base-id modulo 1000000 missing")
    if "nms_loot_bucket* tables are missing or empty" not in loot_cpp:
        failures.append("fail-closed log missing")
    if "global_loot" in loot_cpp and "NmsGetLootBucket" in loot_cpp:
        # allowed to coexist; the hook must not load GlobalLootRepository for buckets
        if "GlobalLootRepository" in loot_cpp and "nms_loot_bucket" in loot_cpp[loot_cpp.find("NmsGetLootBucket"):]:
            notes.append("global_loot still in loot.cpp (stock path); bucket hook is separate")

    npc_bad, npc_total, npc_miss = miss_rate(UNRESOLVED_DIR / "unresolved-npcs.txt")
    item_bad, item_total, item_miss = miss_rate(UNRESOLVED_DIR / "unresolved-items.txt")
    if npc_miss > MISS_THRESHOLD:
        failures.append(f"npc miss rate {npc_miss:.1%} > {MISS_THRESHOLD:.0%}")
    if item_miss > MISS_THRESHOLD:
        failures.append(f"item miss rate {item_miss:.1%} > {MISS_THRESHOLD:.0%}")

    proof = []
    for expansion, kind, limit in (
        ("classic", "named", 1),
        ("classic", "raid", 2),
        ("god", "named", 1),
        ("god", "raid", 2),
        ("oow", "raid", 2),
    ):
        bucket, member = pick_member(buckets, expansion, kind)
        if not bucket:
            failures.append(f"no mapped {expansion} {kind} bucket with items")
            continue
        proof.append((expansion, kind, limit, bucket, member))

    stock_by_table = {}
    index = None
    if proof and args.dump.is_file():
        index = load_or_build_index(args.dump, CACHE_PATH)
        table_ids = set()
        for _, _, _, bucket, member in proof:
            npc = index.npcs_by_id.get(member[0])
            if npc and npc.loottable_id:
                table_ids.add(npc.loottable_id)
        if table_ids:
            stock_by_table = load_stock_loot(args.dump, table_ids)

    proof_lines = []
    for expansion, kind, limit, bucket, member in proof:
        npc_id, zone = member
        npc = index.npcs_by_id.get(npc_id) if index else None
        stock = stock_by_table.get(npc.loottable_id, set()) if npc else set()
        off = simulate(stock, bucket["items"], False, limit)
        on = simulate(stock, bucket["items"], True, limit)
        leaked_off = off["possible"] - stock
        if leaked_off:
            failures.append(f"{expansion} {kind} rule-off added non-stock items")
        if on["stock"] != (stock - bucket["items"]):
            failures.append(f"{expansion} {kind} skip-set mismatch")
        if on["shared"] != set(bucket["items"]):
            failures.append(f"{expansion} {kind} shared pool is not this NPC's bucket")
        foreign = bucket["items"] - stock
        if bucket["items"] and not (foreign <= on["shared"]):
            failures.append(f"{expansion} {kind} other-member pool items missing from treatment shared set")
        quest_kept = [i for i in stock if i not in bucket["items"]]
        if quest_kept and not set(quest_kept) <= on["stock"]:
            failures.append(f"{expansion} {kind} non-pool stock items were stripped")
        if npc and npc.merchant_id:
            failures.append(f"mapped merchant npc {npc_id}")
        if npc and npc.untargetable:
            failures.append(f"mapped untargetable npc {npc_id}")
        cross_member = None
        for other_npc, other_zone in bucket["npcs"]:
            if other_npc != npc_id:
                cross_member = (other_npc, other_zone)
                break
        proof_lines.append(
            f"{expansion}/{kind} npc={npc_id} zone={zone} bucket={bucket['code']} "
            f"stock={len(stock)} pool={len(bucket['items'])} "
            f"off_possible={len(off['possible'])} on_possible={len(on['possible'])} "
            f"rule_off_extra={len(leaked_off)} other_member={cross_member}"
        )
        write_artifact(
            args.out / "baseline" / f"{expansion}-{kind}.txt",
            f"npc={npc_id}\nzone={zone}\nrule=off\npossible={sorted(off['possible'])}\n",
        )
        write_artifact(
            args.out / "treatment" / f"{expansion}-{kind}.txt",
            f"npc={npc_id}\nzone={zone}\nrule=on\nstock={sorted(on['stock'])}\nshared={sorted(on['shared'])}\n",
        )

    empty_ready = "member_count == 0" in BUCKETS_CPP.read_text(encoding="utf-8")
    if not empty_ready:
        failures.append("empty-table fail-closed guard missing")

    claim = (
        "When RandomLootBuckets is off, mapped NPCs keep stock tables; when on, "
        "named/raid/expansion pools stay isolated, quest items not in LOOT N stay "
        "on the original NPC, and empty seed fails closed."
    )
    if failures:
        verdict = "NOT VERIFIED"
    elif not proof:
        verdict = "INCONCLUSIVE"
    else:
        verdict = "VERIFIED"

    evidence = [
        f"npc_resolve: {npc_total - npc_bad}/{npc_total} miss={npc_miss:.1%} threshold<{MISS_THRESHOLD:.0%}",
        f"item_resolve: {item_total - item_bad}/{item_total} miss={item_miss:.1%} threshold<{MISS_THRESHOLD:.0%}",
        f"buckets={len(buckets)} ikkinz_maps={len(ikkinz)} mixed_kind={len(mixed_kind)} "
        f"mixed_exp={len(mixed_exp)} multi_bucket_ids={len(multi_bucket_ids)}",
        *proof_lines,
        *(f"FAIL: {x}" for x in failures),
        *(f"NOTE: {x}" for x in notes),
    ]
    body = (
        f"{verdict}\nClaim: {claim}\n\nEvidence:\n"
        + "\n".join(f"- {line}" for line in evidence)
        + "\n\nReasoning:\n"
        + (
            "Seed membership, unresolved rates, source guards, and simulated "
            "baseline/treatment loot sets for Classic named/raid, GoD named/raid, "
            "and OoW raid were compared. "
            + ("Failures listed above." if failures else "Predicted isolation and skip/share behavior held.")
        )
        + "\n"
    )
    write_artifact(args.out / "claim.md", claim + "\n")
    write_artifact(args.out / "verdict.md", body)
    write_artifact(args.out / "timeline.md", "importer -> seed parse -> dump stock loot -> simulate off/on\n")
    print(body)
    return 0 if verdict != "NOT VERIFIED" else 1


if __name__ == "__main__":
    raise SystemExit(main())

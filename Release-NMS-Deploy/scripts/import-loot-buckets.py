#!/usr/bin/env python3
"""Build nms_loot_buckets seed SQL from Mischief/Teek CSVs + the PEQ dump.

Classic-PoP rows resolve by cleaned name + zone. GoD/OoW rows use NPC_ID / ITEM_IDS
when the extractor emitted them, and fall back to the same fuzzy resolver.

Does not write into a migration. Apply the seed after custom v27 creates empty tables.

  python Release-NMS-Deploy/scripts/import-loot-buckets.py
"""

from __future__ import annotations

import argparse
import csv
import gzip
import os
import pickle
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

from peq_dump import InsertRowReader, parse_sql_int, parse_sql_str  # noqa: E402

DEFAULT_CSV = REPO_ROOT / "Release-NMS-Deploy" / "research" / "mischief-teek-randomization" / "csv"
DEFAULT_DUMP = REPO_ROOT / "Release-NMS-Server" / "database" / "release-peq.zip"
DEFAULT_SEED = REPO_ROOT / "Release-NMS-Server" / "utils" / "sql" / "nms_loot_buckets_seed.sql"
DEFAULT_UNRESOLVED = (
    REPO_ROOT / "Release-NMS-Deploy" / "research" / "mischief-teek-randomization"
)
CACHE_PATH = DEFAULT_UNRESOLVED / ".cache" / "dump-index.pkl.gz"

SKIP_SHEETS = {"SHILL.csv", "Major-Tradeable-Items.csv"}

SHEETS = [
    ("CLASSIC.csv", "classic", "named"),
    ("CLASSIC-RAID-NPCS.csv", "classic", "raid"),
    ("Kunark-Named.csv", "kunark", "named"),
    ("Kunark-Raids.csv", "kunark", "raid"),
    ("Velious-Named.csv", "velious", "named"),
    ("Velious-Raids.csv", "velious", "raid"),
    ("Luclin-Raids.csv", "luclin", "raid"),
    ("PoP-Raids.csv", "pop", "raid"),
    ("MISCDATA.csv", "ooe", "named"),
    ("GoD-Named.csv", "god", "named"),
    ("GoD-Raids.csv", "god", "raid"),
    ("OoW-Named.csv", "oow", "named"),
    ("OoW-Raids.csv", "oow", "raid"),
]

IDENTITY_COLS = {
    "name",
    "named",
    "npc name",
    "npc",
    "npc_id",
    "lvl",
    "level",
    "zone",
    "zone_sn",
    "bucket",
    "motm",
    "notes",
    "item_ids",
}

# Sheet display names that do not survive long-name matching.
ZONE_ALIASES = {
    "solb(naggy lair)": "soldungb",
    "solb (nag lair)": "soldungb",
    "sola (solusek's eye)": "soldunga",
    "cazic-thule 1.0": "cazicthule",
    "the hole 1.0": "hole",
    "the hole": "hole",
    "butcherblock": "butcher",
    "gorge of xorbb": "beholder",
    "highpass hold": "highpasshold",
    "lake rathe": "lakerathe",
    "lower guk": "gukbottom",
    "upper guk": "guktop",
    "mistmoore": "mistmoore",
    "north karana": "northkarana",
    "south karana": "southkarana",
    "west karana": "qey2hh1",
    "north ro": "northro",
    "south ro": "southro",
    "splitpaw": "paw",
    "steamfont": "steamfont",
    "qeynos hills": "qeytoqrg",
    "warslicks woods": "warslikswood",
    "karnors": "karnor",
    "skyfire": "skyfire",
    "chardok: b (ooe)": "chardokb",
    "droga 2 (ooe)": "droga",
    "nurga (ooe)": "nurga",
    "growth": "growthplane",
    "plane of growth": "growthplane",
    "sleepers": "sleeper",
    "sleeper's tomb": "sleeper",
    "sleeper's tomb 2.0": "sleeper",
    "sleepers tomb 1.0": "sleeper",
    "vp 2.0 (ooe)": "veeshan",
    "veeshan's peak": "veeshan",
    "veeshan's peak (ooe)": "veeshan",
    "veksar (ooe)": "veksar",
    "acrylia 1.0": "acrylia",
    "acrylia caverns": "acrylia",
    "ssraeszha temple": "ssratemple",
    "ssraeshza temple": "ssratemple",
    "kurns tower": "kurn",
    "kurn's tower": "kurn",
    "time: phase 1": "potimeb",
    "time: phase 2": "potimeb",
    "time: phase 3": "potimeb",
    "time: phase 4": "potimeb",
    "time: phase 5": "potimeb",
    "time: phase 6": "potimeb",
    "plane of earth a": "poeartha",
    "plane of earth b": "poearthb",
    "plane of air": "poair",
    "plane of hate": "hateplane",
    "plane of fear": "fearplane",
    "plane of sky": "airplane",
    "tower of solro": "solrotower",
    "solusek ro's tower": "solrotower",
    "lair of terris thule": "nightmareb",
    "temple of marr": "pomarr",
    "crypt of decay": "codecay",
    "bastion of thunder": "bothunder",
    "halls of honor": "hohonora",
    "iceclad": "iceclad",
    "tower frozen shadow": "frozenshadow",
    "icewell keep": "thurgadina",
    "mischief 2.0 (ooe)": "mischiefplane",
    "skyshrine 2.0 (ooe)": "skyshrine",
    "dranik's hollows": "dranikhollowsa",
    "catacombs of dranik": "dranikcatacombsa",
    "kedge keep": "kedge",
    "ocean of tears": "oot",
    "toxxulia forest": "tox",
    "howling stones": "charasis",
    "city of mist": "citymist",
    "field of bone": "fieldofbone",
    "lake of ill omen": "lakeofillomen",
    "swamp of no hope": "swampofnohope",
    "trakanon's teeth": "trakanon",
    "the deep": "thedeep",
    "umbral plains": "umbral",
    "vex thal": "vexthal",
    "grieg's end": "griegsend",
    "echo caverns": "echo",
    "akheva ruins": "akheva",
    "sanctus seru": "sseru",
    "katta castellum": "katta",
    "eastern wastes": "eastwastes",
    "western wastes": "westwastes",
    "wakening lands": "wakening",
    "great divide": "greatdivide",
    "cobalt scar": "cobaltscar",
    "crystal caverns": "crystal",
    "dragon necropolis": "necropolis",
    "siren's grotto": "sirens",
    "velketor's labyrinth": "velketor",
    "icewell keep": "thurgadinb",
    "kael drakkel": "kael",
    "temple of veeshan": "templeveeshan",
    "plane of disease": "podisease",
    "plane of innovation": "poinnovation",
    "plane of justice": "pojustice",
    "plane of nightmare": "nightmare",
    "plane of storms": "postorms",
    "plane of tactics": "potactics",
    "plane of torment": "potorment",
    "plane of valor": "povalor",
    "plane of water": "powater",
    "plane of fire": "pofire",
    "dagnor's cauldron": "cauldron",
    "lesser faydark": "lfaydark",
    "qeynos aqueducts": "qcat",
    "everfrost": "everfrost",
    "lavastorm": "lavastorm",
    "najena": "najena",
    "unrest": "unrest",
    "crushbone": "crushbone",
    "befallen": "befallen",
    "misty thicket": "misty",
    "rathe mountains": "rathemtn",
    "kithicor": "kithicor",
    "burning woods": "burningwood",
    "dreadlands": "dreadlands",
    "emerald jungle": "emeraldjungle",
    "timorous deep": "timorous",
    "dalnir": "dalnir",
    "droga": "droga",
    "kaesora": "kaesora",
    "sebilis": "sebilis",
    "chardok": "chardok",
}

ZONE_EQUIV = {
    "sro": {"sro", "southro"},
    "southro": {"sro", "southro"},
    "nro": {"nro", "northro"},
    "northro": {"nro", "northro"},
    "steamfont": {"steamfont", "steamfontmts"},
    "steamfontmts": {"steamfont", "steamfontmts"},
    "highpass": {"highpass", "highpasshold", "highkeep"},
    "highpasshold": {"highpass", "highpasshold", "highkeep"},
    "highkeep": {"highpass", "highpasshold", "highkeep"},
}

JUNK_LOOT = {
    "no unique drops",
    "no unique drop",
    "class bps",
    "keys",
    "`",
    "x",
}

# Sheet item names that do not match items.Name after punctuation normalize.
ITEM_ALIASES = {
    "dragon bone braclet": "dragon bone bracelet",
    "blood fire": "bloodfire",
    "shield of rianbow hues": "shield of rainbow hues",
    "iksar skull with an 'x' (lore)": "iksar skull with an 'x'",
    "sepentskin eyepatch": "serpentskin eyepatch",
    "electrum braclet": "electrum bracelet",
    "ivory brraclet": "ivory bracelet",
    "obsidian scimatar": "obsidian scimitar",
}

NPC_ALIASES = {
    "undead crusader": "an undead crusader",
    "a kobold king": "solusek kobold king",
    "kobold king": "solusek kobold king",
    "war chieftan galronaar": "war chieftan galronar",
    "ston'ruak ancient of the trees": "ston'ruak ancient of trees",
    "severilious": "severilous",
    "trakanasaurus rex": "trakanasaur rex",
    "narmak barreka": "narmak berreka",
    "arch duke latol": "arch duke iatol",
    "silvering": "silverwing",
    "hreidar lynhilig": "hreidar lynhillig",
    "a monstrous mudwalker": "a monsterous mudwalker",
    "monstrous mudwalker": "monsterous mudwalker",
    "drakonine keeper": "drakonine lair keeper",
}

# Sheet zone -> dump zone for one NPC. Do not fold these into ZONE_EQUIV
# (southro↔oasis would also retarget Cazel / ancient cyclops).
NPC_ZONE_FALLBACK = {
    "lockjaw": {"southro": "oasis", "sro": "oasis"},
}

# Zone-scoped sheet name -> dump name. Global aliases would steal other-zone mobs.
NPC_ALIASES_BY_ZONE = {
    "permafrost": {
        "a goblin alchemist": "an ice goblin alchemist",
        "goblin alchemist": "ice goblin alchemist",
    },
}

# Script-spawned NPCs often have no spawn2 zone in PEQ, so ordinary name + zone
# ranking cannot disambiguate duplicate names. Keys are norm_text(sheet name).
# Time Phase 4/5 gods share names with Tactics / Decay / Nightmare / Hate / Fear
# placeholders; _pick_npc would take the lowest unzoned raid id. Quests spawn
# the killable Time copies below. 214052 is the Tactics controller (loot 0);
# 214109 is the attackable Tactics mini/fake Rallos.
NPC_IDS_BY_ZONE_AND_NAME = {
    "potimeb": {
        "bertoxxulous": 223142,
        "cazic thule": 223166,
        "innoruuk": 223167,
        "rallos zek": 223168,
        "saryrn": 223076,
        "tallon zek": 223077,
        "terris thule": 223075,
        "vallon zek": 223078,
    },
    "potactics": {
        "rallos zek (fake)": 214109,
    },
}


@dataclass
class NpcRec:
    id: int
    name: str
    clean: str
    loottable_id: int
    merchant_id: int
    unique_spawn: int
    rare_spawn: int
    raid_target: int
    untargetable: int
    zones: set[str] = field(default_factory=set)


@dataclass
class DumpIndex:
    items_by_name: dict[str, list[int]]
    item_names: dict[int, str]
    npcs_by_name: dict[str, list[NpcRec]]
    npcs_by_id: dict[int, NpcRec]
    zone_short: dict[str, str]
    zone_long: dict[str, str]


def norm_text(value: str) -> str:
    text = (value or "").replace("`", "'").replace("’", "'").replace("“", '"').replace("”", '"')
    text = text.replace("_", " ").replace("-", " ").strip()
    text = re.sub(r"\s+", " ", text)
    return text.lower()


def strip_article(text: str) -> str:
    for prefix in ("a ", "an ", "the "):
        if text.startswith(prefix):
            return text[len(prefix) :]
    return text


def norm_npc(value: str) -> str:
    text = norm_text(value)
    text = re.sub(r"[\[\(].*?[\]\)]", "", text)
    text = re.sub(r"[^\w\s']+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    while text.startswith("#"):
        text = text[1:].strip()
    text = re.sub(r"\d+$", "", text).strip()
    return NPC_ALIASES.get(text, text)


def npc_name_keys(value: str) -> list[str]:
    base = norm_npc(value)
    core = strip_article(base)
    keys = [base, core, "a " + core, "an " + core, "the " + core]
    if "," in (value or ""):
        left = norm_npc((value or "").split(",", 1)[0])
        if left and len(left) >= 6:
            keys.append(left)
            keys.append(strip_article(left))
    if "archaeologist" in core:
        keys.append(core.replace("archaeologist", "archeologist"))
    if "ssraeszha" in core:
        keys.append(core.replace("ssraeszha", "ssraeshza"))
    parts = core.split()
    if len(parts) >= 3 and parts[-1] in {"dat", "set"}:
        keys.append(" ".join(parts[:-1]))
    if core.endswith("men") and not core.endswith("women"):
        keys.append(core[:-3] + "man")
    if core.endswith("s") and len(core) > 4:
        keys.append(core[:-1])
    for key in list(keys):
        if "'" in key:
            keys.append(key.replace("'", ""))
    out = []
    seen: set[str] = set()
    for key in keys:
        if key and key not in seen:
            seen.add(key)
            out.append(key)
    return out


def npc_index_keys(clean: str) -> list[str]:
    keys = []
    seen: set[str] = set()
    for key in (clean, strip_article(clean)):
        for variant in (key, key.replace("'", "")):
            if variant and variant not in seen:
                seen.add(variant)
                keys.append(variant)
    return keys


def norm_zone(value: str) -> str:
    return norm_text(value).rstrip(".")


ZONE_ALIASES_NORM = {norm_zone(key): short for key, short in ZONE_ALIASES.items()}


def misc_bucket(level: float) -> str:
    if level < 40:
        return "M0"
    if level < 50:
        return "M1"
    if level < 60:
        return "M2"
    return "M3"


def parse_level(raw: str) -> float:
    text = (raw or "").strip().rstrip("?")
    if not text:
        return 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0


def sql_str(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def header_key(key: str | None) -> str:
    return re.sub(r"\s+", " ", (key or "").replace("\n", " ").strip().lower())


def row_map(row: dict[str, str]) -> dict[str, str]:
    return {header_key(k): (v or "").strip() for k, v in row.items() if k}


def col(row: dict[str, str], *names: str) -> str:
    for name in names:
        if name in row and row[name]:
            return row[name]
    return ""


def loot_fields(row: dict[str, str], expansion: str) -> list[str]:
    values = []
    for key, value in row.items():
        if not key or not value:
            continue
        if key in IDENTITY_COLS:
            continue
        if expansion == "ooe" and key == "tag":
            values.append(value)
            continue
        if key.startswith("loot") and key != "loot pool":
            cleaned = value.strip()
            if cleaned and norm_text(cleaned) not in JUNK_LOOT:
                values.append(cleaned)
    return values


def infer_bucket(level: float, expansion: str) -> str:
    if expansion == "ooe":
        return misc_bucket(level)
    band = max(1, int(level // 10)) if level else 1
    return f"{band}.0"


def load_or_build_index(dump: Path, cache: Path) -> DumpIndex:
    dump_stat = dump.stat()
    if cache.is_file():
        try:
            with gzip.open(cache, "rb") as fh:
                payload = pickle.load(fh)
            meta = payload.get("meta") or {}
            if (
                meta.get("dump") == str(dump)
                and meta.get("mtime") == dump_stat.st_mtime
                and meta.get("size") == dump_stat.st_size
                and meta.get("version") == 3
            ):
                print(f"dump index cache: {cache}", flush=True)
                npcs_by_name: dict[str, list[NpcRec]] = defaultdict(list)
                npcs_by_id: dict[int, NpcRec] = {}
                for raw in payload["npcs"]:
                    npc = NpcRec(
                        id=raw["id"],
                        name=raw["name"],
                        clean=raw["clean"],
                        loottable_id=raw["loottable_id"],
                        merchant_id=raw["merchant_id"],
                        unique_spawn=raw["unique_spawn"],
                        rare_spawn=raw["rare_spawn"],
                        raid_target=raw["raid_target"],
                        untargetable=raw["untargetable"],
                        zones=set(raw["zones"]),
                    )
                    npcs_by_id[npc.id] = npc
                    for key in npc_index_keys(npc.clean):
                        npcs_by_name[key].append(npc)
                return DumpIndex(
                    items_by_name=payload["items_by_name"],
                    item_names=payload["item_names"],
                    npcs_by_name=dict(npcs_by_name),
                    npcs_by_id=npcs_by_id,
                    zone_short=payload["zone_short"],
                    zone_long=payload["zone_long"],
                )
        except Exception as exc:
            print(f"cache ignored: {exc}", flush=True)

    print(f"indexing dump: {dump}", flush=True)
    reader = InsertRowReader(dump)

    print("pass zone", flush=True)
    zone_short: dict[str, str] = {}
    zone_long: dict[str, str] = {}
    for row in reader.iter_rows("zone"):
        if len(row) < 5:
            continue
        version = parse_sql_int(row[2])
        short = parse_sql_str(row[3]).lower()
        long_name = parse_sql_str(row[4])
        if not short:
            continue
        if short not in zone_short or version == 0:
            zone_short[short] = short
            nlong = norm_zone(long_name)
            if nlong:
                zone_long[nlong] = short
                if nlong.startswith("the "):
                    zone_long[nlong[4:]] = short
                if "," in nlong:
                    zone_long[nlong.split(",", 1)[0].strip()] = short

    print("pass spawn2", flush=True)
    group_zones: dict[int, set[str]] = defaultdict(set)
    for row in reader.iter_rows("spawn2"):
        if len(row) < 4:
            continue
        group_zones[parse_sql_int(row[1])].add(parse_sql_str(row[2]).lower())

    print("pass spawnentry", flush=True)
    npc_zones: dict[int, set[str]] = defaultdict(set)
    for row in reader.iter_rows("spawnentry"):
        if len(row) < 2:
            continue
        gid = parse_sql_int(row[0])
        npc_zones[parse_sql_int(row[1])].update(group_zones.get(gid, ()))

    print("pass npc_types", flush=True)
    npcs_by_name: dict[str, list[NpcRec]] = defaultdict(list)
    npcs_by_id: dict[int, NpcRec] = {}
    for row in reader.iter_rows("npc_types"):
        if len(row) < 19:
            continue
        npc = NpcRec(
            id=parse_sql_int(row[0]),
            name=parse_sql_str(row[1]),
            clean=norm_npc(parse_sql_str(row[1])),
            loottable_id=parse_sql_int(row[17]),
            merchant_id=parse_sql_int(row[18]),
            unique_spawn=parse_sql_int(row[90]) if len(row) > 90 else 0,
            rare_spawn=parse_sql_int(row[119]) if len(row) > 119 else 0,
            raid_target=parse_sql_int(row[97]) if len(row) > 97 else 0,
            untargetable=parse_sql_int(row[110]) if len(row) > 110 else 0,
            zones=npc_zones.get(parse_sql_int(row[0]), set()),
        )
        if not npc.clean:
            continue
        npcs_by_id[npc.id] = npc
        for key in npc_index_keys(npc.clean):
            npcs_by_name[key].append(npc)

    print("pass items", flush=True)
    items_by_name: dict[str, list[int]] = defaultdict(list)
    item_names: dict[int, str] = {}
    for row in reader.iter_rows("items"):
        if len(row) < 3:
            continue
        item_id = parse_sql_int(row[0])
        name = parse_sql_str(row[2])
        key = norm_text(name)
        if not key:
            continue
        items_by_name[key].append(item_id)
        item_names[item_id] = name

    index = DumpIndex(
        items_by_name=dict(items_by_name),
        item_names=item_names,
        npcs_by_name=dict(npcs_by_name),
        npcs_by_id=npcs_by_id,
        zone_short=zone_short,
        zone_long=zone_long,
    )
    cache.parent.mkdir(parents=True, exist_ok=True)
    npcs_payload = []
    for npc in index.npcs_by_id.values():
        npcs_payload.append(
            {
                "id": npc.id,
                "name": npc.name,
                "clean": npc.clean,
                "loottable_id": npc.loottable_id,
                "merchant_id": npc.merchant_id,
                "unique_spawn": npc.unique_spawn,
                "rare_spawn": npc.rare_spawn,
                "raid_target": npc.raid_target,
                "untargetable": npc.untargetable,
                "zones": sorted(npc.zones),
            }
        )
    with gzip.open(cache, "wb") as fh:
        pickle.dump(
            {
                "meta": {
                    "dump": str(dump),
                    "mtime": dump_stat.st_mtime,
                    "size": dump_stat.st_size,
                    "version": 3,
                },
                "items_by_name": index.items_by_name,
                "item_names": index.item_names,
                "npcs": npcs_payload,
                "zone_short": index.zone_short,
                "zone_long": index.zone_long,
            },
            fh,
        )
    print(
        f"indexed zones={len(zone_short)} npcs={len(npcs_by_id)} item_names={len(items_by_name)}",
        flush=True,
    )
    return index


def resolve_zone(label: str, index: DumpIndex) -> str | None:
    if not label:
        return None
    n = norm_zone(label)
    if n in index.zone_short:
        return n
    if n in index.zone_long:
        return index.zone_long[n]
    stripped = norm_zone(re.sub(r"[\[\(].*?[\]\)]", "", label))
    stripped = re.sub(r"\s+\d+(\.0)?$", "", stripped).strip()
    if stripped in index.zone_long:
        return index.zone_long[stripped]
    if n in ZONE_ALIASES_NORM:
        return ZONE_ALIASES_NORM[n]
    if stripped in ZONE_ALIASES_NORM:
        return ZONE_ALIASES_NORM[stripped]
    if n in ZONE_ALIASES:
        return ZONE_ALIASES[n]
    if stripped in ZONE_ALIASES:
        return ZONE_ALIASES[stripped]
    matches = {
        sn
        for long_n, sn in index.zone_long.items()
        if long_n.startswith(n) or (len(n) >= 12 and n.startswith(long_n))
    }
    if len(matches) == 1:
        return next(iter(matches))
    return None


def resolve_item(name: str, index: DumpIndex) -> int | None:
    key = ITEM_ALIASES.get(norm_text(name), norm_text(name))
    ids = index.items_by_name.get(key)
    if not ids:
        return None
    preferred = [i for i in ids if i < 1000000]
    pick = min(preferred or ids)
    return pick % 1000000


def _pick_npc(pool: list[NpcRec]) -> NpcRec:
    ranked = sorted(
        pool,
        key=lambda n: (0 if (n.unique_spawn or n.rare_spawn or n.raid_target) else 1, n.id),
    )
    return ranked[0]


def resolve_npc(name: str, zone_sn: str | None, index: DumpIndex) -> NpcRec | None:
    if zone_sn:
        exact_id = NPC_IDS_BY_ZONE_AND_NAME.get(zone_sn, {}).get(norm_text(name))
        if exact_id is not None:
            return index.npcs_by_id.get(exact_id)
        zmap = NPC_ALIASES_BY_ZONE.get(zone_sn, {})
        base = norm_npc(name)
        mapped = zmap.get(base) or zmap.get(strip_article(base))
        if mapped:
            name = mapped
    by_id: dict[int, NpcRec] = {}
    for key in npc_name_keys(name):
        for npc in index.npcs_by_name.get(key, ()):
            by_id[npc.id] = npc
    cands = list(by_id.values())
    if not cands:
        return None
    playable = [n for n in cands if not n.merchant_id and not n.untargetable]
    pool = playable or cands
    if zone_sn:
        zones = set(ZONE_EQUIV.get(zone_sn, {zone_sn}))
        in_zone = [n for n in pool if n.zones & zones]
        if in_zone:
            return _pick_npc(in_zone)
        fallback = NPC_ZONE_FALLBACK.get(strip_article(norm_npc(name)), {}).get(zone_sn)
        if fallback:
            fb_zones = set(ZONE_EQUIV.get(fallback, {fallback}))
            fb_hit = [n for n in pool if n.zones & fb_zones]
            if fb_hit:
                return _pick_npc(fb_hit)
        unzoned = [n for n in pool if not n.zones]
        if unzoned:
            return _pick_npc(unzoned)
    if len(pool) == 1:
        return pool[0]
    return None


def parse_item_ids(raw: str) -> list[int]:
    ids = []
    for part in (raw or "").replace(",", ";").split(";"):
        part = part.strip()
        if not part:
            continue
        try:
            ids.append(int(part) % 1000000)
        except ValueError:
            continue
    return ids


def write_reports(path: Path, title: str, rows: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "\n".join([title, *rows, ""])
    path.write_text(body, encoding="utf-8")


def emit_inserts(lines: list[str], table: str, columns: str, values: list[str]) -> None:
    if not values:
        return
    for i in range(0, len(values), 80):
        chunk = values[i : i + 80]
        lines.append(f"INSERT INTO {table} ({columns}) VALUES")
        lines.append(",\n".join(chunk) + ";")
        lines.append("")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv-dir", type=Path, default=Path(os.environ.get("NMS_LOOT_CSV", DEFAULT_CSV)))
    parser.add_argument("--dump", type=Path, default=Path(os.environ.get("NMS_PEQ_DUMP", DEFAULT_DUMP)))
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--unresolved-dir", type=Path, default=DEFAULT_UNRESOLVED)
    parser.add_argument("--cache", type=Path, default=CACHE_PATH)
    args = parser.parse_args()

    if not args.csv_dir.is_dir():
        print(f"missing csv dir: {args.csv_dir}", file=sys.stderr)
        return 1
    if not args.dump.is_file():
        print(f"missing dump: {args.dump}", file=sys.stderr)
        return 1

    index = load_or_build_index(args.dump, args.cache)
    known_item_bases = {item_id % 1000000 for item_id in index.item_names}

    buckets: dict[str, dict] = {}
    unresolved_npcs: list[str] = []
    unresolved_items: list[str] = []
    npc_rows = 0
    npc_ok = 0
    item_mentions = 0
    item_ok = 0

    for filename, expansion, kind in SHEETS:
        path = args.csv_dir / filename
        if not path.is_file():
            print(f"skip missing {filename}", flush=True)
            continue
        with path.open(encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            for row_no, raw_row in enumerate(reader, start=2):
                row = row_map(raw_row)
                name = col(row, "name", "named", "npc name", "npc")
                if not name:
                    continue
                npc_rows += 1
                level = parse_level(col(row, "lvl", "level"))
                sheet_zone = col(row, "zone")
                zone_sn = col(row, "zone_sn").lower() or resolve_zone(sheet_zone, index)
                bucket_code = col(row, "bucket", "loot pool", "pool")
                if filename == "MISCDATA.csv" or not bucket_code:
                    bucket_code = infer_bucket(level, expansion)
                if not bucket_code:
                    unresolved_npcs.append(
                        f"{filename}\t{row_no}\t{name}\t{sheet_zone}\t\tmissing bucket"
                    )
                    continue
                full_code = f"{expansion}:{kind}:{bucket_code}"
                bucket = buckets.setdefault(
                    full_code,
                    {"code": full_code, "kind": kind, "expansion": expansion, "npcs": set(), "items": set()},
                )

                npc_id_raw = col(row, "npc_id")
                npc = None
                if npc_id_raw.isdigit():
                    npc = index.npcs_by_id.get(int(npc_id_raw))
                if npc is None:
                    npc = resolve_npc(name, zone_sn, index)
                if npc is None:
                    unresolved_npcs.append(
                        f"{filename}\t{row_no}\t{name}\t{sheet_zone}\t{full_code}\tno npc match"
                    )
                else:
                    npc_ok += 1
                    stored_zone = zone_sn or (sorted(npc.zones)[0] if len(npc.zones) == 1 else "")
                    bucket["npcs"].add((npc.id, stored_zone))

                explicit_ids = parse_item_ids(col(row, "item_ids"))
                names = loot_fields(row, expansion)
                if explicit_ids:
                    for item_id in explicit_ids:
                        item_mentions += 1
                        if item_id in known_item_bases:
                            item_ok += 1
                            bucket["items"].add(item_id)
                        else:
                            unresolved_items.append(
                                f"{filename}\t{row_no}\titem:{item_id}\t{full_code}\tunknown id"
                            )
                    continue
                for item_name in names:
                    item_mentions += 1
                    item_id = resolve_item(item_name, index)
                    if item_id is None:
                        unresolved_items.append(
                            f"{filename}\t{row_no}\t{item_name}\t{full_code}\tno item match"
                        )
                        continue
                    item_ok += 1
                    bucket["items"].add(item_id)

    ordered = sorted(buckets.values(), key=lambda b: b["code"])
    lines = [
        "-- Shared-bucket loot seed. Generated by Release-NMS-Deploy/scripts/import-loot-buckets.py",
        "-- Apply AFTER custom migration v27 (empty nms_loot_buckets* tables). Not a migration.",
        "-- If Custom:RandomLootBuckets is on and these tables stay empty, zone fails closed to stock loot.",
        "",
        "DELETE FROM nms_loot_bucket_items;",
        "DELETE FROM nms_loot_bucket_npcs;",
        "DELETE FROM nms_loot_buckets;",
        "",
    ]
    bucket_values = []
    npc_values = []
    item_values = []
    for i, bucket in enumerate(ordered, start=1):
        bucket_values.append(
            f"({i}, {sql_str(bucket['code'])}, {sql_str(bucket['kind'])}, {sql_str(bucket['expansion'])})"
        )
        for npc_id, zone_sn in sorted(bucket["npcs"]):
            npc_values.append(f"({i}, {npc_id}, {sql_str(zone_sn)})")
        for item_id in sorted(bucket["items"]):
            item_values.append(f"({i}, {item_id})")

    emit_inserts(lines, "nms_loot_buckets", "id, code, kind, expansion", bucket_values)
    emit_inserts(lines, "nms_loot_bucket_npcs", "bucket_id, npc_id, zone_sn", npc_values)
    emit_inserts(lines, "nms_loot_bucket_items", "bucket_id, item_id", item_values)

    args.seed.parent.mkdir(parents=True, exist_ok=True)
    args.seed.write_text("\n".join(lines) + "\n", encoding="utf-8")

    npc_miss = 0 if npc_rows == 0 else (npc_rows - npc_ok) / npc_rows
    item_miss = 0 if item_mentions == 0 else (item_mentions - item_ok) / item_mentions
    summary = [
        f"# unresolved npcs: {npc_rows - npc_ok} / {npc_rows} ({npc_miss:.1%})",
        "sheet\trow\tname\tzone\tbucket\treason",
        *unresolved_npcs,
    ]
    write_reports(args.unresolved_dir / "unresolved-npcs.txt", summary[0], summary[1:])
    summary_i = [
        f"# unresolved items: {item_mentions - item_ok} / {item_mentions} ({item_miss:.1%})",
        "sheet\trow\titem\tbucket\treason",
        *unresolved_items,
    ]
    write_reports(args.unresolved_dir / "unresolved-items.txt", summary_i[0], summary_i[1:])

    print(
        f"seed {args.seed} buckets={len(ordered)} npc_maps={len(npc_values)} items={len(item_values)}",
        flush=True,
    )
    print(f"npc resolve {npc_ok}/{npc_rows} miss={npc_miss:.1%}", flush=True)
    print(f"item resolve {item_ok}/{item_mentions} miss={item_miss:.1%}", flush=True)
    print(f"unresolved npcs -> {args.unresolved_dir / 'unresolved-npcs.txt'}", flush=True)
    print(f"unresolved items -> {args.unresolved_dir / 'unresolved-items.txt'}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

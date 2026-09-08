"""Sizing census for the hero persistence spec: how many AA abilities a hero can own at once.

Reads the stock dump inside Release-NMS-Server/database/release-peq.zip (no extraction) and
mirrors the parts of Mob::CanUseAlternateAdvancementRank (zone/aa.cpp ~1950-2091) that the
data can express: aa_ability.enabled = 1, status = 0, category not 3/4 (shroud), and the class
mask under the dump's convention (bit 1 << (class_id - 1); the server shifts the mask left once
at load, aa.cpp ~2283). Race, deity, drakkin heritage and expansion (skipped live under
Custom:AAIgnoreExpansionGate) are not applied. Points are summed along first_rank_id / next_id.

Run from the repo root:  python Release-NMS-Deploy/research/aa_persistence_census.py
"""
import io
import re
import zipfile

ZIP = 'Release-NMS-Server/database/release-peq.zip'
TUP = re.compile(r"\((?:[^()']|'(?:[^'\\]|\\.)*')*\)")
CLASSES = {1: 'WAR', 2: 'CLR', 3: 'PAL', 4: 'RNG', 5: 'SHD', 6: 'DRU', 7: 'MNK', 8: 'BRD',
           9: 'ROG', 10: 'SHM', 11: 'NEC', 12: 'WIZ', 13: 'MAG', 14: 'ENC', 15: 'BST', 16: 'BER'}


def split_tuple(t):
    """Split one SQL VALUES tuple into cells, honouring quotes and backslash escapes."""
    out, buf, quoted, i = [], '', False, 1
    while i < len(t) - 1:
        c = t[i]
        if quoted:
            if c == '\\':
                buf += t[i + 1]
                i += 2
                continue
            if c == "'":
                quoted = False
            else:
                buf += c
        else:
            if c == "'":
                quoted = True
            elif c == ',':
                out.append(buf)
                buf = ''
            else:
                buf += c
        i += 1
    out.append(buf)
    return [x.strip() for x in out]


def load():
    """Return (aa_ability rows by id, aa_ranks rows by id) as dicts of column -> string."""
    cols, rows, cur, table_cols = {}, {'aa_ability': [], 'aa_ranks': []}, None, None
    with zipfile.ZipFile(ZIP) as z, z.open('release-peq.sql') as f:
        for line in io.TextIOWrapper(f, encoding='utf-8', errors='replace'):
            if line.startswith('CREATE TABLE `'):
                cur, table_cols = line.split('`')[1], []
                continue
            if table_cols is not None:
                s = line.strip()
                if s.startswith('`'):
                    table_cols.append(s.split('`')[1])
                    continue
                if s.startswith(')'):
                    cols[cur], table_cols = table_cols, None
                    continue
            if line.startswith('INSERT INTO `'):
                cur = line.split('`')[1]
            if cur not in rows or not line.lstrip().startswith(('(', 'INSERT')):
                continue
            body = line[line.index('VALUES') + 6:] if line.startswith('INSERT') else line
            for t in TUP.findall(body):
                rows[cur].append(split_tuple(t))
    ab = {r[cols['aa_ability'].index('id')]: dict(zip(cols['aa_ability'], r)) for r in rows['aa_ability']}
    rk = {r[cols['aa_ranks'].index('id')]: dict(zip(cols['aa_ranks'], r)) for r in rows['aa_ranks']}
    return ab, rk


def usable(ability, held_mask):
    """The data-expressible part of CanUseAlternateAdvancementRank."""
    if ability['enabled'] != '1' or ability['status'] != '0':
        return False
    if ability['category'] in ('3', '4'):
        return False
    return int(ability['classes']) & held_mask != 0


def chain(ranks, first_id, level_cap=None):
    """Follow first_rank_id -> next_id; return (rank count, total cost) up to level_cap."""
    n, cost, rid, seen = 0, 0, first_id, set()
    while rid and rid != '0' and rid in ranks and rid not in seen:
        seen.add(rid)
        r = ranks[rid]
        if level_cap is not None and int(r['level_req']) > level_cap:
            break
        n += 1
        cost += int(r['cost'])
        rid = r['next_id']
    return n, cost


def combo(ab, rk, names, level_cap):
    ids = [c for c, n in CLASSES.items() if n in names]
    mask = sum(1 << (c - 1) for c in ids)
    abilities = [a for a in ab.values() if usable(a, mask)]
    steps = points = 0
    owned = 0
    for a in abilities:
        n, c = chain(rk, a['first_rank_id'], level_cap)
        if n:
            owned += 1
            steps += n
            points += c
    return len(abilities), owned, steps, points


def main():
    ab, rk = load()
    print(f'abilities {len(ab)} ranks {len(rk)}')
    print('combo | abilities usable | ownable at level<=70 | rank steps | points to buy all')
    for names in [('MAG',), ('SHD', 'MNK', 'BER'), ('SHD', 'MNK', 'BER', 'WAR'), ('SHD', 'MNK', 'BER', 'BRD'),
                  ('CLR', 'SHD', 'MNK', 'BER'), ('WIZ', 'SHM', 'MAG', 'NEC'), ('CLR', 'SHD', 'SHM', 'MAG'),
                  tuple(CLASSES.values())]:
        u, o, s, p = combo(ab, rk, names, 70)
        label = '/'.join(names) if len(names) < 16 else 'every class'
        print(f'{label:<20} {u:>6} {o:>8} {s:>8} {p:>8}')
    # worst four by usable count
    per = {n: combo(ab, rk, (n,), 70)[1] for n in CLASSES.values()}
    top4 = sorted(per, key=lambda n: -per[n])[:4]
    u, o, s, p = combo(ab, rk, tuple(top4), 70)
    print(f'{"/".join(top4):<20} {u:>6} {o:>8} {s:>8} {p:>8}   (four largest single classes)')


if __name__ == '__main__':
    main()

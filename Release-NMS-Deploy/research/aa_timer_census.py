"""Census of timed AAs per class from the stock PEQ dump, to size the dynamic timer problem."""
import zipfile, io, re, sys
from collections import defaultdict

TUP = re.compile(r"\((?:[^()']|'(?:[^'\\]|\\.)*')*\)")
z = zipfile.ZipFile('Release-NMS-Server/database/release-peq.zip')
cols = {}
rows = {'aa_ability': [], 'aa_ranks': []}
cur = None
tc = None


def split_tuple(t):
    out, buf, q, i = [], '', False, 1
    while i < len(t) - 1:
        c = t[i]
        if q:
            if c == '\\':
                buf += t[i + 1]; i += 2; continue
            if c == "'":
                q = False
            else:
                buf += c
        else:
            if c == "'":
                q = True
            elif c == ',':
                out.append(buf); buf = ''
            else:
                buf += c
        i += 1
    out.append(buf)
    return [x.strip() for x in out]


with z.open('release-peq.sql') as f:
    for line in io.TextIOWrapper(f, encoding='utf-8', errors='replace'):
        if line.startswith('CREATE TABLE `'):
            cur = line.split('`')[1]; tc = []; continue
        if tc is not None:
            s = line.strip()
            if s.startswith('`'):
                tc.append(s.split('`')[1]); continue
            if s.startswith(')'):
                cols[cur] = tc; tc = None; continue
        if line.startswith('INSERT INTO `'):
            cur = line.split('`')[1]
        if cur not in rows or not line.lstrip().startswith(('(', 'INSERT')):
            continue
        body = line[line.index('VALUES') + 6:] if line.startswith('INSERT') else line
        for t in TUP.findall(body):
            rows[cur].append(split_tuple(t))

ab_cols = cols['aa_ability']; rk_cols = cols['aa_ranks']
print('aa_ability cols:', ab_cols)
print('aa_ranks cols:', rk_cols)
A = {r[ab_cols.index('id')]: dict(zip(ab_cols, r)) for r in rows['aa_ability']}
R = {r[rk_cols.index('id')]: dict(zip(rk_cols, r)) for r in rows['aa_ranks']}
print('abilities', len(A), 'ranks', len(R))

CLASSES = {1: 'WAR', 2: 'CLR', 3: 'PAL', 4: 'RNG', 5: 'SHD', 6: 'DRU', 7: 'MNK', 8: 'BRD', 9: 'ROG', 10: 'SHM', 11: 'NEC', 12: 'WIZ', 13: 'MAG', 14: 'ENC', 15: 'BST', 16: 'BER'}


def timed_abilities(status_filter=None):
    """abilities whose first rank has recast_time > 0, not grant_only, enabled, level <= 70"""
    out = []
    for aid, a in A.items():
        if a.get('enabled', '1') != '1':
            continue
        if a.get('grant_only', '0') == '1':
            continue
        fr = R.get(a['first_rank_id'])
        if not fr:
            continue
        if int(fr['recast_time']) <= 0:
            continue
        out.append((aid, a, fr))
    return out


timed = timed_abilities()
print('timed, enabled, non-grant abilities in stock:', len(timed))
max_st = max(int(fr['spell_type']) for _, _, fr in timed)
print('max stock spell_type among timed:', max_st, ' distinct:', len({int(fr['spell_type']) for _, _, fr in timed}))

per_class = {}
for cid, name in CLASSES.items():
    bit = 1 << (cid - 1)
    mine = [(aid, a, fr) for aid, a, fr in timed if int(a['classes']) & bit]
    lvl70 = [(aid, a, fr) for aid, a, fr in mine if int(fr['level_req']) <= 70]
    st = {int(fr['spell_type']) for _, _, fr in lvl70}
    per_class[cid] = lvl70
    print(f"{name}: timed AAs {len(mine):3d}  (level<=70: {len(lvl70):3d})  distinct spell_type: {len(st):3d}")

def combo(*names):
    ids = [c for c, n in CLASSES.items() if n in names]
    u = {}
    for c in ids:
        for aid, a, fr in per_class[c]:
            u[aid] = (a, fr)
    st = {(int(fr['spell_type'])) for a, fr in u.values()}
    # timers if keyed by (spell_type) only vs per (class-of-first-owner, spell_type)
    per_class_st = set()
    for c in ids:
        for aid, a, fr in per_class[c]:
            per_class_st.add((c, int(fr['spell_type'])))
    print(f"{'/'.join(names)}: union timed AAs (<=70) {len(u)}  distinct spell_type {len(st)}  (class,spell_type) pairs {len(per_class_st)}")

combo('SHD', 'MNK', 'BER')
combo('SHD', 'MNK', 'BER', 'BRD')
combo('CLR', 'SHD', 'MNK', 'BER')
combo('WAR', 'PAL', 'DRU', 'MNK')
combo('NEC', 'WIZ', 'MAG', 'ENC')
# classes bitmask distribution (which bit convention does the dump use?)
from collections import Counter
cnt = Counter(int(a['classes']) for a in A.values())
print('top classes masks:', cnt.most_common(6))
print('BER bit 1<<16 present in how many abilities:', sum(1 for a in A.values() if int(a['classes']) & (1 << 16)))

# what the server actually SENDS: every timed AA any held class can use, no level filter
def sent(*names):
    ids = [c for c, n in CLASSES.items() if n in names]
    mask = sum(1 << (c - 1) for c in ids)
    vis = [(aid, a, fr) for aid, a, fr in timed if int(a['classes']) & mask]
    st = {int(fr['spell_type']) for _, _, fr in vis}
    pairs = set()
    for aid, a, fr in vis:
        for c in ids:
            if int(a["classes"]) & (1 << (c - 1)):
                pairs.add((c, int(fr['spell_type'])))
    print(f"SENT {'/'.join(names)}: timed AAs visible {len(vis)}  distinct spell_type {len(st)}  (class,spell_type) pairs {len(pairs)}")

for combo_names in [('SHD', 'MNK', 'BER'), ('SHD', 'MNK', 'BER', 'BRD'), ('CLR', 'SHD', 'MNK', 'BER'), ('WAR', 'PAL', 'DRU', 'MNK'), ('NEC', 'WIZ', 'MAG', 'ENC'), ('WIZ', 'SHM', 'MAG', 'NEC')]:
    sent(*combo_names)

# worst case: the four classes with the most timed AAs
top4 = sorted(CLASSES.values(), key=lambda n: -len(per_class[[c for c, x in CLASSES.items() if x == n][0]]))[:4]
combo(*top4)

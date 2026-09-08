"""Every four-class combination through aa_persistence_census.combo(): the sizing ceiling.

Prints the smallest and largest "ownable at level 70" totals over all C(16,4) = 1820 four-class
combinations, how many fall outside the range the hero persistence spec first quoted, the ones
that exceed the client's 300-slot owned list, and the five-class maximum. Same filter as the
census script (see its docstring); takes a few minutes.

Run from the repo root:  python Release-NMS-Deploy/research/aa_persistence_combos.py
"""
import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aa_persistence_census as census  # noqa: E402


def main():
    ab, rk = census.load()
    names = list(census.CLASSES.values())
    rows = []
    for combo in itertools.combinations(names, 4):
        usable, owned, steps, points = census.combo(ab, rk, combo, 70)
        rows.append((owned, usable, steps, points, '/'.join(combo)))
    rows.sort()
    print(f'four-class combinations {len(rows)}')
    print('min ownable', rows[0])
    print('max ownable', rows[-1])
    print('below 249', sum(1 for r in rows if r[0] < 249))
    print('above 278', sum(1 for r in rows if r[0] > 278))
    over = [f'{r[4]}={r[0]}' for r in rows if r[0] > 300]
    print(f'above 300 {len(over)}', over)
    best5 = max((census.combo(ab, rk, combo, 70)[1], '/'.join(combo))
                for combo in itertools.combinations(names, 5))
    print('five-class max ownable', best5)


if __name__ == '__main__':
    main()

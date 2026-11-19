import csv, random, re, json, collections, sys
random.seed(20261119)
files = [l.strip().split('datasets/real/')[1] for l in open(sys.argv[1] + '/real_list.txt') if 'datasets/real/' in l]
by = collections.defaultdict(set)
for f in files:
    m = re.match(r'(.+?)_(farend_singletalk_with_movement|farend_singletalk|doubletalk_with_movement|doubletalk)_(lpb|mic)\.wav$', f)
    if m: by[m.group(1)].add((m.group(2), m.group(3)))
guids = sorted(by)
random.shuffle(guids)
want = ['farend_singletalk','doubletalk','doubletalk_with_movement',  # dev
        'farend_singletalk','farend_singletalk','doubletalk','doubletalk','farend_singletalk_with_movement']  # test
real, used = [], set()
for i, sc in enumerate(want):
    g = next(g for g in guids if g not in used and {(sc,'lpb'),(sc,'mic')} <= by[g])
    used.add(g)
    real.append({'id': f'real{i+1}', 'kind':'real', 'guid': g, 'scenario': sc, 'split': 'dev' if i < 3 else 'test'})
rows = [r for r in csv.DictReader(open(sys.argv[1] + '/data/meta.csv')) if r['split']=='test']
random.shuffle(rows)
syn = [{'id': f'syn{i+1}', 'kind':'synthetic', 'fileid': r['fileid'], 'ser': r['ser'], 'nonlinear': r['is_farend_nonlinear'],
        'farend_noisy': r['is_farend_noisy'], 'nearend_noisy': r['is_nearend_noisy'], 'split': 'dev' if i < 3 else 'test'} for i, r in enumerate(rows[:8])]
json.dump(real+syn, open(sys.argv[1] + '/clips.json', 'w'), indent=1)
for c in real+syn: print(c)

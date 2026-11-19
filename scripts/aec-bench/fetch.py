import json, subprocess, os, sys
D = sys.argv[1]
B = 'https://github.com/microsoft/AEC-Challenge/raw/main/datasets/'
os.makedirs(D + '/data/clips', exist_ok=True)
jobs = []
for c in json.load(open(D + '/clips.json')):
    i = c['id']
    if c['kind'] == 'real':
        for t in ('lpb', 'mic'):
            jobs.append((f"real/{c['guid']}_{c['scenario']}_{t}.wav", f"{i}_{t}.wav"))
    else:
        f = c['fileid']
        for d, p, t in [('farend_speech','farend_speech','lpb'), ('nearend_mic_signal','nearend_mic','mic'),
                        ('echo_signal','echo','echo'), ('nearend_speech','nearend_speech','near')]:
            jobs.append((f"synthetic/{d}/{p}_fileid_{f}.wav", f"{i}_{t}.wav"))
for src, dst in jobs:
    out = f'{D}/data/clips/{dst}'
    if not os.path.exists(out):
        subprocess.run(['curl', '-sSfL', '-o', out, B + src], check=True)
    print(dst, os.path.getsize(out))

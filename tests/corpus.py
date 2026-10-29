#!/usr/bin/env python3
"""Corpus regression check: translates every shader of a shader cache directory (NVN mode) with
`maxmetal service`, compares each output with the baseline's fingerprint and compiles it with the Metal compiler.

The directory holds <variant>.code (the program) and <variant>_b.json (a reflection: the stage, c1 and thread group
size, which the request repeats). Shaders are game data: they stay out of this repository; the baseline holds
only their names and hashes of the outputs.

Usage: corpus.py [--corpus DIR] [--maxmetal PATH] [--baseline FILE] [--update] [--no-metal] [-j N]
  --corpus DIR (or MAXMETAL_CORPUS=DIR): without one the check is skipped (exit 77, ctest's skip)
  --update: write the baseline from this run (review its diff: the shaders whose output changed)
Exit: 0 as the baseline, 1 an output changed, a shader that translated fails, or one that compiled does not.
"""
import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def requests(corpus):
    """(variant, stage, request) for every code file with a reflection"""
    out = []
    for code in sorted(glob.glob(os.path.join(corpus, '*.code'))):
        variant = os.path.basename(code)[:-5]
        try:
            with open(os.path.join(corpus, variant + '_b.json')) as f:
                refl = json.load(f)
        except (OSError, ValueError):
            continue
        stage = refl.get('stage')
        if stage not in ('vs', 'ps', 'cs'):
            continue
        rq = {'variant': variant, 'stage': stage, 'code': code, 'c1': refl.get('c1') or ''}
        if stage == 'cs':
            rq['local'] = refl.get('threadgroup_size')
        out.append((variant, stage, rq))
    return out


def digest(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]


def read_baseline(path):
    base = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) == 6 and not line.startswith('#'):
                    base[p[0]] = p[1:]
    return base


def compiles(metal, path):
    r = subprocess.run([metal, '-c', '-w', path, '-o', os.devnull], capture_output=True, text=True)
    return r.returncode == 0, r.stderr


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--corpus', default=os.environ.get('MAXMETAL_CORPUS'))
    ap.add_argument('--maxmetal', default=os.path.join(HERE, '..', 'build', 'maxmetal'))
    ap.add_argument('--baseline', default=os.path.join(HERE, 'corpus-baseline.txt'))
    ap.add_argument('--update', action='store_true')
    ap.add_argument('--no-metal', action='store_true')
    ap.add_argument('-j', type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    if not a.corpus:
        print('no corpus (--corpus DIR or MAXMETAL_CORPUS=DIR): skipped')
        return 77
    rqs = requests(a.corpus)
    if not rqs:
        print(f'no shaders in {a.corpus} (<variant>.code with <variant>_b.json)')
        return 77
    metal = None
    if not a.no_metal:
        r = subprocess.run(['xcrun', '-sdk', 'macosx', '-f', 'metal'], capture_output=True, text=True)
        metal = r.stdout.strip() if r.returncode == 0 else None
        if not metal:
            print('no Metal compiler (xcrun metal): outputs not compiled')

    with tempfile.TemporaryDirectory() as out:
        stdin = ''.join(json.dumps(rq) + '\n' for _, _, rq in rqs)
        r = subprocess.run([a.maxmetal, 'service', '--out', out, '--chain', 'corpus'], input=stdin,
                           capture_output=True, text=True, timeout=3600)
        replies = r.stdout.splitlines()
        if r.returncode != 0 or len(replies) != len(rqs):
            print(f'maxmetal service: exit {r.returncode}, {len(replies)} replies to {len(rqs)} requests\n{r.stderr}')
            return 1
        now, errors = {}, {}
        for (variant, stage, _), reply in zip(rqs, replies):
            rep = json.loads(reply)
            if rep.get('ok'):
                stem = os.path.join(out, variant + '_b')
                now[variant] = [stage, 'ok', digest(stem + '.metal'), digest(stem + '.json'), '-']
            else:
                now[variant] = [stage, 'fail', '-', '-', '-']
                errors[variant] = rep.get('error', '')
        if metal:
            todo = [v for v in now if now[v][1] == 'ok']
            with concurrent.futures.ThreadPoolExecutor(a.j) as pool:
                res = pool.map(lambda v: compiles(metal, os.path.join(out, v + '_b.metal')), todo)
                for v, (ok, err) in zip(todo, res):
                    now[v][4] = 'c' if ok else 'x'
                    if not ok:
                        errors[v] = err.strip().splitlines()[0] if err.strip() else 'metal: failed'

    if a.update:
        with open(a.baseline, 'w') as f:
            f.write('# variant stage translation metal-sha256 json-sha256 compiles (c yes, x no, - not checked)\n')
            for v in sorted(now):
                f.write(' '.join([v] + now[v]) + '\n')
        print(f'baseline written: {len(now)} shaders -> {a.baseline}')
        return 0

    base = read_baseline(a.baseline)
    same, changed, new, regress = 0, [], [], []
    for v, cur in sorted(now.items()):
        old = base.get(v)
        if not old:
            new.append(v)
            continue
        if cur[1] == 'fail' and old[1] == 'ok':
            regress.append(f'fails  {v} {cur[0]}: {errors.get(v, "")}')
        elif cur[4] == 'x' and old[4] == 'c':
            regress.append(f'metal  {v} {cur[0]}: {errors.get(v, "")}')
        diff = [k for k, i in (('metal', 2), ('json', 3)) if cur[i] != old[i]]
        if cur[1] == old[1] == 'ok' and diff:
            changed.append(f'changed {v} {cur[0]} ({", ".join(diff)})')
        elif not diff:
            same += 1
    missing = [v for v in base if v not in now]
    nfail = sum(1 for v in now.values() if v[1] == 'fail')
    nbad = sum(1 for v in now.values() if v[4] == 'x')
    print(f'{len(now)} shaders: {same} as the baseline, {len(changed)} changed, {len(new)} new, {len(missing)} not in the '
          f'corpus; {nfail} do not translate' + (f', {nbad} do not compile' if metal else ''))
    for line in (regress + changed)[:40]:
        print(line)
    if len(regress + changed) > 40:
        print(f'... {len(regress + changed) - 40} more')
    if changed or regress:
        print('an intended change: corpus.py --update, then review and commit the baseline')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

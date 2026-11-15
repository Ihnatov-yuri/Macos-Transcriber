import json, sys, glob, os, collections
root = sys.argv[1]
keys = collections.OrderedDict()
for f in sorted(glob.glob(root + '/**/*.stringsdata', recursive=True)):
    d = json.load(open(f))
    src = os.path.relpath(d.get('source',''), os.getcwd())
    for table, entries in d.get('tables', {}).items():
        for e in entries:
            k = e['key']
            keys.setdefault((table, k), {'table': table, 'key': k, 'comment': e.get('comment'), 'files': set()})['files'].add(src)
out = [dict(v, files=sorted(v['files'])) for v in keys.values()]
json.dump(out, open(sys.argv[2], 'w'), ensure_ascii=False, indent=1)
c = collections.Counter(v['table'] for v in out)
print(len(out), dict(c))

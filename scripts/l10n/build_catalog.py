"""Build Localizable.xcstrings from extracted keys and translation files.

usage: build_catalog.py keys.json out.xcstrings [tr1.json ...]

The translations already in out.xcstrings are kept; translation files add to
them or replace them. Keys no longer in the code are dropped.

A translation file maps a source key to {"uk": T, "nl": T, "en": T?}, where T is
a string, or for a key with exactly one integer argument a plural dict
({"one", "few", "many", "other"} for uk, {"one", "other"} for nl and en).
Every translation must use the same format specifiers as the key (positional
forms like %1$@ allowed). Problems are printed; a key with a bad translation is
left untranslated for that language.
"""
import json, re, sys, collections

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|\.?\d*f|%)")


def specs(s):
    return collections.Counter(m.group(2) for m in SPEC.finditer(s) if m.group(2) != "%")


def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}


def main():
    keys_path, out_path, *tr_paths = sys.argv[1:]
    keys = json.load(open(keys_path))
    tr = {}
    try:
        old = json.load(open(out_path))["strings"]
    except (OSError, ValueError, KeyError):
        old = {}
    for k, v in old.items():
        for lang, loc in v.get("localizations", {}).items():
            if "stringUnit" in loc:
                tr.setdefault(k, {})[lang] = loc["stringUnit"]["value"]
            elif "plural" in loc.get("variations", {}):
                tr.setdefault(k, {})[lang] = {f: u["stringUnit"]["value"] for f, u in loc["variations"]["plural"].items()}
    for p in tr_paths:
        for k, v in json.load(open(p)).items():
            tr.setdefault(k, {}).update(v)
    strings = {}
    problems = []
    missing = collections.Counter()
    for e in keys:
        if e["table"] != "Localizable":
            continue
        k = e["key"]
        entry = {}
        if e.get("comment"):
            entry["comment"] = e["comment"]
        locs = {}
        want = specs(k)
        ints = sum(n for t, n in want.items() if t in ("lld", "ld", "d"))
        t = tr.get(k, {})
        for lang in ("en", "uk", "nl"):
            v = t.get(lang)
            if v is None:
                if lang != "en":
                    missing[lang] += 1
                continue
            forms = v if isinstance(v, dict) else None
            values = list(forms.values()) if forms else [v]
            bad = [x for x in values if specs(x) != want and not (forms and specs(x) - want == collections.Counter() and ints == 1)]
            if bad:
                problems.append(f"{lang}: specifiers differ for {k!r}: {bad[0]!r}")
                continue
            if forms:
                if ints != 1:
                    problems.append(f"{lang}: plural forms for a key without exactly one integer: {k!r}")
                    continue
                need = {"uk": {"one", "few", "many", "other"}, "nl": {"one", "other"}, "en": {"one", "other"}}[lang]
                if not need <= set(forms):
                    problems.append(f"{lang}: plural forms {sorted(forms)} miss {sorted(need - set(forms))} for {k!r}")
                    continue
                locs[lang] = {"variations": {"plural": {f: unit(forms[f]) for f in sorted(forms)}}}
            else:
                if lang == "en" and v == k:
                    continue
                locs[lang] = unit(v)
        if locs:
            entry["localizations"] = locs
        strings[k] = entry
    json.dump({"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"},
              open(out_path, "w"), ensure_ascii=False, indent=2)
    print(f"{len(strings)} keys; untranslated: {dict(missing)}; problems: {len(problems)}")
    for p in problems[:60]:
        print("  " + p)


main()

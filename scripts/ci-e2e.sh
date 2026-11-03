#!/usr/bin/env bash
# Headless end-to-end checks of transcriberrcli on a macOS runner (or a Mac).
#
#   scripts/ci-e2e.sh <path/to/transcriberrcli>
#
# Synthesises speech with `say`, converts it with `afconvert`, and runs the
# CLI's subcommands on it: decoding, noise suppression, Parakeet, the
# diarizer, the voice print, offline echo cancellation, the full RUN
# pipeline (one track and a split-track meeting), finalize replay, the
# vocabulary pass, the benchmark, the knowledge base and the MCP server.
# Every check prints PASS, FAIL or SKIP with a reason; the script exits 1
# when any check FAILs.
#
# Environment:
#   E2E_OUT=<dir>         where logs, audio and results.tsv go (default: a new temp dir)
#   E2E_SKIP_MODELS=1     skip everything that downloads or runs a speech model
#   E2E_SKIP_WHISPER=1    skip Whisper (WhisperKit large-v3, ~3 GB) and Super
#   E2E_SKIP_UK=1         skip Parakeet UK (~630 MB from Hugging Face)
#   E2E_GEMMA=1           also download Gemma 4 E2B (~2.6 GB) and run litert/gentest/brief
#   E2E_SKIP_NETWORK=1    skip `uk-model status` (asks Hugging Face for its release list)
#   E2E_ALLOW_PREFS=1     allow writing nl.ihnatov.Transcriberr preferences (assistant
#                         access off/on); on by default when CI=true, restored afterwards
#   E2E_EXPECT_VERSION=x  the version the MCP server must report (MARKETING_VERSION)
#
# Nothing in the repository is touched. The store and backups the CLI sees
# are pointed at the temp dir (TRANSCRIBERR_STORE, TRANSCRIBERR_BACKUP_ROOT),
# so the user's library is never opened. Models land where the app keeps
# them (~/Library/Application Support/FluidAudio, …/Transcriberr/models,
# ~/Documents/huggingface), which is what the workflow caches.

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <path/to/transcriberrcli>" >&2
    exit 64
fi
CLI="$1"
if [ ! -x "$CLI" ]; then
    echo "not an executable: $CLI" >&2
    exit 64
fi
CLI="$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")"

OUT="${E2E_OUT:-}"
if [ -z "$OUT" ]; then
    OUT="$(mktemp -d "${TMPDIR:-/tmp}/transcriberr-e2e.XXXXXX")"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/work"
LOGS="$OUT/logs"
AUDIO="$OUT/audio"
RESULTS="$OUT/results.tsv"
mkdir -p "$WORK" "$LOGS" "$AUDIO"
: > "$RESULTS"

SKIP_MODELS="${E2E_SKIP_MODELS:-0}"
SKIP_WHISPER="${E2E_SKIP_WHISPER:-0}"
SKIP_UK="${E2E_SKIP_UK:-0}"
RUN_GEMMA="${E2E_GEMMA:-0}"
SKIP_NETWORK="${E2E_SKIP_NETWORK:-0}"
ALLOW_PREFS="${E2E_ALLOW_PREFS:-0}"
if [ "${CI:-}" = "true" ]; then ALLOW_PREFS="${E2E_ALLOW_PREFS:-1}"; fi
EXPECT_VERSION="${E2E_EXPECT_VERSION:-}"

# Never the user's library or backups.
export TRANSCRIBERR_STORE="$WORK/no-such-library.store"
export TRANSCRIBERR_BACKUP_ROOT="$WORK/backups"
unset TRANSCRIBERR_VOICEPRINT TRANSCRIBERR_DUMP_FINALIZE TRANSCRIBERR_CONTEXT 2>/dev/null || true

APP_DOMAIN="nl.ihnatov.Transcriberr"
PASS=0
FAIL=0
SKIP=0
RC=0
TIMED_OUT=0
STEP_SECS=0

record() {
    local status="$1" name="$2" reason="${3:-}"
    printf '%-4s  %-44s %s\n' "$status" "$name" "$reason"
    printf '%s\t%s\t%s\n' "$status" "$name" "$reason" >> "$RESULTS"
    case "$status" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        *) SKIP=$((SKIP + 1)) ;;
    esac
}

# Lines of "STATUS|name|reason" from the Python helper.
record_lines() {
    local line status name reason
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        status="${line%%|*}"
        line="${line#*|}"
        name="${line%%|*}"
        reason="${line#*|}"
        record "$status" "$name" "$reason"
    done
}

# run_step <log-name> <timeout-seconds> <command…>: stdout/stderr to
# $LOGS/<log-name>.out/.err; sets RC, TIMED_OUT (macOS has no `timeout`:
# the alarm survives exec and SIGALRM ends the command with status 142).
run_step() {
    local name="$1" secs="$2"
    shift 2
    local t0 t1
    t0="$(date +%s)"
    RC=0
    perl -e 'alarm shift; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@" \
        > "$LOGS/$name.out" 2> "$LOGS/$name.err" < /dev/null || RC=$?
    t1="$(date +%s)"
    STEP_SECS=$((t1 - t0))
    TIMED_OUT=0
    if [ "$RC" -eq 142 ]; then TIMED_OUT=1; fi
}

cli() {
    local name="$1" secs="$2"
    shift 2
    run_step "$name" "$secs" "$CLI" "$@"
}

rc_reason() {
    if [ "$TIMED_OUT" -eq 1 ]; then
        printf 'timed out after %ss' "$STEP_SECS"
    else
        printf 'exit %s after %ss, see logs/%s.{out,err}' "$RC" "$STEP_SECS" "$1"
    fi
}

out_has() { grep -qiE -- "$2" "$LOGS/$1.out" "$LOGS/$1.err" 2>/dev/null; }

# expect_rc <check-name> <log-name> <expected-rc> [<regex that must appear in the output>]
expect_rc() {
    local check="$1" log="$2" want="$3" pattern="${4:-}"
    if [ "$TIMED_OUT" -eq 0 ] && [ "$RC" -eq "$want" ]; then
        if [ -z "$pattern" ] || out_has "$log" "$pattern"; then
            record PASS "$check" "exit $RC in ${STEP_SECS}s"
        else
            record FAIL "$check" "exit $RC but output lacks /$pattern/ (logs/$log.*)"
        fi
    else
        record FAIL "$check" "expected exit $want: $(rc_reason "$log")"
    fi
}

models_skipped() { [ "$SKIP_MODELS" = "1" ]; }
whisper_skipped() { models_skipped || [ "$SKIP_WHISPER" = "1" ]; }

# ---------------------------------------------------------------- helper ---
HELPER="$WORK/e2e_helper.py"
cat > "$HELPER" <<'PY'
"""Helpers for scripts/ci-e2e.sh: audio assembly and output checks.
Pure standard library (the runner's python3 has no numpy)."""
import array, json, math, os, re, subprocess, sys, wave, uuid

def read_wav(path):
    with wave.open(path, "rb") as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise SystemExit("expected 16-bit PCM: %s" % path)
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder != "little":
        a.byteswap()
    if ch > 1:
        a = a[::ch]
    return [x / 32768.0 for x in a], sr

def write_wav(path, samples, sr=16000):
    a = array.array("h", (max(-32768, min(32767, int(round(x * 32767)))) for x in samples))
    if sys.byteorder != "little":
        a.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(a.tobytes())

def energy(x, a, b):
    a = max(0, a); b = min(len(x), b)
    return sum(v * v for v in x[a:b]) + 1e-12

FOLD = str.maketrans({"є": "е", "ї": "і", "ґ": "г", "’": "'", "ʼ": "'", "ё": "е"})

def words(text):
    return re.findall(r"[^\W_]+(?:'[^\W_]+)?", text.lower().translate(FOLD))

def hit_ratio(keywords, text):
    toks = words(text)
    kws = words(keywords)
    hits, missing = 0, []
    for k in kws:
        ok = k in toks or (len(k) >= 6 and any(t.startswith(k[:-2]) for t in toks))
        if ok:
            hits += 1
        else:
            missing.append(k)
    return (hits / len(kws) if kws else 0.0), missing

def cmd_voices():
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, timeout=60).stdout
    voices = []
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s+([a-z]{2,3}[_-][A-Za-z0-9]+)\s+#", line)
        if m:
            voices.append((m.group(1).strip(), m.group(2).replace("-", "_")))
    en = [n for n, l in voices if l.startswith("en_")]
    uk = [n for n, l in voices if l.startswith("uk_")]
    pick_a = ["Samantha", "Karen", "Moira", "Tessa", "Victoria", "Allison", "Ava"]
    pick_b = ["Daniel", "Fred", "Alex", "Ralph", "Tom", "Aaron", "Rishi"]
    a = next((n for n in pick_a if n in en), en[0] if en else "")
    b = next((n for n in pick_b if n in en and n != a), next((n for n in en if n != a), ""))
    print(json.dumps({"a": a, "b": b, "uk": (["Lesya"] if "Lesya" in uk else uk[:1] or [""])[0],
                      "count": len(voices)}))

def cmd_dialog(outdir, a1, b1, a2, b2):
    """A two-voice conversation, and the meeting it would be: the mix, the
    microphone (A plus the call coming back through the speakers) and the
    call track (B)."""
    sr = 16000
    gap = [0.0] * int(0.7 * sr)
    lead = [0.0] * int(0.3 * sr)
    mix, a_track, b_track, regions = list(lead), list(lead), list(lead), []
    for label, path in (("A", a1), ("B", b1), ("A", a2), ("B", b2)):
        x, r = read_wav(path)
        if r != sr:
            raise SystemExit("expected 16 kHz: %s" % path)
        start = len(mix)
        regions.append({"label": label, "start": start / sr, "end": (start + len(x)) / sr})
        mix += x + gap
        silence = [0.0] * len(x)
        a_track += (x if label == "A" else silence) + gap
        b_track += (x if label == "B" else silence) + gap
    delay, gain = int(0.15 * sr), 0.5
    echo = [0.0] * delay + [v * gain for v in b_track]
    mic = [a_track[i] + echo[i] for i in range(len(a_track))]
    write_wav(os.path.join(outdir, "dialog.wav"), mix)
    write_wav(os.path.join(outdir, "meeting.wav"), [0.7 * v for v in mix])
    write_wav(os.path.join(outdir, "meeting.mic.wav"), mic)
    write_wav(os.path.join(outdir, "meeting.sys.wav"), b_track)
    with open(os.path.join(outdir, "regions.json"), "w") as f:
        json.dump({"regions": regions, "echo_delay": delay / sr, "echo_gain": gain,
                   "duration": len(mix) / sr}, f, indent=1)

def cmd_concat(out, *paths):
    sr = 16000
    acc = []
    for p in paths:
        x, _ = read_wav(p)
        acc += x + [0.0] * int(0.5 * sr)
    write_wav(out, acc)

def cmd_hits(keywords, path):
    text = open(path, encoding="utf-8", errors="replace").read()
    ratio, missing = hit_ratio(keywords, text)
    print("%.2f %s" % (ratio, ",".join(missing[:12]) or "-"))

def cmd_between(path, out):
    """The text a command prints between its two ──── rulers."""
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    marks = [i for i, l in enumerate(lines) if l.strip() and set(l.strip()) == {"─"}]
    text = "\n".join(lines[marks[0] + 1:marks[1]]) if len(marks) >= 2 else ""
    open(out, "w", encoding="utf-8").write(text)
    print(len(text.split()))

def cmd_tjson(path, duration, keywords, name):
    """transcribe --json: stdout is exactly one JSON document with the
    documented keys and sane word timings."""
    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = [l for l in raw.splitlines() if l.strip()]
    if len(lines) != 1:
        print("FAIL|%s stdout-is-only-json|%d non-empty stdout lines, expected 1" % (name, len(lines)))
    else:
        print("PASS|%s stdout-is-only-json|1 line" % name)
    doc = None
    for l in reversed(lines):
        try:
            doc = json.loads(l); break
        except ValueError:
            continue
    if not isinstance(doc, dict):
        print("FAIL|%s json-schema|no JSON object on stdout" % name); return
    need = {"text": str, "confidence": (int, float), "duration_s": (int, float), "words": list}
    bad = [k for k, t in need.items() if not isinstance(doc.get(k), t)]
    if "language" not in doc:
        bad.append("language")
    ws = doc.get("words") or []
    for w in ws:
        if not (isinstance(w, dict) and isinstance(w.get("word"), str)
                and all(isinstance(w.get(k), (int, float)) for k in ("start", "end", "confidence"))):
            bad.append("word-shape"); break
    starts = [w.get("start", 0) for w in ws if isinstance(w, dict)]
    if starts != sorted(starts):
        bad.append("word-order")
    if any(isinstance(w, dict) and (w.get("end", 0) < w.get("start", 0) or w.get("end", 0) > float(duration) + 0.5) for w in ws):
        bad.append("word-times")
    if not ws:
        bad.append("no-words")
    if abs(float(doc.get("duration_s") or 0) - float(duration)) > 0.6:
        bad.append("duration_s=%s vs %s" % (doc.get("duration_s"), duration))
    if bad:
        print("FAIL|%s json-schema|%s" % (name, ", ".join(bad)))
    else:
        print("PASS|%s json-schema|%d timed words, confidence %.2f" % (name, len(ws), doc["confidence"]))
    ratio, missing = hit_ratio(keywords, doc.get("text", ""))
    status = "PASS" if ratio >= 0.6 else "FAIL"
    print("%s|%s keywords|hit ratio %.2f, missing %s" % (status, name, ratio, ",".join(missing) or "-"))

def cmd_rttm(path, regions_path, name):
    regions = json.load(open(regions_path))["regions"]
    rows = []
    for line in open(path):
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            rows.append((float(p[3]), float(p[3]) + float(p[4]), p[7]))
    labels = sorted({r[2] for r in rows})
    def at(t):
        hit = [r[2] for r in rows if r[0] <= t <= r[1]]
        if hit:
            return hit[0]
        near = sorted(rows, key=lambda r: min(abs(r[0] - t), abs(r[1] - t)))
        return near[0][2] if near else None
    mids = [(g["label"], at((g["start"] + g["end"]) / 2)) for g in regions]
    a = {lab for who, lab in mids if who == "A"}
    b = {lab for who, lab in mids if who == "B"}
    if len(labels) < 2:
        print("FAIL|%s two-speakers|%d speaker label(s) in the RTTM" % (name, len(labels)))
    else:
        print("PASS|%s two-speakers|%d speaker labels" % (name, len(labels)))
    if len(a) == 1 and len(b) == 1 and a != b:
        print("PASS|%s turns-attributed|voice A=%s, voice B=%s" % (name, a.pop(), b.pop()))
    else:
        print("FAIL|%s turns-attributed|turn midpoints read A=%s B=%s" % (name, sorted(map(str, a)), sorted(map(str, b))))

def cmd_aec(mic16, clean16, regions_path, name):
    mic, _ = read_wav(mic16)
    clean, _ = read_wav(clean16)
    meta = json.load(open(regions_path))
    sr = 16000
    if abs(len(clean) - len(mic)) > sr // 10:
        print("FAIL|%s length|cleaned %d samples vs mic %d" % (name, len(clean), len(mic)))
    else:
        print("PASS|%s length|cleaned track keeps the mic's length" % name)
    d = meta["echo_delay"]
    echo_in = echo_out = user_in = user_out = 0.0
    for g in meta["regions"]:
        a, b = int((g["start"] + d + 0.1) * sr), int((g["end"] + d) * sr)
        if g["label"] == "B":
            echo_in += energy(mic, a, b); echo_out += energy(clean, a, b)
        else:
            a, b = int((g["start"] + 0.05) * sr), int((g["end"] - 0.05) * sr)
            user_in += energy(mic, a, b); user_out += energy(clean, a, b)
    erle = 10 * math.log10(echo_in / echo_out)
    keep = 10 * math.log10(user_out / user_in)
    print("%s|%s echo-removed|echo-only stretches %.1f dB quieter (need >= 10)" % ("PASS" if erle >= 10 else "FAIL", name, erle))
    print("%s|%s user-kept|user's own speech %+.1f dB (need >= -6)" % ("PASS" if keep >= -6 else "FAIL", name, keep))

def cmd_runout(path, out_json):
    """`run` prints `start<TAB>name<TAB>text<TAB>key` lines after ### DONE."""
    done, segs = False, []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("### DONE"):
            done = True; continue
        if done:
            p = line.split("\t")
            if len(p) >= 3:
                segs.append({"start": p[0], "name": p[1], "text": p[2], "key": p[3] if len(p) > 3 else ""})
    by = {}
    for s in segs:
        k = s["key"] or s["name"]
        by.setdefault(k, []).append(s["text"])
    json.dump({"done": done, "segments": len(segs), "keys": sorted(by),
               "text": " ".join(s["text"] for s in segs),
               "by_key": {k: " ".join(v) for k, v in by.items()}}, open(out_json, "w"), ensure_ascii=False)

def cmd_runcheck(out_json, name, a_kw, b_kw, mode):
    r = json.load(open(out_json))
    if not r["done"]:
        print("FAIL|%s done|no ### DONE line" % name); return
    print("PASS|%s done|%d segments, speakers %s" % (name, r["segments"], ",".join(r["keys"]) or "-"))
    ratio, missing = hit_ratio(a_kw + " " + b_kw, r["text"])
    print("%s|%s keywords|hit ratio %.2f, missing %s" % ("PASS" if ratio >= 0.6 else "FAIL", name, ratio, ",".join(missing[:10]) or "-"))
    if mode == "diar":
        n = len([k for k in r["keys"] if k])
        print("%s|%s speakers|%d distinct speaker keys (need >= 2)" % ("PASS" if n >= 2 else "FAIL", name, n))
    elif mode == "split":
        me = r["by_key"].get("ME", "")
        others = " ".join(v for k, v in r["by_key"].items() if k != "ME")
        ra, _ = hit_ratio(a_kw, me)
        rb, _ = hit_ratio(b_kw, others)
        leak, leaked = hit_ratio(b_kw, me)
        print("%s|%s mic-is-me|A's words under ME: %.2f" % ("PASS" if ra >= 0.6 else "FAIL", name, ra))
        print("%s|%s call-is-others|B's words under the call's speakers: %.2f" % ("PASS" if rb >= 0.6 else "FAIL", name, rb))
        print("%s|%s no-echo-under-me|B's words under ME: %.2f (need <= 0.34) %s" % ("PASS" if leak <= 0.34 else "FAIL", name, leak, ",".join(w for w in words(b_kw) if w not in leaked)[:80]))

def cmd_csvmedian(path):
    vals = []
    for line in open(path):
        p = line.strip().split(",")
        if len(p) == 2 and p[1] and p[0] != "t":
            try:
                vals.append(float(p[1]))
            except ValueError:
                pass
    vals.sort()
    print("%.3f %d" % (vals[len(vals) // 2] if vals else float("nan"), len(vals)))

def cmd_langid(path):
    tops = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^\s*[\d.]+\s+(\S+)\s+\[", line)
        if m:
            tops.append(m.group(1))
    if not tops:
        print("none 0 0"); return
    best = max(set(tops), key=tops.count)
    print("%s %d %d" % (best, tops.count(best), len(tops)))

def cmd_bench_item(dirpath, clip, ref, machine, lang):
    item = {"id": str(uuid.uuid4()).upper(), "recordingId": str(uuid.uuid4()).upper(),
            "recordingTitle": "CI e2e", "language": lang, "speaker": None, "start": 0.0, "end": 6.0,
            "reference": ref, "machine": machine, "engine": "parakeet-v3", "track": "mix",
            "checkedAt": "2026-01-01T00:00:00Z", "clip": clip}
    with open(os.path.join(dirpath, item["id"] + ".json"), "w") as f:
        json.dump(item, f)

def cmd_dump(path):
    json.dump({"segments": [{"start": 0.0, "end": 2.5, "text": "Hello there, this is a replay test.", "speaker": None}],
               "diarize": False, "splitTracks": False, "expectedSpeakers": 0,
               "diarization": [], "timelines": {}}, open(path, "w"))

def cmd_mcp(cli, mode, expect_version, logpath):
    """Drive `transcriberrcli mcp` over stdio and check every reply."""
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ci", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "kb_stats", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "no_such_tool", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 5, "method": "bogus/method"},
        {"jsonrpc": "2.0", "id": 6, "method": "ping"},
        {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}},
        {"jsonrpc": "2.0", "id": 8, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
        {"jsonrpc": "2.0", "id": "s-9", "method": "tools/call", "params": {"name": "kb_search", "arguments": {"query": "budget"}}},
    ]
    body = "".join(json.dumps(r) + "\n" for r in reqs)
    body += "this is not json\n" + json.dumps([1, 2]) + "\n"
    body += json.dumps({"jsonrpc": "2.0", "id": 10, "method": "ping"})   # no trailing newline
    tag = "mcp" if mode == "on" else "mcp-access-off"
    try:
        p = subprocess.run([cli, "mcp"], input=body.encode(), capture_output=True, timeout=90)
    except subprocess.TimeoutExpired:
        print("FAIL|%s exits-at-eof|still running 90 s after stdin closed" % tag); return
    out = p.stdout.decode("utf-8", "replace")
    open(logpath, "w").write(out + "\n--- stderr ---\n" + p.stderr.decode("utf-8", "replace"))
    print("%s|%s exits-at-eof|exit %d" % ("PASS" if p.returncode == 0 else "FAIL", tag, p.returncode))
    replies, junk = [], []
    for line in out.splitlines():
        if not line.strip():
            continue
        try:
            replies.append(json.loads(line))
        except ValueError:
            junk.append(line[:60])
    print("%s|%s stdout-is-protocol-only|%s" % ("FAIL" if junk else "PASS", tag, ("non-JSON: %r" % junk[:2]) if junk else "%d JSON lines" % len(replies)))
    by_id = {}
    nulls = []
    for r in replies:
        if r.get("jsonrpc") != "2.0":
            print("FAIL|%s jsonrpc-2.0|reply without jsonrpc 2.0: %r" % (tag, r)); return
        if r.get("id") is None:
            nulls.append(r)
        else:
            by_id[r["id"]] = r
    def check(name, ok, why):
        print("%s|%s %s|%s" % ("PASS" if ok else "FAIL", tag, name, why))
    expected_ids = {1, 2, 3, 4, 5, 6, 7, 8, "s-9", 10}
    check("one-reply-per-request", set(by_id) == expected_ids and len(replies) == len(expected_ids) + 2,
          "ids %s, %d id-less errors (notification must get none)" % (sorted(map(str, by_id)), len(nulls)))
    init = by_id.get(1, {}).get("result", {})
    if mode == "on":
        check("initialize", init.get("protocolVersion") == "2025-06-18" and "tools" in init.get("capabilities", {})
              and init.get("serverInfo", {}).get("name") == "transcriberr", json.dumps(init)[:160])
        version = init.get("serverInfo", {}).get("version", "")
        if expect_version:
            check("server-version", version == expect_version, "serverInfo.version %r, MARKETING_VERSION %r" % (version, expect_version))
        else:
            check("server-version", bool(re.match(r"^\d+\.\d+(\.\d+)?$", version)), "serverInfo.version %r" % version)
        check("protocol-fallback", by_id.get(7, {}).get("result", {}).get("protocolVersion") == "2025-06-18",
              "unknown revision answered with %r" % by_id.get(7, {}).get("result", {}).get("protocolVersion"))
        check("protocol-older", by_id.get(8, {}).get("result", {}).get("protocolVersion") == "2024-11-05",
              "2024-11-05 answered with %r" % by_id.get(8, {}).get("result", {}).get("protocolVersion"))
        tools = by_id.get(2, {}).get("result", {}).get("tools", [])
        names = sorted(t.get("name", "") for t in tools)
        want = sorted(["kb_list", "kb_search", "kb_get_transcript", "kb_get_outputs", "kb_folders_tags", "kb_stats"])
        check("tools-list", names == want, "tools %s" % names)
        schemas_ok = all(t.get("inputSchema", {}).get("type") == "object" and t.get("description") for t in tools)
        req = {t["name"]: t.get("inputSchema", {}).get("required", []) for t in tools if "name" in t}
        check("tool-schemas", schemas_ok and req.get("kb_search") == ["query"] and req.get("kb_get_transcript") == ["id"]
              and req.get("kb_get_outputs") == ["id"], "required: %s" % json.dumps(req))
        res3 = by_id.get(3, {}).get("result", {})
        text3 = " ".join(c.get("text", "") for c in res3.get("content", []))
        check("missing-library-is-a-tool-error", res3.get("isError") is True and "No Transcriberr database" in text3,
              text3[:120] or json.dumps(by_id.get(3))[:120])
        res9 = by_id.get("s-9", {}).get("result", {})
        check("string-ids-echoed", res9.get("isError") is True, "id 's-9' answered: %s" % json.dumps(res9)[:100])
    else:
        tools = by_id.get(2, {}).get("result", {}).get("tools")
        check("no-tools-when-off", tools == [], "tools/list returned %r" % (tools if tools is None else len(tools)))
        res3 = by_id.get(3, {}).get("result", {})
        text3 = " ".join(c.get("text", "") for c in res3.get("content", []))
        check("calls-refused-when-off", res3.get("isError") is True and "switched off" in text3, text3[:120])
    check("unknown-tool", by_id.get(4, {}).get("error", {}).get("code") == -32602, json.dumps(by_id.get(4))[:120])
    check("unknown-method", by_id.get(5, {}).get("error", {}).get("code") == -32601, json.dumps(by_id.get(5))[:120])
    check("ping", by_id.get(6, {}).get("result") == {} and by_id.get(10, {}).get("result") == {},
          "ping replies %r / %r (the second had no trailing newline)" % (by_id.get(6), by_id.get(10)))
    codes = sorted(r.get("error", {}).get("code") for r in nulls)
    check("parse-and-invalid-request", codes == [-32700, -32600], "id-less error codes %s" % codes)

if __name__ == "__main__":
    fn = globals()["cmd_" + sys.argv[1].replace("-", "_")]
    fn(*sys.argv[2:])
PY
helper() { python3 -I "$HELPER" "$@"; }
helper_quiet() { helper "$@" 2>> "$LOGS/helper.err" || true; }
# The text between a command's ──── rulers, into a file (empty on failure).
helper_between() { helper between "$1" "$2" > /dev/null 2>> "$LOGS/helper.err" || : > "$2"; }
# langid_check <check> <expected-code> <log>: the majority of Whisper's
# per-window language guesses must be the expected language.
langid_check() {
    local check="$1" want="$2" log="$3" res top n total
    res="$(helper langid "$log" 2>> "$LOGS/helper.err" || echo "none 0 0")"
    read -r top n total <<< "$res" || true
    if [ "${top:-}" = "$want" ] && [ "${total:-0}" -gt 0 ]; then
        record PASS "$check" "majority '$top' in $n of $total windows"
    else
        record FAIL "$check" "majority '${top:-?}' in ${n:-0} of ${total:-0} windows, expected '$want'"
    fi
}
# keyword_check <check> <keywords> <text-file> [<extra reason>]: PASS when at
# least 60% of the known sentence's content words were recognized.
keyword_check() {
    local check="$1" kw="$2" file="$3" extra="${4:-}" res ratio missing
    res="$(helper hits "$kw" "$file" 2>> "$LOGS/helper.err" || true)"
    ratio="${res%% *}"
    missing="${res#* }"
    if [ -n "$res" ] && python3 -I -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) >= 0.6 else 1)' "$ratio" 2> /dev/null; then
        record PASS "$check" "hit ratio $ratio, missing $missing${extra:+; $extra}"
    else
        record FAIL "$check" "hit ratio ${ratio:-?} (need >= 0.6), missing ${missing:-?}${extra:+; $extra}"
    fi
}

echo "transcriberrcli e2e: $CLI"
echo "output: $OUT"
sw_vers 2>/dev/null || true
echo "skip models=$SKIP_MODELS whisper=$SKIP_WHISPER uk=$SKIP_UK gemma=$RUN_GEMMA network=$SKIP_NETWORK prefs=$ALLOW_PREFS"
echo

# ------------------------------------------------------- speech fixtures ---
A1="The quick brown fox jumps over the lazy dog near the river."
B1="Thank you everyone for joining today, we will discuss the marketing campaign."
A2="Please schedule the quarterly budget review for next Tuesday afternoon."
B2="Great, I will send the summary and the slides after this call."
A_KW="quick brown fox jumps lazy dog river schedule quarterly budget review tuesday afternoon"
B_KW="thank everyone joining today discuss marketing campaign great send summary slides call"
ENROLL="When the sun rises over the hills, the village slowly wakes up. Farmers walk to their fields, children run to school, and the baker opens his shop on the corner. By noon the market square is full of people buying bread, fruit and fresh vegetables. In the evening everyone gathers by the fountain to talk about the day, and the old clock on the church tower strikes nine."
UK1="Добрий день. Сьогодні ми обговоримо новий проект і бюджет на наступний рік."
UK_KW="добрий день сьогодні обговоримо новий проект бюджет наступний рік"

VOICE_A=""
VOICE_B=""
VOICE_UK=""
HAVE_SPEECH=0
HAVE_DIALOG=0
HAVE_UK=0

synth() { # <voice> <name> <text>: AIFF from `say`, then 16 kHz mono WAV
    local voice="$1" name="$2" text="$3"
    run_step "say-$name" 120 say -v "$voice" -o "$AUDIO/$name.aiff" "$text"
    [ "$RC" -eq 0 ] || return 1
    run_step "afconvert-$name" 60 afconvert -f WAVE -d LEI16@16000 -c 1 "$AUDIO/$name.aiff" "$AUDIO/$name.wav"
    [ "$RC" -eq 0 ]
}

if ! command -v say > /dev/null || ! command -v afconvert > /dev/null; then
    record FAIL "fixtures say+afconvert" "say or afconvert not found"
else
    VOICES_JSON="$(helper voices 2> "$LOGS/voices.err" || true)"
    VOICE_A="$(printf '%s' "$VOICES_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["a"])' 2>/dev/null || true)"
    VOICE_B="$(printf '%s' "$VOICES_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["b"])' 2>/dev/null || true)"
    VOICE_UK="$(printf '%s' "$VOICES_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["uk"])' 2>/dev/null || true)"
    if [ -z "$VOICE_A" ]; then
        record FAIL "fixtures english-voice" "no en_* voice in \`say -v '?'\`"
    elif synth "$VOICE_A" a1 "$A1" && synth "$VOICE_A" a2 "$A2" && synth "$VOICE_A" enroll "$ENROLL"; then
        HAVE_SPEECH=1
        record PASS "fixtures english-voice" "voice A: $VOICE_A"
        afconvert -f m4af -d aac "$AUDIO/a1.aiff" "$AUDIO/a1.m4a" > "$LOGS/afconvert-m4a.out" 2>&1 || true
        afconvert -f flac -d flac "$AUDIO/a1.aiff" "$AUDIO/a1.flac" > "$LOGS/afconvert-flac.out" 2>&1 || true
        afconvert -f WAVE -d LEI16@44100 "$AUDIO/a1.aiff" "$AUDIO/a1-44k.wav" > "$LOGS/afconvert-44k.out" 2>&1 || true
        if [ -n "$VOICE_B" ] && synth "$VOICE_B" b1 "$B1" && synth "$VOICE_B" b2 "$B2"; then
            if helper dialog "$AUDIO" "$AUDIO/a1.wav" "$AUDIO/b1.wav" "$AUDIO/a2.wav" "$AUDIO/b2.wav" 2> "$LOGS/dialog.err"; then
                HAVE_DIALOG=1
                helper concat "$AUDIO/a-test.wav" "$AUDIO/a1.wav" "$AUDIO/a2.wav" || true
                helper concat "$AUDIO/b-test.wav" "$AUDIO/b1.wav" "$AUDIO/b2.wav" || true
                record PASS "fixtures two-voice-dialog" "voice B: $VOICE_B; meeting.wav + .mic.wav + .sys.wav"
            else
                record FAIL "fixtures two-voice-dialog" "assembling the dialog failed (logs/dialog.err)"
            fi
        else
            record SKIP "fixtures two-voice-dialog" "no second English voice"
        fi
    else
        record FAIL "fixtures english-voice" "say/afconvert failed with voice '$VOICE_A' (logs/say-*.err)"
    fi
    if [ -n "$VOICE_UK" ] && synth "$VOICE_UK" uk1 "$UK1"; then
        HAVE_UK=1
        record PASS "fixtures ukrainian-voice" "voice: $VOICE_UK"
    else
        record SKIP "fixtures ukrainian-voice" "no uk_* voice installed (e.g. Lesya)"
    fi
fi

# A file that is not audio.
printf 'this is not audio\n' > "$WORK/not-audio.wav"

# -------------------------------------------------------- dispatch, help ---
cli help 30 help
if [ "$RC" -eq 0 ]; then
    missing=""
    for c in record decode noisesup transcribe diarize context bench vocab kb mcp restore-backups migrate-audio migrate-echo voice uk-model virtualmic; do
        grep -qE "transcriberrcli $c" "$LOGS/help.out" || missing="$missing $c"
    done
    if [ -z "$missing" ]; then record PASS "help lists-commands" "all 16 documented commands listed"
    else record FAIL "help lists-commands" "missing:$missing"; fi
else
    record FAIL "help lists-commands" "$(rc_reason help)"
fi
cli unknown 30 no-such-command
expect_rc "dispatch unknown-command" unknown 64
cli decode-noarg 30 decode
expect_rc "dispatch missing-argument" decode-noarg 64

# ------------------------------------------------------- decode/noisesup ---
afinfo_secs() { afinfo "$1" 2>/dev/null | awk '/estimated duration/ {print $3; exit}'; }
if [ "$HAVE_SPEECH" -eq 1 ]; then
    for f in a1.aiff a1.wav a1.m4a a1.flac a1-44k.wav; do
        if [ ! -f "$AUDIO/$f" ]; then record SKIP "decode $f" "afconvert could not make it"; continue; fi
        cli "decode-$f" 120 decode "$AUDIO/$f"
        if [ "$RC" -ne 0 ]; then record FAIL "decode $f" "$(rc_reason "decode-$f")"; continue; fi
        line="$(grep -E '\[decode\].*samples' "$LOGS/decode-$f.out" | head -1 || true)"
        samples="$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) samples, ([0-9.]+)s, ([0-9]+) chunks.*/\1/p')"
        chunks="$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) samples, ([0-9.]+)s, ([0-9]+) chunks.*/\3/p')"
        src="$(afinfo_secs "$AUDIO/$f")"
        verdict="$(python3 -I -c 'import sys
s, src, ch = sys.argv[1], sys.argv[2], sys.argv[3]
if not s or not src: print("FAIL no sample count in output"); raise SystemExit
d = int(s) / 16000.0
ok = abs(d - float(src)) <= 0.1 + 0.02 * float(src) and int(ch or 0) >= 1
print(("PASS" if ok else "FAIL") + " %.2fs at 16 kHz vs %.2fs source, %s chunk(s)" % (d, float(src), ch))' "$samples" "$src" "${chunks:-0}")"
        record "${verdict%% *}" "decode $f" "${verdict#* }"
    done
    cli decode-bad 60 decode "$WORK/not-audio.wav"
    expect_rc "decode not-audio-fails-cleanly" decode-bad 1 "decode"
    target="$AUDIO/a1.wav"
    if [ "$HAVE_DIALOG" -eq 1 ]; then target="$AUDIO/dialog.wav"; fi
    cli noisesup 120 noisesup "$target"
    if [ "$RC" -eq 0 ]; then
        io="$(sed -nE 's/.*in=([0-9]+) out=([0-9]+).*/\1 \2/p' "$LOGS/noisesup.out" | head -1)"
        if [ -n "$io" ] && [ "${io#* }" -gt 0 ]; then record PASS "noisesup runs" "samples in/out: $io"
        else record FAIL "noisesup runs" "no in=/out= line"; fi
    else
        record FAIL "noisesup runs" "$(rc_reason noisesup)"
    fi
else
    record SKIP "decode formats" "no synthetic speech"
    record SKIP "noisesup runs" "no synthetic speech"
fi

# ----------------------------------------------------------------- vocab ---
printf 'we use Web RTC daily\nI worked at Kim Kim for years.\nnothing to change here\n' > "$WORK/vocab.txt"
# The vocabulary comes in through the argument domain, so no preferences
# file is written for it (the CLI reads the app's domain, then its own).
cli vocab 60 vocab "$WORK/vocab.txt" English -prompt.vocabulary "WebRTC, KimKim"
if [ "$RC" -eq 0 ] && grep -qF '+ we use WebRTC daily' "$LOGS/vocab.out" \
    && grep -qF '+ I worked at KimKim for years.' "$LOGS/vocab.out" \
    && grep -qF '### 2 lines changed, 2 terms' "$LOGS/vocab.out"; then
    record PASS "vocab spelling-pass" "joined split terms, left the rest"
else
    record FAIL "vocab spelling-pass" "$(rc_reason vocab); expected WebRTC/KimKim joins and '### 2 lines changed, 2 terms'"
fi

# --------------------------------------------------------------- context ---
cli context-bad 30 context "not a date"
expect_rc "context unreadable-date" context-bad 64 "cannot read a date"
cli context-short 30 context "2026-01-05 10:00" 0.5
expect_rc "context too-short-window" context-short 1 "no invite covers"
cli context-lookup 45 context "2026-01-05 10:00" 30
if [ "$TIMED_OUT" -eq 1 ]; then
    record SKIP "context calendar-lookup" "the calendar permission prompt cannot be answered headlessly (timed out)"
elif [ "$RC" -eq 1 ] && out_has context-lookup "no invite covers"; then
    record PASS "context calendar-lookup" "no access or no invite: reported, exit 1"
elif [ "$RC" -eq 0 ]; then
    record PASS "context calendar-lookup" "an invite was found and printed"
else
    record FAIL "context calendar-lookup" "$(rc_reason context-lookup)"
fi

# ------------------------------------------------- hardware-bound, fail fast ---
cli record 45 record 1
if [ "$TIMED_OUT" -eq 1 ]; then
    record FAIL "record fails-fast-without-mic-permission" "hung instead of reporting the missing permission"
elif [ "$RC" -eq 2 ] && out_has record "not authorized"; then
    record PASS "record fails-fast-without-mic-permission" "exit 2 with the System Settings hint"
elif [ "$RC" -eq 0 ]; then
    record PASS "record fails-fast-without-mic-permission" "microphone authorized here: recorded 1 s"
else
    record SKIP "record fails-fast-without-mic-permission" "$(rc_reason record) (no usable input device?)"
fi
cli virtualmic 60 virtualmic 1
if out_has virtualmic "driver installed: true"; then
    record SKIP "virtualmic driver-absent-is-reported" "a Transcriberr Microphone driver is installed on this machine"
elif [ "$TIMED_OUT" -eq 0 ] && [ "$RC" -eq 1 ] && out_has virtualmic "no feed device"; then
    record PASS "virtualmic driver-absent-is-reported" "exit 1: no feed device"
else
    record FAIL "virtualmic driver-absent-is-reported" "$(rc_reason virtualmic)"
fi

# --------------------------------------------------------- knowledge base ---
cli kb-help 30 kb help
expect_rc "kb help" kb-help 0 "transcriberrcli kb"
cli kb-nosub 30 kb
expect_rc "kb missing-subcommand" kb-nosub 64
cli kb-stats 30 kb stats
expect_rc "kb missing-library-env" kb-stats 1 "No Transcriberr database at"
cli kb-list-store 30 kb list --json --store "$WORK/elsewhere.store"
expect_rc "kb missing-library-flag" kb-list-store 1 "elsewhere.store"

record_lines < <(helper mcp "$CLI" on "$EXPECT_VERSION" "$LOGS/mcp.log" 2>> "$LOGS/helper.err")

# Assistant access switched off in Settings: kb refuses (77), MCP offers nothing.
if [ "$ALLOW_PREFS" = "1" ]; then
    prev="$(defaults read "$APP_DOMAIN" assistants.allowed 2>/dev/null || echo unset)"
    restore_access() {
        if [ "$prev" = "unset" ]; then defaults delete "$APP_DOMAIN" assistants.allowed > /dev/null 2>&1 || true
        elif [ "$prev" = "0" ]; then defaults write "$APP_DOMAIN" assistants.allowed -bool false
        else defaults write "$APP_DOMAIN" assistants.allowed -bool true; fi
    }
    trap restore_access EXIT
    if defaults write "$APP_DOMAIN" assistants.allowed -bool false; then
        cli kb-off 30 kb stats
        expect_rc "kb refused-when-access-off" kb-off 77 "switched off"
        record_lines < <(helper mcp "$CLI" off "" "$LOGS/mcp-off.log" 2>> "$LOGS/helper.err")
    else
        record FAIL "kb refused-when-access-off" "could not write $APP_DOMAIN assistants.allowed"
    fi
    restore_access
    trap - EXIT
else
    record SKIP "kb refused-when-access-off" "writes the app's preferences: set E2E_ALLOW_PREFS=1 (default on CI)"
fi

# ------------------------------------------------ store-writing commands ---
cli restore 30 restore-backups --dry-run
expect_rc "restore-backups no-backups" restore 0 "no backups found"
cli migrate-audio 30 migrate-audio --dry-run
expect_rc "migrate-audio no-library" migrate-audio 1 "no store at"
cli migrate-echo 30 migrate-echo --dry-run
expect_rc "migrate-echo no-library" migrate-echo 1 "no store at"

# --------------------------------------------------------------- bench/refinalize ---
mkdir -p "$WORK/bench-empty" "$WORK/bench"
cli bench-empty 30 bench --dir "$WORK/bench-empty"
expect_rc "bench empty-set" bench-empty 0 "^0 checked lines"
if [ "$HAVE_SPEECH" -eq 1 ]; then
    cp "$AUDIO/a2.wav" "$WORK/bench/clip.wav"
    # 10 reference words, 2 substituted: exactly 20.0% WER.
    helper_quiet bench-item "$WORK/bench" clip.wav \
        "please schedule the quarterly budget review for next tuesday afternoon" \
        "please schedule the quarterly budget review for last tuesday morning" English
    cli bench-summary 30 bench --dir "$WORK/bench"
    expect_rc "bench wer-of-corrections" bench-summary 0 "English.*1 lines.*20\.0% WER"
fi
helper_quiet dump "$WORK/finalize-dump.json"
cli refinalize 60 refinalize "$WORK/finalize-dump.json"
expect_rc "refinalize replays-a-dump" refinalize 0 "replay test"
cli refinalize-bad 30 refinalize "$WORK/not-audio.wav"
expect_rc "refinalize bad-dump" refinalize-bad 1 "cannot read finalize dump"

# --------------------------------------------------------- uk-model status ---
if [ "$SKIP_NETWORK" = "1" ]; then
    record SKIP "uk-model status" "E2E_SKIP_NETWORK=1"
else
    cli uk-status 120 uk-model status
    expect_rc "uk-model status" uk-status 0 "on Hugging Face: [0-9a-f]{8}"
fi

# ============================================================ speech models ===
if models_skipped; then
    record SKIP "models" "E2E_SKIP_MODELS=1: transcribe, diarize, voice, aec, run, Whisper, Gemma skipped"
elif [ "$HAVE_SPEECH" -ne 1 ]; then
    record FAIL "models" "no synthetic speech to run the models on"
else
    # ---------------------------------------------- Parakeet v3 (transcribe) ---
    a1secs="$(afinfo_secs "$AUDIO/a1.wav")"
    cli transcribe-json 1800 transcribe "$AUDIO/a1.wav" --json --language English
    if [ "$RC" -eq 0 ]; then
        record PASS "transcribe parakeet-v3" "first run includes the model download (${STEP_SECS}s)"
        record_lines < <(helper tjson "$LOGS/transcribe-json.out" "$a1secs" "quick brown fox jumps lazy dog river" "transcribe" 2>> "$LOGS/helper.err")
    else
        record FAIL "transcribe parakeet-v3" "$(rc_reason transcribe-json)"
    fi
    cli transcribe-m4a 600 transcribe "$AUDIO/a1.m4a"
    if [ "$RC" -eq 0 ]; then
        helper_between "$LOGS/transcribe-m4a.out" "$WORK/transcribe-m4a.txt"
        keyword_check "transcribe m4a-plain-text" "quick brown fox jumps lazy dog river" "$WORK/transcribe-m4a.txt"
    else
        record FAIL "transcribe m4a-plain-text" "$(rc_reason transcribe-m4a)"
    fi
    cli transcribe-badlang 600 transcribe "$AUDIO/a2.wav" --language Klingon
    expect_rc "transcribe unknown-language-falls-back" transcribe-badlang 0 "unknown --language 'Klingon'"
    if [ "$HAVE_UK" -eq 1 ]; then
        uksecs="$(afinfo_secs "$AUDIO/uk1.wav")"
        cli transcribe-uk 600 transcribe "$AUDIO/uk1.wav" --json --language Ukrainian
        if [ "$RC" -eq 0 ]; then
            record_lines < <(helper tjson "$LOGS/transcribe-uk.out" "$uksecs" "$UK_KW" "transcribe-uk" 2>> "$LOGS/helper.err")
        else
            record FAIL "transcribe-uk parakeet-v3" "$(rc_reason transcribe-uk)"
        fi
    else
        record SKIP "transcribe-uk parakeet-v3" "no Ukrainian voice"
    fi

    # ------------------------------------------------------------- voice print ---
    cli voice-enroll 1200 voice enroll "$AUDIO/enroll.wav" --out "$WORK/voiceprint.json"
    if [ "$RC" -eq 0 ] && [ -s "$WORK/voiceprint.json" ]; then
        record PASS "voice enroll" "$(grep -oE '[0-9]+ windows.*' "$LOGS/voice-enroll.out" | head -1)"
        run_step voice-show 60 env TRANSCRIBERR_VOICEPRINT="$WORK/voiceprint.json" "$CLI" voice show
        expect_rc "voice show" voice-show 0 "wespeaker_v2, [0-9]+ windows"
        if [ "$HAVE_DIALOG" -eq 1 ]; then
            mkdir -p "$WORK/score-a" "$WORK/score-b"
            cp "$AUDIO/a-test.wav" "$WORK/score-a/a.wav"
            cp "$AUDIO/b-test.wav" "$WORK/score-b/b.wav"
            cli voice-score-a 600 voice score "$WORK/score-a/a.wav" --print "$WORK/voiceprint.json" --csv "$WORK/score-a.csv"
            rca="$RC"
            cli voice-score-b 600 voice score "$WORK/score-b/b.wav" --print "$WORK/voiceprint.json" --csv "$WORK/score-b.csv"
            if [ "$rca" -eq 0 ] && [ "$RC" -eq 0 ]; then
                sa="$(helper csvmedian "$WORK/score-a.csv" 2>> "$LOGS/helper.err" || echo "nan 0")"
                sb="$(helper csvmedian "$WORK/score-b.csv" 2>> "$LOGS/helper.err" || echo "nan 0")"
                verdict="$(python3 -I -c 'import sys,math
a, na = sys.argv[1].split(); b, nb = sys.argv[2].split()
a, b = float(a), float(b)
ok = not math.isnan(a) and not math.isnan(b) and a >= b + 0.1
print(("PASS" if ok else "FAIL") + " median similarity: same voice %.2f (%s windows), other voice %.2f (%s windows), need a gap >= 0.10" % (a, na, b, nb))' "$sa" "$sb" 2> /dev/null || echo "FAIL could not read the score CSVs")"
                record "${verdict%% *}" "voice score tells-voices-apart" "${verdict#* }"
            else
                record FAIL "voice score tells-voices-apart" "exit $rca / $RC (logs/voice-score-*.out)"
            fi
        fi
    else
        record FAIL "voice enroll" "$(rc_reason voice-enroll)"
    fi

    if [ "$HAVE_DIALOG" -eq 1 ]; then
        # ------------------------------------------------------------- diarize ---
        printf 'dialog\t%s\n' "$AUDIO/dialog.wav" > "$WORK/diarize.tsv"
        cli diarize 1800 diarize "$WORK/diarize.tsv" "$WORK/diar" 2
        if [ "$RC" -eq 0 ] && [ -s "$WORK/diar/dialog.rttm" ] && [ -s "$WORK/diar/timing.tsv" ]; then
            record PASS "diarize writes-rttm" "$(grep -E '^\[diarize\]' "$LOGS/diarize.out" | head -1)"
            record_lines < <(helper rttm "$WORK/diar/dialog.rttm" "$AUDIO/regions.json" "diarize" 2>> "$LOGS/helper.err")
        else
            record FAIL "diarize writes-rttm" "$(rc_reason diarize)"
        fi
        cli superdiar 1800 superdiar "$AUDIO/dialog.wav"
        if [ "$RC" -eq 0 ]; then
            n="$(sed -nE 's/.*diarizer: [0-9]+ regions, ([0-9]+) speakers.*/\1/p' "$LOGS/superdiar.out" | head -1)"
            helper_between "$LOGS/superdiar.out" "$WORK/superdiar.txt"
            keyword_check "superdiar transcript" "$A_KW $B_KW" "$WORK/superdiar.txt"
            if [ "${n:-0}" -ge 2 ]; then record PASS "superdiar speakers" "$n speakers"
            else record FAIL "superdiar speakers" "${n:-0} speaker(s), need >= 2"; fi
        else
            record FAIL "superdiar diarized-transcript" "$(rc_reason superdiar)"
        fi

        # ----------------------------------------------------------------- aec ---
        cli aec 600 aec "$AUDIO/meeting.wav"
        if [ "$RC" -eq 0 ] && [ -f "$AUDIO/meeting.aec.wav" ] && [ -f "$AUDIO/meeting.mix.wav" ]; then
            record PASS "aec writes-cleaned-and-mix" "$(grep -oE 'reduced by [-0-9.]+ dB' "$LOGS/aec.out" | head -1)"
            afconvert -f WAVE -d LEI16@16000 -c 1 "$AUDIO/meeting.aec.wav" "$WORK/aec16.wav" > /dev/null 2>&1 || true
            if [ -f "$WORK/aec16.wav" ]; then
                record_lines < <(helper aec "$AUDIO/meeting.mic.wav" "$WORK/aec16.wav" "$AUDIO/regions.json" "aec" 2>> "$LOGS/helper.err")
            else
                record FAIL "aec echo-removed" "could not read meeting.aec.wav"
            fi
        else
            record FAIL "aec writes-cleaned-and-mix" "$(rc_reason aec)"
        fi

        # ----------------------------------------------------- full RUN pipeline ---
        run_step run-dialog 1800 env TRANSCRIBERR_DUMP_FINALIZE="$WORK/run-dump.json" \
            "$CLI" run "$AUDIO/dialog.wav" 2 parakeet-v3 "" "" English
        if [ "$RC" -eq 0 ]; then
            helper_quiet runout "$LOGS/run-dialog.out" "$WORK/run-dialog.json"
            record_lines < <(helper runcheck "$WORK/run-dialog.json" "run parakeet-diarized" "$A_KW" "$B_KW" diar 2>> "$LOGS/helper.err")
            if [ -s "$WORK/run-dump.json" ]; then
                cli refinalize-real 120 refinalize "$WORK/run-dump.json"
                if [ "$RC" -eq 0 ]; then
                    cut -f4- "$LOGS/refinalize-real.out" > "$WORK/refinalize-real.txt"
                    keyword_check "refinalize replays-the-run" "$A_KW $B_KW" "$WORK/refinalize-real.txt"
                else
                    record FAIL "refinalize replays-the-run" "$(rc_reason refinalize-real)"
                fi
            else
                record FAIL "refinalize replays-the-run" "TRANSCRIBERR_DUMP_FINALIZE wrote no dump"
            fi
        else
            record FAIL "run parakeet-diarized" "$(rc_reason run-dialog)"
        fi
        cli run-meeting 1800 run "$AUDIO/meeting.wav" 0 parakeet-v3 "" "" English
        if [ "$RC" -eq 0 ]; then
            helper_quiet runout "$LOGS/run-meeting.out" "$WORK/run-meeting.json"
            record_lines < <(helper runcheck "$WORK/run-meeting.json" "run split-track-meeting" "$A_KW" "$B_KW" split 2>> "$LOGS/helper.err")
        else
            record FAIL "run split-track-meeting" "$(rc_reason run-meeting)"
        fi
    else
        record SKIP "diarize/aec/run" "no two-voice dialog"
    fi

    cli bench-score 1200 bench score parakeet-v3 --dir "$WORK/bench"
    if [ "$RC" -eq 0 ]; then
        wer="$(sed -nE 's/^### parakeet-v3 English: ([0-9.]+)% WER.*/\1/p' "$LOGS/bench-score.out" | head -1)"
        verdict="$(python3 -I -c 'import sys
w = sys.argv[1]
print(("PASS" if w and float(w) <= 40 else "FAIL") + " Parakeet v3 against the checked line: %s%% WER" % (w or "?"))' "$wer")"
        record "${verdict%% *}" "bench score" "${verdict#* }"
    else
        record FAIL "bench score" "$(rc_reason bench-score)"
    fi

    # --------------------------------------------------------- Parakeet UK ---
    if [ "$SKIP_UK" = "1" ]; then
        record SKIP "run parakeet-uk" "E2E_SKIP_UK=1"
    elif [ "$HAVE_UK" -ne 1 ]; then
        record SKIP "run parakeet-uk" "no Ukrainian voice"
    else
        cli run-uk 2400 run "$AUDIO/uk1.wav" 0 parakeet-uk "" "" Ukrainian
        if [ "$RC" -eq 0 ]; then
            helper_quiet runout "$LOGS/run-uk.out" "$WORK/run-uk.json"
            record_lines < <(helper runcheck "$WORK/run-uk.json" "run parakeet-uk" "$UK_KW" "" plain 2>> "$LOGS/helper.err")
        else
            record FAIL "run parakeet-uk" "$(rc_reason run-uk)"
        fi
    fi

    # ------------------------------------------------------------- Whisper ---
    if whisper_skipped; then
        record SKIP "whisper" "E2E_SKIP_WHISPER=1: whisper, langid, whisperbench, whisperloop, Super skipped"
    else
        cli whisper-en 3600 whisper "$AUDIO/a1.wav" en
        if [ "$RC" -eq 0 ]; then
            helper_between "$LOGS/whisper-en.out" "$WORK/whisper-en.txt"
            keyword_check "whisper large-v3-english" "quick brown fox jumps lazy dog river" "$WORK/whisper-en.txt" "${STEP_SECS}s incl. download"
        else
            record FAIL "whisper large-v3-english" "$(rc_reason whisper-en)"
        fi
        cli langid-en 1800 langid "$AUDIO/a-test.wav"
        if [ "$RC" -eq 0 ]; then
            langid_check "langid english" en "$LOGS/langid-en.out"
        else
            record FAIL "langid english" "$(rc_reason langid-en)"
        fi
        if [ "$HAVE_UK" -eq 1 ]; then
            cli whisper-uk 1800 whisper "$AUDIO/uk1.wav" uk
            if [ "$RC" -eq 0 ]; then
                helper_between "$LOGS/whisper-uk.out" "$WORK/whisper-uk.txt"
                keyword_check "whisper large-v3-ukrainian" "$UK_KW" "$WORK/whisper-uk.txt"
            else
                record FAIL "whisper large-v3-ukrainian" "$(rc_reason whisper-uk)"
            fi
            cli langid-uk 1800 langid "$AUDIO/uk1.wav" 3
            if [ "$RC" -eq 0 ]; then
                langid_check "langid ukrainian" uk "$LOGS/langid-uk.out"
            else
                record FAIL "langid ukrainian" "$(rc_reason langid-uk)"
            fi
        fi
        cli whisperbench 1800 whisperbench ane English "$AUDIO/a2.wav"
        if [ "$RC" -eq 0 ] && [ -s "$AUDIO/a2.wav.ane.txt" ]; then
            keyword_check "whisperbench whole-track" "schedule quarterly budget review tuesday afternoon" \
                "$AUDIO/a2.wav.ane.txt" "$(grep -E '^WALL' "$LOGS/whisperbench.out" | head -1 || true)"
        else
            record FAIL "whisperbench whole-track" "$(rc_reason whisperbench)"
        fi
        if [ "$HAVE_DIALOG" -eq 1 ]; then
            bmid="$(python3 -I -c 'import json,sys
r = [g for g in json.load(open(sys.argv[1]))["regions"] if g["label"] == "B"][0]
print("%.1f" % ((r["start"] + r["end"]) / 2))' "$AUDIO/regions.json" 2> /dev/null || echo 6)"
            cli whisperloop 1800 whisperloop "$AUDIO/meeting.wav" "$bmid" large-v3
            expect_rc "whisperloop sys-chunk-diagnostic" whisperloop 0 "^chunk [0-9.]+-[0-9.]+ s"
            cli run-whisper 3600 run "$AUDIO/dialog.wav" 2 whisper-large-v3 "" "" English
            if [ "$RC" -eq 0 ]; then
                helper_quiet runout "$LOGS/run-whisper.out" "$WORK/run-whisper.json"
                record_lines < <(helper runcheck "$WORK/run-whisper.json" "run whisper-diarized" "$A_KW" "$B_KW" diar 2>> "$LOGS/helper.err")
            else
                record FAIL "run whisper-diarized" "$(rc_reason run-whisper)"
            fi
            # Super: Whisper + Parakeet merged word by word; without a Gemma
            # bundle the arbiter is skipped and engine A's reading stands.
            cli run-super 3600 run "$AUDIO/dialog.wav" 2 ensemble whisper-large-v3 parakeet-v3 English
            if [ "$RC" -eq 0 ]; then
                helper_quiet runout "$LOGS/run-super.out" "$WORK/run-super.json"
                record_lines < <(helper runcheck "$WORK/run-super.json" "run super" "$A_KW" "$B_KW" diar 2>> "$LOGS/helper.err")
            else
                record FAIL "run super" "$(rc_reason run-super)"
            fi
        fi
    fi

    # --------------------------------------------------------------- Gemma ---
    if [ "$RUN_GEMMA" != "1" ]; then
        record SKIP "gemma" "set E2E_GEMMA=1 to download Gemma 4 E2B (~2.6 GB) and run litert/gentest/brief"
    else
        GEMMA_DIR="$HOME/Library/Application Support/Transcriberr/models/litert-community/gemma-4-E2B-it-litert-lm"
        GEMMA_FILE="$GEMMA_DIR/gemma-4-E2B-it.litertlm"
        GEMMA_URL="https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm"
        GEMMA_SHA="181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
        mkdir -p "$GEMMA_DIR"
        if [ ! -s "$GEMMA_FILE" ]; then
            run_step gemma-download 3600 curl -fL --retry 3 -o "$GEMMA_FILE.partial" "$GEMMA_URL"
            if [ "$RC" -eq 0 ]; then mv "$GEMMA_FILE.partial" "$GEMMA_FILE"; fi
        fi
        if [ -s "$GEMMA_FILE" ] && [ "$(shasum -a 256 "$GEMMA_FILE" | awk '{print $1}')" = "$GEMMA_SHA" ]; then
            record PASS "gemma bundle" "E2B present, SHA-256 matches the catalog"
            cli litert 2400 litert "$AUDIO/a1.wav"
            if [ "$RC" -eq 0 ]; then
                helper_between "$LOGS/litert.out" "$WORK/litert.txt"
                keyword_check "litert gemma-audio-transcription" "quick brown fox jumps lazy dog river" \
                    "$WORK/litert.txt" "$(grep -oE 'engine ready on [A-Z]+' "$LOGS/litert.out" | head -1 || true)"
            else
                record FAIL "litert gemma-audio-transcription" "$(rc_reason litert)"
            fi
            cli gentest 1800 gentest
            expect_rc "gentest concurrent-generations" gentest 0 "PASS — no starved generations"
            printf 'Yuri: Good morning, let us review the Kubernetes rollout.\nKees: I will send the budget on Tuesday.\n' > "$WORK/brief.txt"
            cli brief 1800 brief "$WORK/brief.txt"
            expect_rc "brief meeting-brief" brief 0 "\[brief\] ✓"
        else
            rm -f "$GEMMA_FILE.partial"
            record FAIL "gemma bundle" "download failed or SHA-256 mismatch (logs/gemma-download.err)"
        fi
    fi
fi

# ----------------------------------------------------------------- summary ---
echo
echo "PASS $PASS  FAIL $FAIL  SKIP $SKIP   (results: $RESULTS, logs: $LOGS)"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Failed checks:"
    grep -E '^FAIL' "$RESULTS" | cut -f2,3 | sed 's/^/  /'
    exit 1
fi
exit 0

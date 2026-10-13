#!/usr/bin/env python3
"""Writes unreachable.json: apply slots (corpus.json apply_pos, heldout.json
slots) that NO learned rule can reasonably reach, by the objective rules
below, applied in order (first match wins). It was run once and the output
COMMITTED; the list is frozen so fixers are judged against a fixed bar —
fixer agents must not edit unreachable.json or re-run this to move it.

Per voice, the "corrected forms" of a term are the heard forms of every slot
that voice's learn events (learn_keyboard, and learn_spelled whose letters
Parakeet heard right) mis-wrote — exactly main.swift's expectedRules. A
merged slot ("Dhruvmehar" for "Dhruv Mehra") is judged against the joined
term and joined forms.

  R1 dropped     Parakeet wrote nothing for the name.
  R2 numeral     the heard form contains a digit ("5" for Pype).
  R3 untaught    the voice never corrected that term in any learn event
                 (e.g. Rishi heard Mehra right every time it was taught), so
                 no rule for the term exists in that voice's memory.md.
  R4 swallowed   the garble swallows a neighbouring non-name word: in the
                 truth↔raw alignment (difflib, as build_corpus.py) the heard
                 token is also the best match of an adjacent non-name truth
                 word ("Kaldhruve" = Kal + Dhruv, "Mehraji" = Mehra + ji).
  R5 far-sound   SoundCode(heard minus 's) is more than 1 edit from
                 SoundCode(term) AND from SoundCode of every form that voice
                 corrected for that term ("of" OF/F vs TRF, "Fight" FT vs PP
                 when the voice never corrected a F-T form).
SoundCode = Airboard/SoundCode.swift at commit 5c07f49 (frozen here).
Slots of class correct or case are always reachable.

Usage: classify_unreachable.py  (from anywhere; writes unreachable.json)
"""
import difflib, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REV = "5c07f49"

def tokens(text):
    out = []
    for m in re.finditer(r"\S+", text):
        core = re.sub(r"^[^0-9A-Za-zÀ-￿]+|[^0-9A-Za-zÀ-￿]+$", "", m.group(0).replace("’", "'"))
        if core:
            out.append(core)
    return out

def strip_poss(w):
    w = w.replace("’", "'")
    return w[:-2] if w.endswith("'s") else w

def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def soundcoder():
    d = tempfile.mkdtemp()
    src = subprocess.run(["git", "-C", HERE, "show", f"{REV}:Airboard/SoundCode.swift"],
                         capture_output=True, text=True, check=True).stdout
    open(f"{d}/SoundCode.swift", "w").write(src)
    open(f"{d}/main.swift", "w").write('while let l = readLine() { print(SoundCode.code(l)) }\n')
    subprocess.run(["swiftc", "-O", f"{d}/SoundCode.swift", f"{d}/main.swift", "-o", f"{d}/sc"],
                   check=True, capture_output=True)
    cache = {}
    def code(s):
        if s not in cache:
            cache[s] = subprocess.run([f"{d}/sc"], input=s + "\n", capture_output=True, text=True).stdout.strip()
        return cache[s]
    return code

def corrected_forms(items):
    """voice -> term (or "Dhruv Mehra") -> set of heard forms."""
    out = {}
    for it in items:
        if it["role"] not in ("learn_keyboard", "learn_spelled"):
            continue
        if it["role"] == "learn_spelled" and it.get("spelling_heard") is False:
            continue
        f = out.setdefault(it["voice"], {})
        for s in it["slots"]:
            if s["class"] in ("correct", "dropped") or not s.get("heard"):
                continue
            if s.get("merged"):
                terms = " ".join(x["term"] for x in it["slots"] if x.get("merged") and x.get("heard") == s["heard"])
                f.setdefault(terms, set()).add(strip_poss(s["heard"]))
                for t in terms.split():
                    f.setdefault(t, set())   # taught (as part of the merge)
            else:
                f.setdefault(s["term"], set()).add(strip_poss(s["heard"]))
    return out

def swallowed(it, slot):
    tt = tokens(it["truth"]); rt = tokens(it["raw"])
    slot_idx = {s["i"] for s in it["slots"]}
    for op, a1, a2, b1, b2 in difflib.SequenceMatcher(
            None, [t.lower() for t in tt], [t.lower() for t in rt], autojunk=False).get_opcodes():
        if not (a1 <= slot["i"] < a2) or op != "replace" or a2 - a1 == b2 - b1:
            continue
        pick = {}
        for i in range(a1, a2):
            pick[i] = max(range(b1, b2), key=lambda j: difflib.SequenceMatcher(
                None, tt[i].lower(), rt[j].lower()).ratio())
        mine = pick[slot["i"]]
        for i in (slot["i"] - 1, slot["i"] + 1):
            if a1 <= i < a2 and i not in slot_idx and pick[i] == mine:
                return tt[i]
    return None

def group_slots(it, s):
    """The slot, or every slot of its merge ("Kaldruvmehra" = Dhruv + Mehra)."""
    if not s.get("merged"):
        return [s]
    return [x for x in it["slots"] if x.get("merged") and x.get("heard") == s.get("heard")]

def main():
    code = soundcoder()
    corpus = json.load(open(f"{HERE}/corpus.json"))["items"]
    heldout = json.load(open(f"{HERE}/heldout.json"))["items"]
    forms = corrected_forms(corpus)
    out = []
    counts = {}
    total = 0
    for it in corpus + heldout:
        if it["role"] not in ("apply_pos", "heldout_pos", "heldout_neg"):
            continue
        vf = forms.get(it["voice"], {})
        for k, s in enumerate(it["slots"]):
            total += 1
            if s["class"] in ("correct", "case"):
                continue
            heard = s.get("heard") or ""
            if s.get("merged"):
                group = " ".join(x["term"] for x in it["slots"] if x.get("merged") and x.get("heard") == heard)
            else:
                group = s["term"]
            rule = reason = None
            if s["class"] == "dropped" or not heard:
                rule, reason = "R1", "Parakeet dropped the name"
            elif re.search(r"\d", heard):
                rule, reason = "R2", f"heard as the numeral \"{heard}\""
            elif any(t not in vf for t in group.split()):
                missing = [t for t in group.split() if t not in vf]
                rule, reason = "R3", f"{it['voice']} never corrected {'/'.join(missing)} in any learn event"
            elif any(swallowed(it, x) for x in group_slots(it, s)):
                w = next(swallowed(it, x) for x in group_slots(it, s) if swallowed(it, x))
                rule, reason = "R4", f"\"{heard}\" swallows the neighbouring word \"{w}\""
            else:
                hc = code(strip_poss(heard))
                cand = {group: code(group)}
                fs = set(vf.get(group, set()))
                if " " in group:   # joined per-term forms: Drove+Mera
                    a, b = group.split(" ", 1)
                    fs |= {x + y for x in vf.get(a, set()) for y in vf.get(b, set())}
                for f in fs:
                    cand[f] = code(f)
                best = min(edit_distance(hc, c) for c in cand.values())
                if best > 1:
                    rule = "R5"
                    reason = (f"\"{heard}\" {hc} is {best} code edits from {group} {code(group)} and from every "
                              f"form {it['voice']} corrected ({', '.join(sorted(f'{f} {code(f)}' for f in fs)) or 'none'})")
            if rule:
                counts[rule] = counts.get(rule, 0) + 1
                out.append({"id": it["id"], "slot": k, "term": s["term"], "heard": heard,
                            "rule": rule, "reason": reason})
    doc = {
        "about": "Apply slots no learned rule can reasonably reach. Frozen list (generated once by "
                 "classify_unreachable.py, rules in its header); fixers must not edit it. main.swift "
                 "reports apply recall raw and over the remaining (reachable) slots.",
        "rules": {
            "R1": "dropped: Parakeet wrote nothing for the name",
            "R2": "numeral: the heard form contains a digit",
            "R3": "untaught: the voice never corrected that term in any learn event, so no rule for it exists",
            "R4": "swallowed: the heard token is also the best alignment match of an adjacent non-name truth word",
            "R5": "far-sound: SoundCode(heard minus 's) > 1 edit from SoundCode(term) and from every form that voice corrected for it (SoundCode @5c07f49)",
        },
        "counts": dict(sorted(counts.items())) | {"unreachable": len(out), "slots_total": total},
        "slots": out,
    }
    with open(f"{HERE}/unreachable.json", "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(json.dumps(doc["counts"]), file=sys.stderr)

if __name__ == "__main__":
    main()

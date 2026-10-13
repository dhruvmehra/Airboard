#!/usr/bin/env python3
"""Builds corpus.json from gen.sh's manifest + Parakeet transcripts.

Per utterance: id, voice, role, label, truth (braces removed), raw (REAL
Parakeet output), slots (one per {Name} in the truth: token index, truth
word, expected term, what Parakeet wrote there, and its class), and for
learn_keyboard events `after` = raw with the misheard name tokens replaced
by the true spelling (what the user's keyboard fix leaves in the field).

Slot class: correct (Parakeet wrote the truth word exactly), case (right
letters, wrong capitalisation), dict (every heard word, minus a possessive
's, is in /usr/share/dict/words, case-insensitive), nondict, dropped.
Tokenisation (shared with main.swift): split on whitespace, strip leading/
trailing non-alphanumerics, curly apostrophe -> straight.
"""
import difflib, json, re, sys

def tokens(text):
    out = []
    for m in re.finditer(r"\S+", text):
        raw = m.group(0).replace("’", "'")
        lead = len(raw) - len(re.sub(r"^[^0-9A-Za-zÀ-￿]+", "", raw))
        core = re.sub(r"^[^0-9A-Za-zÀ-￿]+|[^0-9A-Za-zÀ-￿]+$", "", raw)
        if core:
            s = m.start() + lead
            out.append((core, s, s + len(core)))
    return out

DICT = set()
with open("/usr/share/dict/words") as f:
    for w in f:
        DICT.add(w.strip().lower())

def is_letters(tok):
    """A spoken spelling as Parakeet writes it: "D", "D-H-R-U-V", "DHRUV"."""
    t = tok.replace("-", "")
    return t.isalpha() and t.isupper() and (len(t) == 1 or len(t) >= 3)

def strip_poss(w):
    return re.sub(r"'s$", "", w)

def klass(heard, word):
    if heard is None or heard == "":
        return "dropped"
    if heard == word:
        return "correct"
    if heard.lower() == word.lower():
        return "case"
    ws = heard.split()
    return "dict" if all(strip_poss(w.lower()) in DICT for w in ws) else "nondict"

def main(manifest, transcripts, out):
    heard = {}
    for line in open(transcripts):
        if "\t" in line:
            f, t = line.rstrip("\n").split("\t", 1)
            heard[f] = t
    items = []
    for line in open(manifest):
        f, role, sid, voice, flags, prev, text = line.rstrip("\n").split("\t")
        raw = heard.get(f, "<ERROR>")
        if raw == "<ERROR>":
            print(f"skip {f}: probe error", file=sys.stderr); continue
        # truth tokens + slots
        slot_marks = []
        truth = ""
        for part in re.split(r"(\{[^}]*\})", text):
            if part.startswith("{"):
                word = part[1:-1]
                slot_marks.append((len(truth), word))
                truth += word
            else:
                truth += part
        ttoks = tokens(truth)
        slots = []
        for start, word in slot_marks:
            idx = next(i for i, t in enumerate(ttoks) if t[1] == start)
            slots.append({"i": idx, "word": ttoks[idx][0], "term": strip_poss(word)})
        rtoks = tokens(raw)
        # Spoken spellings: leave the letters out of the alignment so the
        # slot pairs with the name as heard ("Drew, DHRUV" -> "Drew").
        tmap = list(range(len(ttoks)))
        rmap = list(range(len(rtoks)))
        if role == "learn_spelled":
            tmap = [i for i in tmap if not is_letters(ttoks[i][0])]
            rmap = [j for j in rmap if not is_letters(rtoks[j][0])]
        tk = [ttoks[i][0].lower() for i in tmap]
        rk = [rtoks[j][0].lower() for j in rmap]
        units = []   # (j1, j2, replacement)
        by_index = {s["i"]: s for s in slots}
        for op, a1, a2, b1, b2 in difflib.SequenceMatcher(None, tk, rk, autojunk=False).get_opcodes():
            # positions in the filtered lists -> token indices (contiguous in
            # the filtered view; spelled letters never sit inside a slot block)
            i1 = tmap[a1] if a1 < len(tmap) else len(ttoks)
            i2 = tmap[a2 - 1] + 1 if a2 > a1 else i1
            j1 = rmap[b1] if b1 < len(rmap) else len(rtoks)
            j2 = rmap[b2 - 1] + 1 if b2 > b1 else j1
            block = [by_index[i] for i in range(i1, i2) if i in by_index]
            if not block:
                continue
            if op == "equal" or (op == "replace" and i2 - i1 == j2 - j1):
                for s in block:
                    j = j1 + (s["i"] - i1)
                    s["heard"] = rtoks[j][0]
                    if rtoks[j][0] != s["word"]:
                        units.append((j, j + 1, s["word"]))
            elif op == "replace":
                # Unequal block: each slot takes the most similar heard token;
                # two slots on one token = a merge ("Dhruvmehra").
                picks = {}
                for s in block:
                    j = max(range(j1, j2), key=lambda j: difflib.SequenceMatcher(
                        None, s["word"].lower(), rtoks[j][0].lower()).ratio())
                    picks.setdefault(j, []).append(s)
                for j, ss in picks.items():
                    for s in ss:
                        s["heard"] = rtoks[j][0]
                        if len(ss) > 1:
                            s["merged"] = True
                units.append((j1, j2, " ".join(t[0] for t in ttoks[i1:i2])))
            else:  # delete
                for s in block:
                    s["heard"] = ""
        for s in slots:
            s["class"] = klass(s.get("heard"), s["word"])
        item = {"id": f"{sid}-{voice}", "sentence": sid, "voice": voice, "role": role,
                "label": "neg" if role == "apply_neg" else "pos",
                "truth": truth, "raw": raw, "slots": slots}
        if "acc" in flags.split(","):
            item["acceptance"] = True
        if prev:
            item["prev"] = f"{prev}-{voice}"
        if role == "learn_spelled":
            # Did Parakeet write the spoken letters as the right letters?
            # If not ("PhiPee", "PYP"), nothing correct can be learned from
            # this event: main.swift leaves it out of the expected rules.
            letters = "".join(t[0].replace("-", "") for t in rtoks if is_letters(t[0])).lower()
            item["letters"] = letters
        if role == "learn_keyboard":
            after = raw
            for j1, j2, rep in sorted(units, key=lambda u: -u[0]):
                after = after[:rtoks[j1][1]] + rep + after[rtoks[j2 - 1][2]:]
            item["after"] = after
        items.append(item)
    by_id = {i["id"]: i for i in items}
    for i in items:
        if i["role"] != "learn_spelled":
            continue
        src = by_id.get(i.get("prev", "")) if not i["slots"] else i
        target = by_id.get(i.get("prev", "")) if not i["slots"] else None
        terms = "".join(s["term"] for s in (src or i)["slots"]).lower()
        ok = bool(i["letters"]) and i["letters"] == terms
        if i["slots"]:
            i.setdefault("spelling_heard", ok)
        if target is not None:   # a follow-up spelling: the name sits in prev
            i["spelling_heard"] = ok
            target["spelling_heard"] = ok
    with open(out, "w") as f:
        json.dump({"generated_by": "scripts/name-eval/gen.sh (say -o + Parakeet TDT v3 via FluidAudio 0.15.5)",
                   "items": items}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {len(items)} items to {out}", file=sys.stderr)

if __name__ == "__main__":
    main(*sys.argv[1:4])

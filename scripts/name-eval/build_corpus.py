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
Every row carries "source": "parakeet" (raw is real Parakeet output, never
hand-typed). learn_keyboard_neg rows carry `edit` ({"from","to"} or
{"rewrite"}: the ORDINARY keyboard edit, applied by main.swift to what was
inserted; `at` = the raw token it targets, see resolve_edit) and `after`
(that edit applied to raw, for reading).
Usage: build_corpus.py manifest transcripts out.json [--merge]
  --merge: keep out.json's rows whose role is not in this manifest.

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

NEG_ROLES = {"apply_neg", "learn_keyboard_neg", "heldout_neg"}

def parse_edit(spec):
    """"from -> to" or "= new text" (see sentences.txt)."""
    spec = spec.strip()
    if spec.startswith("="):
        return {"rewrite": spec[1:].strip()}
    a, b = spec.split(" -> ", 1)
    return {"from": a.strip(), "to": b.strip()}

def resolve_edit(edit, truth, raw):
    """Pins the ordinary edit to what Parakeet actually wrote. `at` = the raw
    token the user edits: `from` itself if Parakeet wrote it, else the raw
    token aligned 1:1 with `from` in the truth ("bust" for "burst"). If the
    truth word sits in a garbled stretch with no 1:1 token ("Mira
    behanarahi" for "Mera behen aa rahi hai"), the user retypes the field:
    the edit becomes a rewrite to the truth with the edit applied."""
    if "rewrite" in edit:
        return dict(edit)
    rt = tokens(raw)
    if any(c.lower() == edit["from"].lower() for c, _, _ in rt):
        return {**edit, "at": next(c for c, _, _ in rt if c.lower() == edit["from"].lower())}
    tt = tokens(truth)
    k = next((i for i, t in enumerate(tt) if t[0].lower() == edit["from"].lower()), None)
    if k is not None:
        for op, a1, a2, b1, b2 in difflib.SequenceMatcher(
                None, [t[0].lower() for t in tt], [t[0].lower() for t in rt], autojunk=False).get_opcodes():
            if a1 <= k < a2 and op in ("equal", "replace") and a2 - a1 == b2 - b1:
                return {**edit, "at": rt[b1 + k - a1][0]}
    fixed, _ = apply_edit(truth, {**edit, "at": edit["from"]})
    return {**edit, "rewrite": fixed, "garbled": True}

def apply_edit(text, edit):
    """Same rule as main.swift's applyEdit: a rewrite replaces the field;
    else the first token whose core equals `at` (case-insensitive) gets its
    core replaced by `to` (first letter upper-cased if the token's was)."""
    if "rewrite" in edit:
        return edit["rewrite"], True
    for core, s, e in tokens(text):
        if core.lower() == edit["at"].lower():
            to = edit["to"]
            if core[:1].isupper():
                to = to[:1].upper() + to[1:]
            return text[:s] + to + text[e:], True
    return text, False

def main(manifest, transcripts, out, merge=None):
    heard = {}
    for line in open(transcripts):
        if "\t" in line:
            f, t = line.rstrip("\n").split("\t", 1)
            heard[f] = t
    items = []
    for line in open(manifest):
        f, role, sid, voice, flags, prev, text = line.rstrip("\n").split("\t")
        edit = None
        if " ==> " in text:
            text, spec = text.split(" ==> ", 1)
            edit = parse_edit(spec)
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
                "label": "neg" if role in NEG_ROLES else "pos",
                "source": "parakeet",
                "truth": truth, "raw": raw, "slots": slots}
        if edit is not None:
            item["edit"] = resolve_edit(edit, truth, raw)
            item["after"], _ = apply_edit(raw, item["edit"])
            if item["after"] == raw:
                item["edit_noop"] = True   # Parakeet already wrote the edited form
                print(f"note {item['id']}: edit is a no-op on raw {raw!r}", file=sys.stderr)
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
    # excluded_reason (a learn event deliberately left out of "learnable"
    # recall, see main.swift) is a human judgement on ONE transcript: carry
    # it over only while that row's raw text is unchanged.
    try:
        prior = {i["id"]: i for i in json.load(open(out))["items"]}
    except (OSError, ValueError, KeyError):
        prior = {}
    for i in items:
        p = prior.get(i["id"])
        if p and p.get("excluded_reason") and p["raw"] == i["raw"]:
            i["excluded_reason"] = p["excluded_reason"]
    doc = {"generated_by": "scripts/name-eval/gen.sh (say -o + Parakeet TDT v3 via FluidAudio 0.15.5)"}
    if merge:
        old = json.load(open(out))
        roles = {i["role"] for i in items}
        keep = [i for i in old["items"] if i["role"] not in roles]
        doc = {k: v for k, v in old.items() if k != "items"}
        items = keep + items
    doc["items"] = items
    with open(out, "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {len(items)} items to {out}", file=sys.stderr)

if __name__ == "__main__":
    a = sys.argv[1:]
    main(a[0], a[1], a[2], merge="--merge" in a[3:])

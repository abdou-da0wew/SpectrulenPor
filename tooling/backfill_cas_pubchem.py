#!/usr/bin/env python3
"""Backfill CAS Registry Numbers into the bundled corpus JSONs from PubChem.

The corpus shipped without CAS numbers (the README promised them). This tool
resolves every compound name on PubChem (PUG REST), extracts the CAS Registry
Number from the record's synonyms, checksum-validates it, and writes it back
into the JSON under the `cas` key.

Design rules (mirroring the app's "never guess" AI discipline):
  * A CAS is only written when it comes from PubChem synonyms for a record
    that PubChem itself resolved from the compound's name (or, for the
    formula-fallback path, when the record's synonyms also contain the name).
  * Every candidate CAS must pass the official CAS checksum test.
  * If a record yields several *distinct* valid CAS numbers, it is reported
    as AMBIGUOUS and nothing is written (resolve manually with --set).
  * True mixtures/materials (borosilicate glass, 304 stainless steel, ITO)
    have no single CAS - they are skipped, not failed.

Usage:
  python3 tooling/backfill_cas_pubchem.py                 # dry run, full report
  python3 tooling/backfill_cas_pubchem.py --write         # apply changes
  python3 tooling/backfill_cas_pubchem.py --file assets/docs/periodic_table.json --write
  python3 tooling/backfill_cas_pubchem.py --limit 5       # smoke test
  python3 tooling/backfill_cas_pubchem.py --set "Name=1234-56-7" --write
  python3 tooling/backfill_cas_pubchem.py --only "Water|Ethanol" --write

PubChem policy: max 5 requests/second; this client sends ~3.3 req/s and
retries 429/503/504 with exponential backoff.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound"
VIEW = "https://pubchem.ncbi.nlm.nih.gov/rest/pug_view/data/compound"
UA = "SpectruLenPor/5.5.1 (tooling: CAS backfill; https://github.com/abdou-da0wew/SpectrulenPor)"
# Authoritative CAS anchor: the record's CAS section references the official
# CAS Common Chemistry database (commonchemistry.cas.org) for well-known
# chemicals - one CAS per record, no isotopologue/history variants.
COMMONCHEM_URL_RE = re.compile(r"commonchemistry\.cas\.org/detail\?cas_rn=(\d{2,7}-\d{2}-\d)")
MIN_INTERVAL = 0.30  # seconds between requests (< 5 req/s PubChem limit)
CAS_RE = re.compile(r"(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)")
# Mixtures / alloys / doped materials: no single CAS Registry Number exists.
MIXTURE_FORMULA_RE = re.compile(r"\+|%|^[A-Za-z]+\-[A-Za-z]+\-")


class _RateLimiter:
    def __init__(self, interval: float) -> None:
        self._interval = interval
        self._last = 0.0

    def wait(self) -> None:
        delta = time.monotonic() - self._last
        if delta < self._interval:
            time.sleep(self._interval - delta)
        self._last = time.monotonic()


_limiter = _RateLimiter(MIN_INTERVAL)


def _get_json(url: str, retries: int = 3) -> dict | None:
    """GET a PubChem PUG REST URL; None on 404; raises on exhausted retries."""
    backoff = 2.0
    for attempt in range(retries + 1):
        _limiter.wait()
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (429, 503, 504) and attempt < retries:
                time.sleep(backoff)
                backoff *= 2
                continue
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt < retries:
                time.sleep(backoff)
                backoff *= 2
                continue
            raise
    return None


def cas_valid(cas: str) -> bool:
    """Official CAS Registry Number check-digit validation.

    Digits before the final check digit are weighted 1..n from right to left;
    the sum modulo 10 must equal the check digit. e.g. 7732-18-5 -> 5.
    """
    digits = cas.replace("-", "")
    if len(digits) < 4 or not digits.isdigit():
        return False
    check = int(digits[-1])
    body = digits[:-1]
    total = sum(int(d) * (i + 1) for i, d in enumerate(reversed(body)))
    return total % 10 == check


def _name_variants(name: str) -> list[str]:
    """Lookup candidates derived from a corpus name, most-specific first."""
    variants: list[str] = [name]
    stripped = re.sub(r"\s*\([^)]*\)\s*", " ", name).strip(" -,")
    if stripped and stripped.lower() != name.lower():
        variants.append(stripped)
    for paren in re.findall(r"\(([^)]+)\)", name):
        inner = paren.strip()
        # "Isopropanol (2-propanol)" -> the parenthetical is itself a synonym;
        # skip pure disambiguators like "(Vitamin C)" that PubChem rarely keys.
        if inner and not inner.lower().startswith(("vitamin", "epsom", "bleach", "quicklime", "slaked")):
            variants.append(inner)
    # Lowercase form last (PubChem is case-insensitive but keep order tidy).
    seen: set[str] = set()
    ordered: list[str] = []
    for v in variants:
        key = v.lower()
        if key not in seen:
            seen.add(key)
            ordered.append(v)
    return ordered


def _norm_formula(f: str) -> str:
    """Loose formula comparison: drop hydrate dots, spaces, parentheses."""
    return re.sub(r"[·∙.\s()]", "", f or "").lower()


def _cas_candidates(synonyms: list[str]) -> list[str]:
    """Distinct checksum-valid CAS numbers found among synonyms."""
    seen: list[str] = []
    for syn in synonyms:
        for cas in CAS_RE.findall(syn):
            if cas in seen:
                continue
            if cas_valid(cas):
                seen.append(cas)
    return seen


def _walk_strings(o, out: list) -> None:
    if isinstance(o, dict):
        for v in o.values():
            _walk_strings(v, out)
    elif isinstance(o, list):
        for v in o:
            _walk_strings(v, out)
    elif isinstance(o, str):
        out.append(o)


def _cas_from_pugview(cid: int) -> tuple[str, list[str]]:
    """CAS from the record's curated CAS section (PUG-View).

    Each CAS-section entry ("Information") cites one CAS number, some via the
    official CAS Common Chemistry database (commonchemistry.cas.org) - the
    CAS registry's own open subset. Records also list isotopologue and
    historical variants, so selection is evidence-weighted:

      1. restrict to checksum-valid candidates,
      2. prefer candidates backed by a Common Chemistry citation,
      3. among the preferred set require 2x frequency dominance over the
         runner-up (isotopologue citations are always a small minority),

    otherwise returns "" and the caller reports every candidate as AMBIGUOUS.

    Returns (selected_cas_or_empty, all_valid_candidates).
    """
    data = _get_json(f"{VIEW}/{cid}/JSON?heading=CAS")
    if not data:
        return "", []

    counts: dict[str, int] = {}
    commonchem: set[str] = set()

    def _walk(o) -> None:
        if isinstance(o, dict):
            info = o.get("Information")
            if isinstance(info, list):
                for entry in info:
                    if not isinstance(entry, dict):
                        continue
                    texts: list[str] = []
                    _walk_strings(entry.get("Value", {}), texts)
                    if entry.get("URL"):
                        texts.append(entry["URL"])
                    entry_cas = set()
                    for s in texts:
                        entry_cas.update(CAS_RE.findall(s))
                    for cas in entry_cas:
                        counts[cas] = counts.get(cas, 0) + 1
                        for s in texts:
                            if COMMONCHEM_URL_RE.search(s):
                                commonchem.add(cas)
                                break
                return
            for v in o.values():
                _walk(v)
        elif isinstance(o, list):
            for v in o:
                _walk(v)

    _walk(data)
    valid = {c: n for c, n in counts.items() if cas_valid(c)}
    if not valid:
        return "", []
    preferred = {c: n for c, n in valid.items() if c in commonchem} or valid
    ranked = sorted(preferred.items(), key=lambda kv: (-kv[1], kv[0]))
    if len(ranked) == 1 or ranked[0][1] >= 2 * ranked[1][1]:
        return ranked[0][0], list(valid)
    return "", list(valid)


def resolve(name: str, formula: str) -> dict:
    """Resolve one corpus entry -> {status, cas, cid, pubchem_formula, note}."""
    # 1. Name-based resolution (PubChem name lookup is authoritative).
    last_cid = 0
    last_note = ""
    for variant in _name_variants(name):
        data = _get_json(f"{BASE}/name/{urllib.parse.quote(variant)}/cids/JSON")
        if not data:
            continue
        cids = data.get("IdentifierList", {}).get("CID", [])
        if not cids:
            continue
        cid = cids[0]
        last_cid = cid
        # Primary: curated CAS Common Chemistry reference for this record.
        cas, candidates = _cas_from_pugview(cid)
        if cas:
            return {"status": "OK", "cas": cas, "cid": cid,
                    "pubchem_formula": "",
                    "note": "CAS Common Chemistry (PUG-View)"}
        # Fallback: exactly one valid CAS among the record's synonyms.
        syn_data = _get_json(f"{BASE}/cid/{cid}/synonyms/JSON")
        synonyms = (syn_data or {}).get("InformationList", {}).get("Information", [{}])[0].get("Synonym", [])
        syn_candidates = _cas_candidates(synonyms)
        for extra in candidates:
            if extra not in syn_candidates:
                syn_candidates.append(extra)
        if len(syn_candidates) == 1:
            return {"status": "OK", "cas": syn_candidates[0], "cid": cid,
                    "pubchem_formula": "",
                    "note": "single valid CAS among synonyms"}
        if len(syn_candidates) > 1:
            return {"status": "AMBIGUOUS", "cas": "", "cid": cid,
                    "pubchem_formula": "",
                    "note": "candidates: " + ", ".join(syn_candidates)}
        last_note = f"resolved as CID {cid} but no CAS in record"
    if last_cid:
        return {"status": "NO_CAS_IN_SYNONYMS", "cas": "", "cid": last_cid,
                "pubchem_formula": "", "note": last_note}
    # 2. Formula fallback - only for clean single formulas, and only accepted
    #    when the record's synonyms also contain the corpus name (no guessing).
    if formula and not MIXTURE_FORMULA_RE.search(formula) and "·" not in formula:
        data = _get_json(f"{BASE}/name/{urllib.parse.quote(formula)}/cids/JSON")
        if data:
            for cid in data.get("IdentifierList", {}).get("CID", [])[:5]:
                syn_data = _get_json(f"{BASE}/cid/{cid}/synonyms/JSON")
                synonyms = (syn_data or {}).get("InformationList", {}).get(
                    "Information", [{}])[0].get("Synonym", [])
                lowered = {s.lower() for s in synonyms}
                name_hit = any(v.lower() in lowered for v in _name_variants(name))
                if not name_hit:
                    continue
                candidates = _cas_candidates(synonyms)
                if len(candidates) == 1:
                    return {"status": "OK", "cas": candidates[0], "cid": cid,
                            "pubchem_formula": "",
                            "note": "formula-fallback + name-verified"}
                if len(candidates) > 1:
                    return {"status": "AMBIGUOUS", "cas": "", "cid": cid,
                            "pubchem_formula": "",
                            "note": "candidates: " + ", ".join(candidates)}
    return {"status": "MIXTURE_OR_NO_MATCH", "cas": "", "cid": 0,
            "pubchem_formula": "", "note": "no PubChem name/formula match"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    here = Path(__file__).resolve().parent.parent
    default_file = here / "assets" / "docs" / "common_compounds.json"
    ap.add_argument("--file", type=Path, default=default_file,
                    help=f"corpus JSON to process (default: {default_file.name})")
    ap.add_argument("--write", action="store_true",
                    help="write results back (default: dry run)")
    ap.add_argument("--limit", type=int, default=0,
                    help="only process first N entries")
    ap.add_argument("--only", type=str, default="",
                    help="process entries whose name matches '|'-separated substrings")
    ap.add_argument("--refresh", action="store_true",
                    help="re-query entries that already carry a CAS")
    ap.add_argument("--set", action="append", default=[], metavar="NAME=CAS",
                    help="manual override applied before lookup (repeatable; "
                         "use NAME=- to mark a mixture as having no CAS)")
    args = ap.parse_args()

    raw = args.file.read_text(encoding="utf-8")
    entries = json.loads(raw)
    overrides = {}
    for spec in args.set:
        if "=" not in spec:
            sys.exit(f"--set expects NAME=CAS, got: {spec}")
        k, v = spec.split("=", 1)
        if v not in ("-", "none") and not cas_valid(v):
            sys.exit(f"--set CAS {v!r} fails checksum validation")
        overrides[k.lower()] = v

    filters = [s.strip().lower() for s in args.only.split("|") if s.strip()] if args.only else None
    if args.limit:
        entries = entries[: args.limit]

    def _set_cas(e: dict, cas: str) -> None:
        """Insert `cas` right after `name`, preserving all other key order."""
        if "cas" in e:
            e["cas"] = cas
            return
        ordered: dict = {}
        for k, v in e.items():
            ordered[k] = v
            if k == "name":
                ordered["cas"] = cas
        e.clear()
        e.update(ordered)

    changed = 0
    counts: dict[str, int] = {}
    for e in entries:
        if not isinstance(e, dict) or "name" not in e:
            continue
        name = e["name"]
        if filters and not any(f in name.lower() for f in filters):
            continue
        if name.lower() in overrides:
            v = overrides[name.lower()]
            if v in ("-", "none"):
                # Explicitly no CAS (true mixtures/materials): remove any value.
                had = e.pop("cas", None)
                if had:
                    changed += 1
                print(f"PIN-N {name:44s} -> (no CAS: mixture/material)")
                counts["PIN-NONE"] = counts.get("PIN-NONE", 0) + 1
            else:
                _set_cas(e, v)
                changed += 1
                print(f"PIN   {name:44s} -> {v:14s} (verified manual override)")
                counts["PIN"] = counts.get("PIN", 0) + 1
            continue
        if e.get("cas") and not args.refresh:
            counts["KEEP"] = counts.get("KEEP", 0) + 1
            continue
        res = resolve(name, e.get("formula", ""))
        status = res["status"]
        counts[status] = counts.get(status, 0) + 1
        if status == "OK":
            _set_cas(e, res["cas"])
            changed += 1
            print(f"OK    {name:44s} -> {res['cas']:14s} CID {res['cid']:<9} {res['note']}")
        else:
            print(f"{status[:6]:6s} {name:44s} -> {res['note']}")

    print("\n=== Summary ===")
    for k in sorted(counts):
        print(f"  {k:22s} {counts[k]}")
    print(f"  {'entries changed':22s} {changed}")

    if args.write and changed:
        out = json.dumps(entries, indent=2, ensure_ascii=False) + "\n"
        args.file.write_text(out, encoding="utf-8")
        print(f"Wrote {args.file}")
    elif not args.write:
        print("(dry run - rerun with --write to apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check the String Catalogs for each language: missing translations, format
specifiers that differ from English, missing CLDR plural categories, and counts
put in through %@. Standard library only, so CI runs it on Linux. Exit 1 on a
problem. Mark a Swift line `// i18n: not-a-count` to accept a String argument."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# CLDR cardinal plural categories. Other languages must supply "other".
PLURAL_CATEGORIES = {
    "en": {"one", "other"},
    "zh-Hans": {"other"}, "zh-Hant": {"other"}, "ja": {"other"}, "ko": {"other"},
    "vi": {"other"}, "th": {"other"}, "id": {"other"}, "ms": {"other"},
    "tr": {"one", "other"}, "de": {"one", "other"}, "nl": {"one", "other"},
    "sv": {"one", "other"}, "da": {"one", "other"}, "nb": {"one", "other"},
    "fi": {"one", "other"}, "et": {"one", "other"}, "el": {"one", "other"},
    "hu": {"one", "other"}, "bg": {"one", "other"}, "ca": {"one", "other"},
    "it": {"one", "many", "other"}, "es": {"one", "many", "other"},
    "fr": {"one", "many", "other"}, "pt": {"one", "many", "other"},
    "pt-BR": {"one", "many", "other"}, "pt-PT": {"one", "many", "other"},
    "ro": {"one", "few", "other"},
    "pl": {"one", "few", "many", "other"}, "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"}, "be": {"one", "few", "many", "other"},
    "lt": {"one", "few", "many", "other"},
    "cs": {"one", "few", "many", "other"}, "sk": {"one", "few", "many", "other"},
    "sr": {"one", "few", "other"}, "sr-Cyrl": {"one", "few", "other"},
    "sr-Latn": {"one", "few", "other"}, "hr": {"one", "few", "other"},
    "bs": {"one", "few", "other"}, "sl": {"one", "two", "few", "other"},
    "lv": {"zero", "one", "other"}, "ga": {"one", "two", "few", "many", "other"},
    "ar": {"zero", "one", "two", "few", "many", "other"},
}

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])")
SUBST = re.compile(r"%(?:(\d+)\$)?#@(\w+)@")
INT_TYPES = set("dDiuUxXoOcC")
COUNT_WORDS = (
    r"lines?|running|stopped|containers?|images?|volumes?|networks?|hosts?|services?|items?|"
    r"files?|machines?|clusters?|nodes?|workers?|matches|results?|"
    r"cpus|CPUs|operations?|tags?|layers?|variables?|domains?|logins?|seconds?|minutes?|hours?|days?"
)
COUNT_KEY = re.compile(rf"%(?:\d+\$)?@ (?:{COUNT_WORDS})\b")
SWIFT_LITERAL = re.compile(
    r'(?:Text|Label|Button|Toggle|Section|Menu|LocalizedStringKey|LocalizedStringResource|'
    r'String\(localized:|accessibilityLabel|accessibilityValue|help|navigationTitle)\s*\(?\s*"((?:[^"\\]|\\.)*)"'
)
STRING_OF_COUNT = re.compile(
    r"\\\(String\((?:[^()]|\([^()]*\))*?(?:count|total|running|stopped|paused|Count|Total)\b[^()]*\)\)"
)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=OrderedDict)


def known_regions() -> set[str]:
    regions: set[str] = set()
    for pbx in ROOT.glob("*.xcodeproj/project.pbxproj"):
        match = re.search(r"knownRegions = \((.*?)\);", pbx.read_text(encoding="utf-8"), re.S)
        if match:
            regions.update(r for r in re.findall(r'"?([A-Za-z][A-Za-z0-9-]*)"?\s*,', match.group(1)) if r != "Base")
    return regions


def specifiers(text: str, subs: dict | None = None) -> list[str]:
    """Argument types of a format string, in argument order."""
    subs = subs or {}

    def expand(m: re.Match) -> str:
        sub = subs.get(m.group(2), {})
        num = sub.get("argNum") or m.group(1)
        return f"%{num}${sub.get('formatSpecifier', '@')}" if num else f"%{sub.get('formatSpecifier', '@')}"

    found: dict[int, str] = {}
    position = 0
    for match in SPEC.finditer(SUBST.sub(expand, text.replace("%arg", ""))):
        conv = match.group(2)
        if conv == "%":
            continue
        kind = "int" if conv in INT_TYPES else "obj" if conv in "@sS" else "float"
        position = int(match.group(1)) if match.group(1) else position + 1
        found[position] = kind
    return [found[i] for i in sorted(found)]


def units(loc: dict) -> dict[str, str]:
    """Flatten one localization into {variant path: value}."""
    out: dict[str, str] = {}

    def walk(node: dict, prefix: str) -> None:
        if "stringUnit" in node:
            out[prefix] = node["stringUnit"].get("value", "")
        for kind, variants in node.get("variations", {}).items():
            for name, sub in variants.items():
                walk(sub, f"{prefix}/{kind}:{name}")
        for name, sub in node.get("substitutions", {}).items():
            walk(sub, f"{prefix}/sub:{name}")

    walk(loc, "")
    return out


def plural_sets(loc: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    if "plural" in loc.get("variations", {}):
        out[""] = set(loc["variations"]["plural"])
    for name, sub in loc.get("substitutions", {}).items():
        if "plural" in sub.get("variations", {}):
            out[f"/sub:{name}"] = set(sub["variations"]["plural"])
    return out


def english_for(where: str, en_units: dict[str, str]) -> tuple[str, bool]:
    """English text to compare a translation variant with; True if the number may be left out."""
    if where in en_units:
        return en_units[where], where.endswith(("plural:one", "plural:zero", "plural:two"))
    base = re.sub(r"/(plural|device|width):\w+$", "", where)
    for candidate in (base + "/plural:other", base, ""):
        if candidate in en_units:
            return en_units[candidate], where.endswith(("plural:one", "plural:zero", "plural:two"))
    return "", True


def check_catalog(path: Path, languages: set[str], problems: list[str]) -> None:
    data = load(path)
    source = data.get("sourceLanguage", "en")
    rel = path.relative_to(ROOT)
    for key, entry in data.get("strings", {}).items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        locs = entry.get("localizations", {})
        en_loc = locs.get(source) or {"stringUnit": {"value": key}}
        en_units = units(en_loc) or {"": key}
        en_subs = en_loc.get("substitutions", {})
        en_plurals = plural_sets(en_loc)
        if COUNT_KEY.search(key) and not en_plurals:
            problems.append(f"{rel}: int-as-%@: {key!r} (use %lld with plural variants)")
        for lang in sorted(languages - {source}):
            loc = locs.get(lang)
            tr_units = units(loc) if loc else {}
            if not any(v.strip() for v in tr_units.values()):
                problems.append(f"{rel}: missing [{lang}]: {key!r}")
                continue
            for where, value in tr_units.items():
                english, optional = english_for(where, en_units)
                want = specifiers(english, en_subs)
                have = specifiers(value, loc.get("substitutions", {}))
                if have != want and not (optional and all(s in want for s in have)):
                    problems.append(f"{rel}: format [{lang} {where or '.'}]: {key!r}: en {want} vs {have}")
            tr_plurals = plural_sets(loc)
            need = PLURAL_CATEGORIES.get(lang, {"other"})
            for where in en_plurals:
                have_cats = tr_plurals.get(where)
                if have_cats is None and need == {"other"}:
                    continue
                if have_cats is None:
                    problems.append(f"{rel}: plural [{lang}]: {key!r}: English has plural variants, the translation has not")
                elif not need <= have_cats:
                    problems.append(f"{rel}: plural [{lang}]: {key!r}: no {', '.join(sorted(need - have_cats))}")


def check_sources(problems: list[str]) -> None:
    files = sorted(ROOT.glob("App/**/*.swift")) + sorted(ROOT.glob("Packages/*/Sources/**/*.swift"))
    for swift in files:
        for number, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            if "i18n: not-a-count" in line:
                continue
            for literal in SWIFT_LITERAL.findall(line):
                if STRING_OF_COUNT.search(literal):
                    problems.append(f"{swift.relative_to(ROOT)}:{number}: int-as-%@: a count goes in as String: \"{literal}\"")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the String Catalogs for translation gaps.")
    parser.add_argument("catalogs", nargs="*", type=Path, help="catalogs to check (default: all)")
    args = parser.parse_args()
    catalogs = [p.resolve() for p in args.catalogs] or sorted(
        p for p in ROOT.rglob("*.xcstrings") if not {".build", "DerivedData"} & set(p.parts)
    )
    languages = known_regions()
    for path in catalogs:
        for entry in load(path).get("strings", {}).values():
            languages.update(entry.get("localizations", {}))
    problems: list[str] = []
    for path in catalogs:
        check_catalog(path, languages, problems)
    check_sources(problems)
    print("\n".join(problems))
    names = ", ".join(str(p.relative_to(ROOT)) for p in catalogs)
    print(f"checked {names} for {', '.join(sorted(languages))}: {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

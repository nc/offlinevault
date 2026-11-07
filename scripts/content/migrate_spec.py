#!/usr/bin/env python3
"""Rewrites the five-list catalogue-spec.json (zims/models/document_packs/zimit_sites/maps) as the `entries`
shape of SPEC §5 and applies the AUDIT 2026-10-19 corrections. Rerunnable; `--check` compares instead of writing.

    scripts/content/migrate_spec.py [--in catalogue-spec.json] [--out catalogue-spec.json] [--check]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ovpub.spec import TIER_RANK, parse_spec  # noqa: E402

LICENCE_MAP = {
    "CC BY-SA 4.0": "CC-BY-SA-4.0", "CC BY-SA 2.0": "CC-BY-SA-2.0", "Public domain (US Government)": "PD-USGov",
    "Public domain": "PD", "Apache-2.0": "Apache-2.0", "ODbL": "ODbL-1.0",
}

# old id -> (category, dated-name base). Moves and renames found by the audit; WikiMed swaps nopic for maxi.
RENAMES = {
    "zim-wikipedia-medicine": ("wikipedia", "wikipedia_en_medicine_maxi"),
    "zim-military-medicine": ("zimit", "irp.fas.org_en_military-medicine"),
    "zim-ready-gov": ("zimit", "ready.gov_en_all"),
    "zim-factbook": ("other", "theworldfactbook_en_all"),
    "zim-gutenberg-medicine": ("gutenberg", "gutenberg_en_lcc-r"),
    "zim-gutenberg-agriculture": ("gutenberg", "gutenberg_en_lcc-s"),
    "zim-gutenberg-technology": ("gutenberg", "gutenberg_en_lcc-t"),
}
RETITLE = {
    "zim-wikipedia-medicine": ("Wikipedia – Medicine (WikiMed)", "Every WikiProject Medicine article: conditions, drugs, procedures, with images."),
    "zim-ready-gov": ("Ready.gov (FEMA)", "Hazard-by-hazard preparedness guidance, crawled by Kiwix."),
    "zim-gutenberg-medicine": ("Project Gutenberg – Medicine (LCC R)", "Public-domain medical texts (historical; use with current references)."),
    "zim-gutenberg-agriculture": ("Project Gutenberg – Agriculture (LCC S)", "Public-domain farming, gardening and husbandry texts."),
    "zim-gutenberg-technology": ("Project Gutenberg – Technology (LCC T)", "Public-domain engineering, crafts and trades."),
}
EXCLUDE = {
    "zim-wikihow": "CC BY-NC-SA 3.0, and Kiwix no longer publishes a wikiHow ZIM (no entry in the Kiwix library, 2026-10-31); offered from Kiwix if one returns",
    "zim-post-disaster": "zimgit collection without a licence field; holds Hesperian (CC BY-NC-SA) and commercial titles",
    "zim-medicine-set": "zimgit collection; holds Hesperian titles and Ethicon's Wound Closure Manual",
    "zim-water": "zimgit collection; 'Water' and 'Water Treatment' by 'Various' have no licence; EPA sheet moved to docs-field-medicine-water",
    "zim-food-preparation": "zimgit collection; holds the BSA Philmont Trail Cookbook and commercial Dutch-oven cookbooks",
    "zim-knots": "zimgit collection; holds Adamides' Knots and Gibson's Handbook of Knots and Splices (copyrighted)",
    "zim-cd3wd": "compilation of FAO/NGO material, often NC; licence unverified",
    "zim-lowtech": "no licence string on the site; widely reported CC BY-NC-SA",
    "zim-gutenberg-fiction": "Kiwix has no fiction subset; English and American literature ship as zim-gutenberg-lit-english / -american (complete)",
    "zim-fsis-food-safety": "fsis.usda.gov rate-limits the crawler (2026-10-20: 138 of 144 pages failed, 22 navigation pages captured); food-safety guidance ships in the Field Guide until a throttled crawl works",
}
# Not redistributable, so never stored by OfflineVault: the app downloads these from Kiwix's own servers and shows
# them as "From Kiwix" (docs/compete-plan.md, item 6). They sit in the free tier because nothing is charged for them.
FROM_KIWIX = {"zim-ifixit", "zim-medlineplus"}

# `page`+`match` documents resolved by the audit to the file the page links today.
PAGE_URLS = {
    "ready-supply-kit-checklist": "https://www.ready.gov/sites/default/files/2024-05/ready_supply-kit-checklist.pdf",
    "cdc-make-water-safe-during-emergency": "https://www.cdc.gov/water-emergency/media/pdfs/make-water-safe-during-emergency-p.pdf",
    "cdc-use-safe-water-one-pager": "https://www.cdc.gov/water-emergency/media/pdfs/334749-B_UseSafeWater-OnePager-508.pdf",
}
EPA_URL = "https://www.epa.gov/sites/default/files/2015-11/documents/epa816f15003.pdf"
# Crawl seeds that moved since the old spec was written: name -> (seeds, scope). The FSIS emergency page 404s;
# its parent section answers 200 and, with prefix scoping, covers the same guidance.
ZIMIT_SEEDS = {"fsis-food-safety_en": (["https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics"], "https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics")}

# Decided 2026-10-31 (docs/compete-plan.md, Business model): the free app ships the Field Guide, the CDC and FEMA packs,
# the US government manuals and the overview map, so it is useful before anyone pays.
FREE = {"zim-fieldguide", "zim-cdc-emergency", "zim-ready-gov", "docs-us-gov-preparedness", "map-world-low"}

SE = "Stack Exchange contributors; ZIM by Kiwix"
WM = "Wikipedia contributors; ZIM by Kiwix"


def kiwix(id_, tier, category, base, title, description, licence, attribution, role="reference", language="eng", external=False, **extra):
    e = {"id": id_, "kind": "zim", "tier": tier, "role": role, "language": language, "title": title, "description": description,
         "licence": licence, "attribution": attribution, "source": {"kind": "kiwix_external" if external else "kiwix", "category": category, "base": base}}
    e.update(extra)
    return e


def se(id_, tier, site, title, description, role="procedural"):
    return kiwix(id_, tier, "stack_exchange", f"{site}.stackexchange.com_en_all", title, description, "CC-BY-SA-4.0", SE, role)


ADDITIONS = [
    {"id": "zim-fieldguide", "kind": "zim", "tier": "core", "role": "procedural", "language": "eng", "title": "OfflineVault Field Guide",
     "description": "Procedures for water, food, first aid, shelter, fire, power, communications and household hazards, each with its sources.",
     "licence": "CC-BY-SA-4.0", "attribution": "OfflineVault; adapted from Wikipedia and US Government publications (credited per article)",
     "source": {"kind": "built", "builder": "fieldguide", "params": {"guide": "scripts/content/fieldguide"}}},
    se("zim-se-electronics", "core", "electronics", "Electrical Engineering Stack Exchange", "Solar, batteries, radios and repair Q&A."),
    kiwix("zim-nhs-medicines", "core", "zimit", "nhs.uk_en_medicines", "NHS Medicines A–Z", "Plain-language reference for common medicines: doses, interactions, side effects.",
          "OGL-3.0", "NHS; contains public sector information licensed under the Open Government Licence v3.0", role="reference"),
    kiwix("zim-wikibooks", "full", "wikibooks", "wikibooks_en_all_maxi", "Wikibooks", "Open textbooks: first aid, cookbook, outdoor survival, ham radio, electronics.",
          "CC-BY-SA-4.0", "Wikibooks contributors; ZIM by Kiwix", role="procedural"),
    kiwix("zim-wikivoyage", "full", "wikivoyage", "wikivoyage_en_all_maxi", "Wikivoyage", "Regional hazards, borders and consulates for evacuation planning.",
          "CC-BY-SA-4.0", "Wikivoyage contributors; ZIM by Kiwix"),
    kiwix("zim-wikipedia-simple", "full", "wikipedia", "wikipedia_en-simple_all_maxi", "Simple English Wikipedia", "Plain-English encyclopaedia for children and ESL readers, with images.",
          "CC-BY-SA-4.0", WM, role="encyclopaedic"),
    kiwix("zim-wiktionary", "full", "wiktionary", "wiktionary_en_all_nopic", "Wiktionary", "The offline dictionary.", "CC-BY-SA-4.0", "Wiktionary contributors; ZIM by Kiwix"),
    kiwix("zim-wikisource", "full", "wikisource", "wikisource_en_all_nopic", "Wikisource", "Historical manuals and legal texts in the public domain, text only.",
          "CC-BY-SA-4.0", "Wikisource contributors; ZIM by Kiwix"),
    se("zim-se-mechanics", "full", "mechanics", "Motor Vehicle Maintenance Stack Exchange", "Vehicle repair Q&A."),
    se("zim-se-cooking", "full", "cooking", "Seasoned Advice (Cooking Stack Exchange)", "Food safety and preservation Q&A."),
    se("zim-se-bicycles", "full", "bicycles", "Bicycles Stack Exchange", "Fuel-free transport: repair and maintenance."),
    se("zim-se-medicalsciences", "full", "medicalsciences", "Medical Sciences Stack Exchange", "Q&A from the former Health Stack Exchange.", role="reference"),
    se("zim-se-pets", "full", "pets", "Pets Stack Exchange", "Animal care Q&A."),
    se("zim-se-parenting", "full", "parenting", "Parenting Stack Exchange", "Children and family Q&A."),
    se("zim-se-fitness", "full", "fitness", "Physical Fitness Stack Exchange", "Fitness and conditioning Q&A."),
    se("zim-se-woodworking", "full", "woodworking", "Woodworking Stack Exchange", "Hand and power tool woodworking Q&A."),
    se("zim-se-crafts", "full", "crafts", "Arts & Crafts Stack Exchange", "Sewing, knitting and repair crafts Q&A."),
    se("zim-se-lifehacks", "full", "lifehacks", "Lifehacks Stack Exchange", "Household improvisation Q&A."),
    kiwix("zim-gutenberg-military", "full", "gutenberg", "gutenberg_en_lcc-u", "Project Gutenberg – Military science (LCC U)", "Older field and technical manuals.", "PD", "Project Gutenberg"),
    kiwix("zim-milne", "full", "zimit", "milneopentextbooks.org_en_all", "Milne Open Textbooks (SUNY)", "Open textbooks in nursing, biology and more.", "CC-BY-4.0", "Milne Open Textbooks, SUNY; ZIM by Kiwix"),
    kiwix("zim-publicdomainrecipes", "full", "zimit", "publicdomainrecipes.com_en_all", "Public Domain Recipes", "Recipes released into the public domain.", "PD", "publicdomainrecipes.com", role="procedural"),
    kiwix("zim-based-cooking", "full", "zimit", "based.cooking_en_all", "based.cooking", "Simple recipes, public domain.", "PD", "based.cooking contributors", role="procedural"),
    kiwix("zim-gutenberg-geography", "complete", "gutenberg", "gutenberg_en_lcc-g", "Project Gutenberg – Geography and recreation (LCC G)", "Camping and woodcraft classics (Kephart and others).", "PD", "Project Gutenberg"),
    kiwix("zim-gutenberg-lit-english", "complete", "gutenberg", "gutenberg_en_lcc-pr", "Project Gutenberg – English literature (LCC PR)", "Thousands of public-domain novels and stories for morale.", "PD", "Project Gutenberg", role="encyclopaedic"),
    kiwix("zim-gutenberg-lit-american", "complete", "gutenberg", "gutenberg_en_lcc-ps", "Project Gutenberg – American literature (LCC PS)", "Thousands of public-domain novels and stories for morale.", "PD", "Project Gutenberg", role="encyclopaedic"),
    kiwix("zim-es-wikipedia", "complete", "wikipedia", "wikipedia_es_all_nopic", "Wikipedia en español (texto)", "Every Spanish Wikipedia article, text only.", "CC-BY-SA-4.0", WM, role="encyclopaedic", language="spa"),
    kiwix("zim-es-ready-gov", "complete", "zimit", "ready.gov_es_all", "Ready.gov en español (FEMA)", "Hazard-by-hazard preparedness guidance in Spanish.", "PD-USGov", "FEMA; ZIM by Kiwix", role="procedural", language="spa"),
    kiwix("zim-ifixit", "free", "ifixit", "ifixit_en_all", "iFixit repair manuals", "Step-by-step repair guides for tools, vehicles and electronics, with photos.",
          "CC-BY-NC-SA-3.0", "iFixit contributors (CC BY-NC-SA 3.0); ZIM by Kiwix", role="procedural", external=True),
    kiwix("zim-medlineplus", "free", "zimit", "medlineplus.gov_en_all", "MedlinePlus (NIH)", "Consumer health encyclopaedia from the US National Library of Medicine: conditions, drugs, tests.",
          "Mixed", "MedlinePlus, US National Library of Medicine (public domain text); A.D.A.M. Medical Encyclopedia (licensed); ZIM by Kiwix", role="reference", external=True),
]

MILITARY_MANUALS = [  # (id, title, archive item, file, size from the metadata API)
    ("fm-3-05-70-survival-2002", "FM 3-05.70 Survival (US Army, 2002)", "fm-3-05.70-survival-2002", "FM 3-05.70 Survival  2002.pdf"),
    ("fm-21-76-1-survival-evasion-recovery", "FM 21-76-1 Survival, Evasion, and Recovery (1999)", "Fm21-76-1", "Fm21-76-1.pdf"),
    ("navedtra-14295-hospital-corpsman", "Hospital Corpsman, NAVEDTRA 14295 (US Navy)", "Hospital_Corpsman_NAVEDTRA_14295", "Hospital_Corpsman_NAVEDTRA_14295.pdf"),
    ("usphs-ships-medicine-chest-2003", "The Ship's Medicine Chest and Medical Aid at Sea (USPHS, 2003)", "gov.law.usphs.ships.2003", "usphs.ships.2003.pdf"),
    ("sof-medical-handbook-2001", "Special Operations Forces Medical Handbook (2001)", "SOFMH2001", "SOFMH2001.pdf"),
    ("chem-bio-casualties-handbook-2016", "Field Management of Chemical and Biological Casualties, 5th ed. (2016)", "Chembio5thEd2016FullBook", "chembio 5th ed  2016 full book.pdf"),
    ("pediatric-surgery-hostile-environments", "Pediatric Surgery and Medicine for Hostile Environments (Borden Institute)", "PedsFullBook", "PedsFullBook.pdf"),
    ("fm-4-02-17-preventive-medicine-2000", "FM 4-02.17 Preventive Medicine Services (2000)", "fm-4-02.17-preventative-medicine-services-2000", "FM 4-02.17 Preventative Medicine Services  2000.pdf"),
    ("fm-3-25-26-map-reading-land-navigation", "FM 3-25.26 Map Reading and Land Navigation (2001)", "FM3-25x26", "FM3-25x26.pdf"),
    ("fm-3-97-61-military-mountaineering", "FM 3-97.61 Military Mountaineering (2002)", "military-mountaineering-fm-3-97.61-tc-90-6-1", "Military Mountaineering - FM 3-97.61 (TC 90-6-1).pdf"),
    ("fm-5-125-rigging-2001", "FM 5-125 Rigging Techniques, Procedures, and Applications (2001)", "RiggingTechniquesProceduresAndApplicationsFM51252001", "Rigging Techniques, Procedures, And Applications (FM 5-125)(2001).pdf"),
    ("fm-31-70-basic-cold-weather", "FM 31-70 Basic Cold Weather Manual", "milmanual-fm-31-70-basic-cold-weather-survival-manual", "fm_31-70_basic_cold_weather_survival_manual.pdf"),
    ("atp-4-02-11-casualty-response-2026", "ATP 4-02.11 Casualty Response, Tactical Combat Casualty Care and First Aid (March 2026)", "army-techniques-publication-for-casualty-response-tactical-combat-casualty-care-", "Army Techniques Publication for Casualty Response, Tactical Combat Casualty Care and First Aid - ATP 4-02.11 (March 2026).pdf"),
    ("fema-453-shelters-safe-rooms-2006", "FEMA 453 Design Guidance for Shelters and Safe Rooms (2006)", "fema-453-design-guidance-for-shelters-and-safe-rooms-2006", "FEMA 453 Design Guidance For Shelters And Safe Rooms  2006.pdf"),
    ("nuclear-war-survival-skills-1987", "Nuclear War Survival Skills (Kearny, ORNL; 1987 edition)", "NuclearWarSurvivalSkills_201405", "nwss.pdf"),
]


def migrate(old: dict) -> dict:
    entries: list[dict] = []
    excluded = [{"id": i, "reason": r} for i, r in EXCLUDE.items()]

    for z in old["zims"]:
        if z["id"] in EXCLUDE or z["id"] in FROM_KIWIX:
            continue
        m = re.match(r"https://download\.kiwix\.org/zim/([^/]+)/(.+)\.zim$", z["url"])
        category, base = RENAMES.get(z["id"], (m.group(1), m.group(2)))
        title, description = RETITLE.get(z["id"], (z["title"], z["description"]))
        attribution = z.get("attribution", "")
        if "Kiwix" not in attribution:
            attribution = f"{attribution}; ZIM by Kiwix"
        extra = {}
        if z.get("replaces"):
            extra["replacesEntry"] = z["replaces"]
        if z["id"] == "zim-wikipedia-maxi":
            extra["stream"] = True
        entries.append(kiwix(z["id"], z["tier"], category, base, title, description, LICENCE_MAP[z["licence"]], attribution,
                             role=z.get("role", "reference"), language=z.get("language", "eng"), **extra))

    for m in old["models"]:
        entries.append({"id": m["id"], "kind": "model", "tier": m["tier"], "title": m["title"], "description": m["description"],
                        "licence": LICENCE_MAP[m["licence"]], "attribution": m["attribution"], "source": {"kind": "url", "url": m["url"]}})

    for p in old["document_packs"]:
        docs = []
        for d in p["documents"]:
            did = d["file"][:-4]
            if did == "epa-emergency-disinfection-drinking-water":
                continue
            doc = {"id": did, "title": d["title"], "publisher": d["publisher"], "licence": LICENCE_MAP[d["licence"]]}
            if "archive" in d:
                doc["archive"] = {"item": d["archive"], "file": d["archive_file"]}
            elif "url" in d:
                doc["url"] = d["url"]
            else:
                doc["url"] = PAGE_URLS[did]
            if d.get("summary"):
                doc["summary"] = d["summary"]
            docs.append(doc)
        entries.append({"id": p["id"], "kind": "document-pack", "tier": p["tier"], "role": "procedural", "title": p["title"],
                        "description": "FEMA, Army, USDA, CDC and NWS publications. Public domain (17 USC §105).",
                        "licence": "PD-USGov", "attribution": "FEMA; US Army; USDA; CDC; NOAA/NWS",
                        "source": {"kind": "documents", "documents": docs}})

    entries.append({"id": "docs-field-medicine-water", "kind": "document-pack", "tier": "core", "role": "procedural",
                    "title": "Field medicine and water (public-domain documents)",
                    "description": "Public-domain water-treatment sheets; grows as further PD items are verified.",
                    "licence": "PD-USGov", "attribution": "US Environmental Protection Agency",
                    "source": {"kind": "documents", "documents": [
                        {"id": "epa-emergency-disinfection-drinking-water", "title": "Emergency Disinfection of Drinking Water (EPA)", "publisher": "EPA",
                         "licence": "PD-USGov", "url": EPA_URL,
                         "summary": "Boiling and bleach dosing when the water supply is unsafe."}]}})
    entries.append({"id": "docs-us-military-manuals", "kind": "document-pack", "tier": "full", "role": "procedural",
                    "title": "US military and federal manuals (public domain)",
                    "description": "Survival, field medicine, navigation, mountaineering, rigging, cold weather and civil-defence manuals from the Internet Archive's public-domain copies.",
                    "licence": "PD-USGov", "attribution": "US Army; US Navy; US Public Health Service; Borden Institute; FEMA; Oak Ridge National Laboratory",
                    "source": {"kind": "documents", "documents": [
                        {"id": i, "title": t, "publisher": "US Government", "licence": "PD-USGov", "archive": {"item": item, "file": f}}
                        for i, t, item, f in MILITARY_MANUALS]}})

    for s in old["zimit_sites"]:
        if s["id"] in EXCLUDE or s["id"] in FROM_KIWIX or s["id"] == "zim-ready-gov":
            continue
        entries.append({"id": s["id"], "kind": "zim", "tier": s["tier"], "role": s.get("role", "reference"), "language": "eng", "title": s["title"],
                        "description": s["description"], "licence": LICENCE_MAP[s["licence"]], "attribution": s.get("attribution", s["title"].split(" ")[0]),
                        "source": {"kind": "zimit", "name": s["name"], "seeds": ZIMIT_SEEDS.get(s["name"], (s["seeds"], s["scope"]))[0], "scope": ZIMIT_SEEDS.get(s["name"], (s["seeds"], s["scope"]))[1]}})

    for m in old["maps"]:
        extra = {"stream": True} if m["extract"]["maxzoom"] >= 15 else {}
        entries.append({"id": m["id"], "kind": "map", "tier": m["tier"], "title": m["title"], "description": m["description"],
                        "licence": LICENCE_MAP[m["licence"]], "attribution": m["attribution"],
                        "source": {"kind": "map_extract", "maxzoom": m["extract"]["maxzoom"]}, **extra})

    entries.extend(ADDITIONS)
    for e in entries:
        if e["id"] in FREE:
            e["tier"] = "free"
    entries.sort(key=lambda e: (TIER_RANK[e["tier"]], {"zim": 0, "document-pack": 1, "model": 2, "map": 3}[e["kind"]], e["id"]))
    return {
        "_comment": "Intent only: what OfflineVault publishes, per tier, with the licence that permits it. "
                    "scripts/content/publish.py resolves, locks, fetches, builds, signs and uploads. Edit, then `publish.py plan`.",
        "version": old["version"],
        "entries": entries,
        "excluded": excluded,
    }


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="inp", default=str(here / "tests/fixtures/catalogue-spec.v1.json"))
    ap.add_argument("--out", default=str(here / "catalogue-spec.json"))
    ap.add_argument("--check", action="store_true", help="exit 1 when --out differs from what migration produces")
    a = ap.parse_args()
    old = json.loads(Path(a.inp).read_text())
    if "entries" in old:
        sys.exit("input is already in the entries shape")
    new = migrate(old)
    parse_spec(new)
    text = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
    if a.check:
        return 0 if Path(a.out).read_text() == text else 1
    Path(a.out).write_text(text)
    print(f"wrote {a.out}: {len(new['entries'])} entries, {len(new['excluded'])} excluded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

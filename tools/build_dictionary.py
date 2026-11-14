#!/usr/bin/env python3
"""Rebuild the shipped dictionary files from Blizzard game data tables.

Run from the repository root:

    python3 -I tools/build_dictionary.py            # build all four files
    python3 -I tools/build_dictionary.py --offline  # cache only, no network
    python3 -I tools/build_dictionary.py --inspect Map   # show a table's columns

Source: the public DB2 browser wago.tools, which serves the client's own data
tables as CSV per build and locale.  The koKR and enUS exports of each table
are joined by row ID, so every pair is exactly what the two game clients show.

Python 3.9 standard library only.
"""
import argparse
import csv
import datetime
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

BASE = "https://wago.tools"
USER_AGENT = "dictionary-builder/1.0 (python-urllib)"
REQUEST_DELAY = 1.0
RETRIES = 4

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, ".cache", "wago")
DATA_DIR = os.path.join(ROOT, "data")

# Flavor -> products, in priority order (the first product to supply a pair wins
# its position; identical pairs from later products are dropped).
FLAVORS = {
    "classic": ["wow_classic_era", "wow_anniversary", "wow_classic"],
    "retail": ["wow"],
}

csv.field_size_limit(1 << 30)


class MissingTable(Exception):
    pass


class Fetcher:
    def __init__(self, offline=False, log=sys.stderr):
        self.offline = offline
        self.log = log
        self.bytes_downloaded = 0
        self.requests = 0
        self.cache_hits = 0
        self._last = 0.0
        self.missing = []  # (product, table, locale)

    def _get(self, url):
        last_error = None
        for attempt in range(RETRIES):
            wait = REQUEST_DELAY - (time.time() - self._last)
            if wait > 0:
                time.sleep(wait)
            req = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
            try:
                self._last = time.time()
                self.requests += 1
                with urllib.request.urlopen(req, timeout=300) as resp:
                    raw = resp.read()
                    self.bytes_downloaded += len(raw)
                    if resp.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                    return raw
            except urllib.error.HTTPError as e:
                # wago answers 400 for a table/build it does not have.
                if e.code in (400, 404):
                    raise MissingTable(url)
                last_error = e
            except (urllib.error.URLError, OSError, EOFError) as e:
                last_error = e
            time.sleep(2 ** attempt * 2)
        raise RuntimeError("download failed after %d tries: %s (%s)" % (RETRIES, url, last_error))

    def builds(self):
        path = os.path.join(CACHE_DIR, "builds.json")
        if not os.path.exists(path):
            if self.offline:
                raise RuntimeError("--offline but %s is not cached" % path)
            data = self._get(BASE + "/api/builds")
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
        else:
            self.cache_hits += 1
        with open(path, "rb") as f:
            return json.load(f)

    def table(self, product, build, table, locale="enUS"):
        """Rows of one table as a list of dicts, or None when the build lacks it."""
        d = os.path.join(CACHE_DIR, "%s-%s" % (product, build))
        path = os.path.join(d, "%s.%s.csv.gz" % (table, locale))
        marker = path + ".missing"
        if os.path.exists(marker):
            self.cache_hits += 1
            self.missing.append((product, table, locale))
            return None
        if not os.path.exists(path):
            if self.offline:
                raise RuntimeError("--offline but %s is not cached" % path)
            url = "%s/db2/%s/csv?build=%s&locale=%s" % (BASE, table, build, locale)
            self.log.write("  fetch %s %s %s ... " % (product, table, locale))
            self.log.flush()
            os.makedirs(d, exist_ok=True)
            try:
                raw = self._get(url)
            except MissingTable:
                open(marker, "w").close()
                self.log.write("not available\n")
                self.missing.append((product, table, locale))
                return None
            if not raw.strip() or raw.lstrip()[:1] in (b"<", b"{"):
                raise RuntimeError("unexpected non-CSV answer for %s" % url)
            tmp = path + ".tmp"
            with gzip.open(tmp, "wb", compresslevel=6) as f:
                f.write(raw)
            os.replace(tmp, path)
            self.log.write("%d bytes\n" % len(raw))
        else:
            self.cache_hits += 1
        with gzip.open(path, "rt", encoding="utf-8", newline="") as f:
            return list(csv.DictReader(f))


def newest_build(builds, product):
    entries = builds.get(product) or []
    if not entries:
        raise RuntimeError("product %s not in builds list" % product)
    def key(e):
        return tuple(int(x) for x in e["version"].split("."))
    # Newest by build number (last version component), not by creation date:
    # the list also carries re-pushed older builds.
    return max(entries, key=lambda e: (key(e)[-1], key(e)))["version"]

# --------------------------------------------------------------------------
# Name hygiene

HANGUL = re.compile(r"[가-힣]")
LATIN = re.compile(r"[A-Za-z]")
# Developer leftovers in the tables: test rows, unused/deprecated rows, UI markup.
JUNK_EN = re.compile(
    r"\[|\]|<|>|\||\{|\}|_|\$|%[sd]|\\|\t"
    r"|\bDNT\b|\bDND\b|\bNYI\b|\bPH\b|\bQA\b|\bTBD\b|\bREUSE\b|\bDELETE\b|\bDEBUG\b"
    r"|\b(?:zz|ZZ|Zz)\w*|\bOLD\b|\(old\)|\(Old\)|^Old(?=[A-Z])"
    r"|\b[Tt]est(?:ing)?\d*\b|\bTEST\w*"
    r"|UNUSED|\b[Uu]nused\b|DEPRECATED|\b[Dd]eprecated\b|\bDEP\b"
    r"|\b[Pp]laceholder\b|\bDev(?:elopment)?\b|^Monster - |^Transport: |DO NOT USE"
    r"|Devland|\b[Rr]euse\b|^\d+Zone|^S\d\d - |Tuning and Overrides|\bTBD\b"
    r"|^\d+ (?:Epic|Purple|Blue|Green)\b|\(Tracker\)|\bHotfix\b|\bhidden\b|\bPTR\b|\bOverride\b|\bDriver\b"
    r"|\bIndalamar\b|\(cin\)"
    # Scratch rows of the map and loot designers, and rows that only label UI lists.
    r"|\bTEMP\b|\(Old [^)]*\)|WoWEdit|^Testwerk$|^Monster, |^[A-Z]{3} (?:Alliance|Horde) Garrison\b"
    r"|^Allied - |^n/a$|^World of Wardcraft$"
)
# Whole names that are a category label of some client list, not a thing players talk about.
LABEL_NAMES = {
    ("zone", "Continent"), ("zone", "City"), ("zone", "Home Interior"), ("zone", "Islands"),
    ("currency", "DPS"), ("currency", "Tank"), ("currency", "Healer"),
    ("spec", "Initial"), ("spec", "Adventurer"), ("boss", "Affixes"), ("faction", "Guild"),
}
# Headers of the reputation pane (the flag that marks them differs between clients).
LABEL_NAMES |= {("faction", name) for name in (
    "Classic", "The Burning Crusade", "Wrath of the Lich King", "Cataclysm", "Mists of Pandaria",
    "Warlords of Draenor", "Legion", "Battle for Azeroth", "Shadowlands", "Dragonflight",
    "The War Within", "Midnight", "Other", "Inactive")}
# A Korean name shared by this many different English names of one kind is a placeholder
# the translators left in ("임시" on every scratch loot row), not a name.
PLACEHOLDER_SHARE = 8
JUNK_KO = re.compile(r"\[|\]|<|>|\||\{|\}|_|\$|%[sd]|\\|\t|미사용|사용 안 ?함|테스트용|시험용|개발자 땅|\bDNT\b|\bNYI\b")
LATIN_WORD = re.compile(r"[A-Za-z]{4,}")
ROMAN = re.compile(r"^[IVXLC]+$")
SPACES = re.compile(r"\s+")


def clean(text):
    return SPACES.sub(" ", (text or "").replace(" ", " ")).strip()


def good_pair(ko, en):
    if not ko or not en or ko == en:
        return False
    # An untranslated row often differs from the English one only in spelling
    # details, so "has Hangul" is the test for "was translated".
    if not HANGUL.search(ko) or HANGUL.search(en) or not LATIN.search(en):
        return False
    if len(en) > 80 or len(ko) > 80:
        return False
    if JUNK_EN.search(en) or JUNK_KO.search(ko):
        return False
    # Half-translated developer rows keep English words in the Korean name.
    english_words = set(LATIN_WORD.findall(en))
    return not any(w in english_words and not ROMAN.match(w) for w in LATIN_WORD.findall(ko))


# --------------------------------------------------------------------------
# One product -> (kind, korean, english) rows

# Kinds in output order.  The same pair in two kinds is kept once, under the
# kind that comes first in DEDUPE_ORDER (an instance is also an area; a mount
# is also a spell and often an item).
KIND_ORDER = ["class", "spec", "race", "profession", "zone", "subzone", "instance", "boss",
              "faction", "spell", "item", "mount", "currency", "achievement"]
# "instance~" is an instance name from the dungeon journal or the group finder: those lists
# also hold world-boss "instances" named after a continent and raid wings named after a
# boss, so there the zone or boss reading wins.  It is written out as "instance".
DEDUPE_ORDER = ["class", "race", "profession", "spec", "instance", "zone", "boss", "instance~",
                "subzone", "faction", "mount", "currency", "item", "spell", "achievement"]

# Item.ClassID
GEAR = {"2", "4"}                         # weapon, armor
SUPPLIES = {"0", "3", "5", "6", "7", "8"}   # consumable, gem, reagent, ammo, trade goods, enhancement
RETAIL_CURRENT_EXPANSIONS = 2            # newest N ExpansionID values count as "current"

# Evergreen items every flavor talks about that the quality/expansion cuts would lose.
ALWAYS_ITEMS = {"Hearthstone", "Healthstone", "Mythic Keystone", "Jeeves", "Goblin Glider Kit",
                "Drums of Fury", "Tome of the Tranquil Mind", "WoW Token"}

ACHIEVEMENT_ROOTS = {"Dungeons & Raids", "Player vs. Player", "Feats of Strength", "Delves", "Legacy"}
# Not plain "Hidden": in current retail builds that category holds the live upgrade
# currencies (Valorstones, the crests).
# Bookkeeping counters stored as currencies.
CURRENCY_JUNK = re.compile(r"^\d+\.\d|Tracker| - |\(Hidden\)|Refund$|Reset$|Capacity|Knowledge$|^Renown\b")
CURRENCY_SKIP = re.compile(r"Unused|Test|Meta|\(Hidden\)|Virtual|Debug", re.I)


def item_wanted(product, cls, quality, level, expansion, current_expansions):
    """The item filter.  Aim: what players link or name in chat, within ~25k rows per flavor.

    Every product: legendary and artifact items; supplies people trade (consumables, gems,
    reagents, trade goods, enhancements) from common quality up; bags, recipes and
    miscellaneous items (mounts, pets, tokens) from uncommon/rare up.
    Gear is where the bulk is, so it is cut by product:
      wow_classic_era  uncommon+  (vanilla greens are named, traded twink/levelling items)
      wow_anniversary  rare+      (adds the Burning Crusade blues and epics)
      wow_classic      epic, item level >= 463 (Mists of Pandaria endgame; earlier
                       expansions' epics in this client are not current content)
      wow              rare+ of the newest two expansions only
    """
    if quality in (5, 6):
        return True
    if product == "wow":
        current = expansion in current_expansions
        if cls in GEAR:
            return current and quality >= 3
        if cls in SUPPLIES:
            return quality >= 1 and (current or cls in ("5", "7"))
        if cls == "19":                  # profession tools and accessories
            return current and quality >= 2
        if cls in ("1", "15"):
            return current and quality >= 3
        return False
    if product == "wow_classic":
        if cls in GEAR:
            return quality == 4 and level >= 463
        if cls in SUPPLIES:
            return quality >= 1 and level >= 85
        if cls in ("1", "9", "15"):
            return quality >= 3 and level >= 85
        return False
    # Vanilla and Burning Crusade clients.
    if cls in GEAR:
        return quality >= (2 if product == "wow_classic_era" else 3)
    if cls in SUPPLIES:
        return quality >= 1
    if cls in ("1", "9", "11", "12", "13"):   # bag, recipe, quiver, quest, key
        return quality >= 2
    if cls == "15":
        return quality >= 1
    return False


class Product:
    def __init__(self, fetcher, product, build):
        self.f = fetcher
        self.product = product
        self.build = build
        self.rows = []          # (kind, korean, english)
        self.dropped = 0
        self.dropped_rows = []
        self.dropped_labels = 0
        self.dropped_placeholders = []   # (kind, korean, how many English names)

    def table(self, name, locale="enUS"):
        return self.f.table(self.product, self.build, name, locale)

    def both(self, name):
        en = self.table(name, "enUS")
        ko = self.table(name, "koKR")
        if en is None or ko is None:
            return None, None
        return en, {r["ID"]: r for r in ko}

    def add(self, kind, ko, en):
        ko, en = clean(ko), clean(en)
        if (kind.rstrip("~"), en) in LABEL_NAMES:
            self.dropped_labels += 1
        elif good_pair(ko, en):
            self.rows.append((kind, ko, en))
        elif ko and en and ko != en:
            self.dropped += 1
            self.dropped_rows.append((kind, ko, en))

    def add_column(self, kind, table, column, keep=None):
        en, ko = self.both(table)
        if en is None:
            return
        for r in en:
            k = ko.get(r["ID"])
            if k is not None and (keep is None or keep(r)):
                self.add(kind(r) if callable(kind) else kind, k.get(column, ""), r.get(column, ""))

    def collect(self):
        # ChrClasses also has the non-class placeholders "Adventurer" and "Traveler".
        self.add_column("class", "ChrClasses", "Name_lang",
                        lambda r: r["Filename"].upper() not in ("ADVENTURER", "TRAVELER"))
        self.add_column("spec", "ChrSpecialization", "Name_lang")
        self.add_column("spec", "TalentTab", "Name_lang")      # pre-Mists talent trees
        # Playable races only: the table also models NPC body types and skyriding mounts.
        self.add_column("race", "ChrRaces", "Name_lang", lambda r: r["PlayableRaceBit"] != "-1")
        # 11 = primary professions, 9 = secondary skills (also holds racial and riding lines).
        self.add_column("profession", "SkillLine", "DisplayName_lang",
                        lambda r: r["CategoryID"] == "11" or (r["CategoryID"] == "9" and r["DisplayName_lang"] in (
                            "Cooking", "Fishing", "First Aid", "Archaeology", "Riding")))
        # Map.InstanceType: 1 dungeon, 2 raid, 3 battleground, 4 arena.
        instanced = {r["ID"] for r in (self.table("Map") or []) if r["InstanceType"] in ("1", "2", "3", "4")}

        def area_kind(r):
            if r["ParentAreaID"] != "0":
                return "subzone"
            return "instance" if r["ContinentID"] in instanced else "zone"

        self.add_column(area_kind, "AreaTable", "AreaName_lang")
        # UiMap: 1 world, 2 continent, 3 zone.
        self.add_column("zone", "UiMap", "Name_lang", lambda r: r["Type"] in ("1", "2", "3"))
        self.add_column("instance", "Map", "MapName_lang", lambda r: r["ID"] in instanced)
        self.add_column("instance~", "JournalInstance", "Name_lang")
        # LFGDungeons carries the wing names ("Scarlet Monastery - Cathedral").  TypeID 1 dungeon,
        # 2 raid; retail Subtype 3 is hundreds of scenario steps, not places.
        retail = self.product == "wow"
        self.add_column("instance~", "LFGDungeons", "Name_lang",
                        lambda r: r["TypeID"] in ("1", "2") and not (retail and r["Subtype"] not in ("1", "2")))
        self.add_column("boss", "DungeonEncounter", "Name_lang")
        self.add_column("boss", "JournalEncounter", "Name_lang")
        # ReputationFlags bit 0x4: not shown in the reputation pane (profession specialisations,
        # conversion counters, internal monster factions); 0x1000: a header of the pane
        # ("Classic", "Guild", the expansion names).
        self.add_column("faction", "Faction", "Name_lang",
                        lambda r: int(r["ReputationIndex"]) >= 0 and not r["Name_lang"].endswith("(Paragon)")
                        and not int(r.get("ReputationFlags_0") or 0) & 0x1004)
        self.spells()
        self.items()
        self.add_column("mount", "Mount", "Name_lang")
        self.currencies()
        self.achievements()
        self.drop_placeholders()

    def drop_placeholders(self):
        shared = {}
        for kind, ko, en in self.rows:
            shared.setdefault((kind, ko), set()).add(en)
        bad = {key for key, names in shared.items() if len(names) >= PLACEHOLDER_SHARE}
        for kind, ko in sorted(bad):
            self.dropped_placeholders.append((kind, ko, len(shared[(kind, ko)])))
        self.rows = [r for r in self.rows if (r[0], r[1]) not in bad]

    def spells(self):
        """Player-relevant spells only: SpellName has every internal spell of the game."""
        names_en = self.table("SpellName", "enUS")
        names_ko = self.table("SpellName", "koKR")
        if names_en is None or names_ko is None:
            return
        wanted = set()
        lines = {r["ID"]: r for r in (self.table("SkillLine") or [])}
        old_world = self.product in ("wow_classic_era", "wow_anniversary")
        for r in self.table("SkillLineAbility") or []:
            line = lines.get(r["SkillLine"])
            if line is None:
                continue
            cat, name = line["CategoryID"], line["DisplayName_lang"]
            if cat == "7":                      # class and pet abilities
                if name not in ("Internal", "Mounts", "Companions"):
                    wanted.add(r["Spell"])
            elif cat == "9" and "Racial" in name:
                wanted.add(r["Spell"])
            elif cat in ("9", "11") and old_world:
                # Recipes ("Enchant Weapon - Crusader"): asked for by name in vanilla/TBC trade
                # chat.  Later clients have many thousands; their products are in the item rows.
                wanted.add(r["Spell"])
        for r in self.table("Talent") or []:
            wanted.add(r.get("SpellRank_0") or r.get("SpellID") or "0")
            wanted.add(r.get("SpellID") or "0")
        for name in ("SpecializationSpells", "PvpTalent", "TraitDefinition"):
            if name == "TraitDefinition" and self.product != "wow":
                continue
            for r in self.table(name) or []:
                wanted.add(r["SpellID"])
        wanted.discard("0")
        ko = {r["ID"]: r["Name_lang"] for r in names_ko if r["ID"] in wanted}
        for r in names_en:
            if r["ID"] in ko:
                self.add("spell", ko[r["ID"]], r["Name_lang"])

    def items(self):
        en, ko = self.both("ItemSparse")
        base = self.table("Item")
        if en is None or base is None:
            return
        cls = {r["ID"]: r["ClassID"] for r in base}
        expansions = sorted({int(r["ExpansionID"]) for r in en if 0 <= int(r["ExpansionID"]) < 100})
        current = set(expansions[-RETAIL_CURRENT_EXPANSIONS:])
        for r in en:
            k = ko.get(r["ID"])
            if k is None:
                continue
            if r["Display_lang"] in ALWAYS_ITEMS or item_wanted(
                    self.product, cls.get(r["ID"], ""), int(r["OverallQualityID"]),
                    int(r["ItemLevel"]), int(r["ExpansionID"]), current):
                self.add("item", k["Display_lang"], r["Display_lang"])

    def currencies(self):
        cats = {r["ID"]: r["Name_lang"] for r in (self.table("CurrencyCategory") or [])}
        self.add_column("currency", "CurrencyTypes", "Name_lang",
                        lambda r: not CURRENCY_SKIP.search(cats.get(r["CategoryID"], ""))
                        and not CURRENCY_JUNK.search(r["Name_lang"]))

    def achievements(self):
        cats = {r["ID"]: r for r in (self.table("Achievement_Category") or [])}

        def root(cid):
            for _ in range(6):
                parent = cats.get(cid, {}).get("Parent", "-1")
                if parent in ("-1", "0") or parent not in cats:
                    break
                cid = parent
            return cats.get(cid, {}).get("Name_lang", "")

        self.add_column("achievement", "Achievement", "Title_lang", lambda r: root(r["Category"]) in ACHIEVEMENT_ROOTS)


# Kinds that name places and people.  Across clients a thing may move between them (a zone
# that later became an instance map), so they share one "which client named it first" slot.
PRIMARY_KINDS = {"class", "spec", "race", "profession", "zone", "instance", "instance~", "boss", "faction"}


def merge(products, renamed=None):
    """Union of several products' rows, the first product winning ties.

    Where a later client gives another Korean name to an English name an earlier client
    already has (Deadwind Pass, Moonglade: renamed in later expansions), only the earlier
    client's wording is kept: the reader would otherwise get two "official" names with
    nothing to choose by.  Two Korean names inside one client stay (two different items
    called "Thick Hide", the two "Protection" specializations).  `renamed`, a list, receives
    the dropped (kind, korean, english, product) rows.
    """
    best = {}       # (ko, en) -> (dedupe rank, product index, kind)
    owner = {}      # (kind slot, english) -> index of the first product that has the name
    for index, p in enumerate(products):
        for kind, ko, en in p.rows:
            slot = ("primary" if kind in PRIMARY_KINDS else kind, en.casefold())
            if owner.setdefault(slot, index) != index:
                if (ko, en) not in best and renamed is not None:
                    renamed.append((kind.rstrip("~"), ko, en, p.product))
                continue
            cand = (DEDUPE_ORDER.index(kind), index, kind)
            if (ko, en) not in best or cand < best[(ko, en)]:
                best[(ko, en)] = cand
    # Inside one client, too, a place or boss sometimes carries two Korean names (the zone
    # table and the instance table disagree, or an encounter is listed twice).  One is kept:
    # the better-ranked kind, then the row met first.  Specializations are exempt: the two
    # "Protection" trees really are named differently.
    # Subzones follow the same rule among themselves ("The Crossroads" exists in two zones
    # under two Korean names; the older area, the one in the Barrens, comes first).
    def one_name_slot(kind):
        if kind == "subzone":
            return "subzone"
        return "primary" if kind in PRIMARY_KINDS and kind != "spec" else None

    single = {}
    for (ko, en), cand in best.items():
        slot = one_name_slot(cand[2])
        if slot:
            key = (slot, en.casefold())
            if key not in single or cand < best[single[key]]:
                single[key] = (ko, en)
    for (ko, en), cand in list(best.items()):
        slot = one_name_slot(cand[2])
        if slot and single[(slot, en.casefold())][0] != ko:
            del best[(ko, en)]
            if renamed is not None:
                renamed.append((cand[2].rstrip("~"), ko, en, products[cand[1]].product))
    rows = [(kind.rstrip("~"), ko, en, index) for (ko, en), (_, index, kind) in best.items()]
    # Product index before Korean: where clients disagree on a translation, the
    # first product's wording comes first.
    rows.sort(key=lambda r: (KIND_ORDER.index(r[0]), r[2].casefold(), r[2], r[3], r[1]))
    return [(k, ko, en) for k, ko, en, _ in rows]


# --------------------------------------------------------------------------
# Chat commands (GlobalStrings SLASH_<TYPE><n>)

# Tags as the client names them.  SMART_WHISPER is the everyday /w (it also reaches
# Battle.net friends); WHISPER is /cw, character-only.
CHAT_TYPES = ["SAY", "YELL", "PARTY", "GUILD", "OFFICER", "RAID", "RAID_WARNING", "INSTANCE_CHAT",
              "BATTLEGROUND", "SMART_WHISPER", "WHISPER", "REPLY", "EMOTE", "CHANNEL"]
SLASH_TAG = re.compile(r"^SLASH_(.+?)(\d+)$")


def slash_commands(p):
    out = {}
    for locale in ("enUS", "koKR"):
        rows = p.table("GlobalStrings", locale)
        if rows is None:
            return None
        found = {}
        for r in rows:
            m = SLASH_TAG.match(r["BaseTag"])
            if m and m.group(1) in CHAT_TYPES:
                text = clean(r["TagText_lang"]).lower()
                if text.startswith("/") and " " not in text:
                    found.setdefault(m.group(1), []).append((int(m.group(2)), text))
        out[locale] = {t: [c for _, c in sorted(v)] for t, v in found.items()}
    return out


def merge_commands(per_product):
    collected = []
    for chat_type in CHAT_TYPES:
        english, korean, common = [], [], None
        for cmds in per_product:
            en = cmds["enUS"].get(chat_type, [])
            ko = cmds["koKR"].get(chat_type, [])
            if not en and not ko:
                continue
            for c in en:
                if c not in english:
                    english.append(c)
            for c in ko:
                if c not in english and c not in korean:
                    korean.append(c)
            ascii_en = {c for c in en if c.isascii()}
            common = ascii_en if common is None else (common & ascii_en)
        if not english:
            continue
        collected.append((chat_type, english, korean, common))
    rows = []
    for chat_type, english, korean, common in collected:
        # Shortest English spelling every product of the flavor accepts, and that no other
        # chat type lists: some classic clients read /bg as BATTLEGROUND, others as
        # INSTANCE_CHAT, so only /instance says "instance chat" in all of them.
        elsewhere = {c for t, e, _, _ in collected if t != chat_type for c in e}
        pool = [c for c in english if c in common] or english
        pool = [c for c in pool if c not in elsewhere] or pool
        canonical = min(pool, key=lambda c: (len(c), pool.index(c)))
        aliases = [canonical] + [c for c in english if c != canonical] + korean
        rows.append((chat_type, canonical, " ".join(aliases)))
    return rows


# --------------------------------------------------------------------------
# Output

def write_tsv(path, comment_lines, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for line in comment_lines:
            f.write("# " + line + "\n")
        f.write("\t".join(header) + "\n")
        for row in rows:
            f.write("\t".join(row) + "\n")


def build(fetcher, builds, date, out_dir, log):
    summary = {}
    for flavor, product_names in FLAVORS.items():
        products = []
        for name in product_names:
            p = Product(fetcher, name, newest_build(builds, name))
            log.write("%s %s\n" % (name, p.build))
            p.collect()
            products.append(p)
        source = ", ".join("%s %s" % (p.product, p.build) for p in products)

        renamed = []
        rows = merge(products, renamed)
        counts = {}
        for kind, _, _ in rows:
            counts[kind] = counts.get(kind, 0) + 1
        count_text = ", ".join("%s %d" % (k, counts[k]) for k in KIND_ORDER if k in counts)
        path = os.path.join(out_dir, "official_names.%s.tsv" % flavor)
        write_tsv(path, [
            "Official Korean <-> English names of the %s game." % flavor,
            "Generated by tools/build_dictionary.py from Blizzard game data tables (koKR and enUS",
            "client tables joined by row ID). Do not edit by hand; rerun the tool.",
            "Products and builds: " + source,
            "Where a later client renamed something in Korean, the first listed client's name is kept.",
            "Date: " + date,
            "Rows: %d (%s)" % (len(rows), count_text),
        ], ["kind", "korean", "english"], rows)

        commands = [c for c in (slash_commands(p) for p in products) if c]
        command_rows = merge_commands(commands)
        cpath = os.path.join(out_dir, "chat_commands.%s.tsv" % flavor)
        write_tsv(cpath, [
            "Chat slash commands of the %s game: every spelling the enUS and koKR clients accept." % flavor,
            "Generated by tools/build_dictionary.py from Blizzard game data tables (GlobalStrings",
            "SLASH_<chat_type><n>). Do not edit by hand; rerun the tool.",
            "chat_type is the client's own tag: SMART_WHISPER is /w, WHISPER is /cw (character only).",
            "canonical is the shortest English spelling every listed product accepts and no other chat type uses.",
            "Products and builds: " + source,
            "Date: " + date,
            "Rows: %d" % len(command_rows),
        ], ["chat_type", "canonical", "aliases"], command_rows)

        summary[flavor] = {
            "source": source, "rows": len(rows), "counts": counts, "commands": len(command_rows),
            "per_product": {p.product: len(p.rows) for p in products},
            "dropped_junk": sum(p.dropped for p in products),
            "dropped_labels": sum(p.dropped_labels for p in products),
            "placeholders": [(p.product,) + x for p in products for x in p.dropped_placeholders],
            "renamed": renamed,
            "junk_rows": [r + (p.product,) for p in products for r in p.dropped_rows],
            "files": {os.path.relpath(x, ROOT): os.path.getsize(x) for x in (path, cpath)},
        }
    return summary


def report(fetcher, summary, out=sys.stdout):
    for flavor, s in summary.items():
        out.write("\n[%s] %s\n" % (flavor, s["source"]))
        out.write("  official names: %d rows\n" % s["rows"])
        for kind in KIND_ORDER:
            if kind in s["counts"]:
                out.write("    %-12s %6d\n" % (kind, s["counts"][kind]))
        out.write("  chat commands: %d rows\n" % s["commands"])
        out.write("  rows dropped as test/unused/markup/untranslated-looking: %d\n" % s["dropped_junk"])
        out.write("  rows dropped as list labels: %d\n" % s["dropped_labels"])
        out.write("  placeholder Korean names dropped: %d\n" % len(s["placeholders"]))
        for product, kind, ko, n in s["placeholders"]:
            out.write("    %s %s %s (%d English names)\n" % (product, kind, ko, n))
        out.write("  second Korean names for one English name dropped: %d\n" % len(s["renamed"]))
        for path, size in s["files"].items():
            out.write("  %s  %d bytes\n" % (path, size))
    missing = sorted({(p, t) for p, t, _ in fetcher.missing})
    out.write("\nTables not available (skipped):\n")
    for p, t in missing:
        out.write("  %s: %s\n" % (p, t))
    if not missing:
        out.write("  none\n")
    out.write("\nNetwork this run: %d requests, %d bytes; %d cache hits\n"
              % (fetcher.requests, fetcher.bytes_downloaded, fetcher.cache_hits))


def inspect(fetcher, builds, table):
    for flavor, products in FLAVORS.items():
        for product in products:
            build = newest_build(builds, product)
            rows = fetcher.table(product, build, table, "enUS")
            print("== %s %s %s: %s" % (product, build, table,
                  "missing" if rows is None else "%d rows" % len(rows)))
            if rows:
                print("   " + ",".join(rows[0].keys()))
                for r in rows[:2]:
                    print("   " + json.dumps(list(r.values()), ensure_ascii=False)[:300])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="use cached tables only")
    ap.add_argument("--date", default=datetime.date.today().isoformat(), help="date for the file headers")
    ap.add_argument("--out", default=DATA_DIR, help="output directory (default: data/)")
    ap.add_argument("--dropped", metavar="FILE", help="also write every dropped row to this file, for review")
    ap.add_argument("--inspect", metavar="TABLE", nargs="+", help="print columns and sample rows of tables")
    args = ap.parse_args()
    fetcher = Fetcher(offline=args.offline)
    builds = fetcher.builds()
    if args.inspect:
        for t in args.inspect:
            inspect(fetcher, builds, t)
        return 0
    summary = build(fetcher, builds, args.date, args.out, sys.stderr)
    report(fetcher, summary)
    if args.dropped:
        with open(args.dropped, "w", encoding="utf-8", newline="\n") as f:
            for flavor, s in summary.items():
                for kind, ko, en, product in s["renamed"]:
                    f.write("\t".join((flavor, "renamed", product, kind, ko, en)) + "\n")
                for kind, ko, en, product in s["junk_rows"]:
                    f.write("\t".join((flavor, "junk", product, kind, ko, en)) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

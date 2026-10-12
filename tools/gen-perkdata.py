#!/usr/bin/env python3
# gen-perkdata.py - generates mod/SWGRCouch/Scripts/perkdata.lua, the static perk catalog of the RACE SETUP step 5
# "RACERS" (notes/design/vehicle-step-v2.md §4.3, §4.4, §5.3 and review corrections RC-2, RC-4, RC-8).
#
# Usage (always python3 -I):
#   python3 -I tools/gen-perkdata.py <src dir> <png root> <out.lua> <summary.txt> [<asset-list.txt>]
#       src dir   work/decoded/perks: abilities.json, affixes.json, styles.json, vbds.json (the perks-loadout research
#                 extracts, copied verbatim; py/ holds the research scripts that made them) + extra.json (below);
#                 raw/ (optional) = the cue4cli decodes behind the hand-written upgrade table (GfnVehicleUIConfig,
#                 VU_* upgrade definitions, TNS_Upgrade_Battery_* tunesets), checked when present
#       png root  work/png (every export under it is searched), one export (work/png/perks) or its Textures folder
#       asset list notes/asset-list.txt (default: ../notes/asset-list.txt next to this tools/ folder)
#   python3 -I tools/gen-perkdata.py --extract-extra <cue4cli json root>/Griffin/Content/Griffin <src dir>/extra.json
#       writes extra.json from a cue4cli json dump of the paks (PL §8 command): the raw rich-text descriptions the
#       research extracts strip (affix faulty texts, traits, styles) and the 4 mystery-interaction affixes, which live
#       outside Vehicles/Common/Upgrades/Affixes and are therefore missing from affixes.json.
#
# Rules kept from the design (FG gen_garagedata.py is the base, CF validate_presets.py the kit check):
# - Lua never reads a soft pointer (ARCHITECTURE rev 0.5.1): every texture, class and asset path is a static string
#   from the decoded data. Textures are stored relative to D.TEX without the ".Object" suffix; perks.lua expands
#   rel -> D.TEX .. rel .. "." .. rel:match("[^/]+$"). Class/object paths (cls, path, build) are stored in full.
# - A path is never derived from an asset name: names the extracts give without a folder are resolved through the
#   PNG export and the asset list (exact file names), and must exist in the PNG export.
# - In-game strings are ASCII plus "·" (vehicle-step-v2 §3.9): known typographic characters are mapped, anything
#   else fails the run.
# - Every check failure exits 1 and leaves the previous out.lua untouched (the summary is written either way).
import collections, glob, json, os, re, shutil, subprocess, sys, tempfile

DATA_VERSION = "CL382493 2026-10-09"   # source paks (hotfix) and decode date of the research extracts
TEX = "/Game/Griffin/UI/Library/Textures/"
TEXFS = "Griffin/Content/Griffin/UI/Library/Textures/"
SIZE_TARGET = 200 * 1024               # vehicle-step-v2 §5.3 target: over it is a summary warning
SIZE_LIMIT = 400 * 1024                # sanity cap: over it fails

# ====================================================================================================== --extract-extra
def extract_extra(root, out):
    """Raw (markup) texts and the mystery affixes from a cue4cli json dump; see the file header."""
    def load(f):
        try:
            return json.load(open(f, encoding="utf-8"))
        except Exception:
            return []
    def txt(v):
        return (v.get("LocalizedString") or v.get("SourceString") or "") if isinstance(v, dict) else ""
    def params(p, keys):
        d = {}
        for k in keys:
            for kv in p.get(k) or []:
                d[kv["Key"]] = str(kv["Value"]) + ("%" if "Percent" in k else "")
        return d
    def objname(v):
        return re.sub(r"^.*'(.*)'$", r"\1", v.get("ObjectName", "")) if isinstance(v, dict) else ""
    cfg = load(os.path.join(root, "Vehicles/Common/Upgrades/DA_VehicleUpgradeConfig.json"))[0]["Properties"]
    fam = {}
    for i, f in enumerate(cfg["AffixFamilyLists"]):
        lst = f["AffixList"]
        for j, a in enumerate(lst):
            fam[objname(a)] = [i, j, len(lst)]
    res = {"affixes": {}, "myst": [], "traits": {}, "styles": {}}
    files = sorted(glob.glob(os.path.join(root, "Vehicles/Common/Upgrades/Affixes/**/*.json"), recursive=True))
    myst = sorted(glob.glob(os.path.join(root, "Narrative/MysteryInteractions/Affixes/*.json")))
    for f in files + myst:
        for e in load(f):
            if e.get("Type") != "AffixPassiveConfig":
                continue
            p = e.get("Properties", {})
            row = {"raw": txt(p.get("PlayerFacingDescription")), "rawFaulty": txt(p.get("FaultyPlayerFacingDescription")),
                   "params": params(p, ("IntProperties", "PercentProperties")),
                   "faultyParams": params(p, ("FaultyIntProperties", "FaultyPercentProperties"))}
            res["affixes"][e["Name"]] = row
            if f in myst:
                res["myst"].append({
                    "name": e["Name"], "package": e.get("Package", ""), "title": txt(p.get("PlayerFacingName")),
                    "rarity": p.get("Rarity", "EGfnRarity::Lowest").split("::")[-1],
                    "iconPath": (p.get("Icon") or {}).get("AssetPathName", ""),
                    "largeIconPath": (p.get("LargeIcon") or {}).get("AssetPathName", ""),
                    "family": [fam[e["Name"]]] if e["Name"] in fam else None,
                    "unlockedBy": (p.get("UnlockedBy") or {}).get("TagName", "")})
    for f in glob.glob(os.path.join(root, "Gameplay/Passives/*.json")):
        for e in load(f):
            if e.get("Type") == "CharacterTrait":
                p = e.get("Properties", {})
                res["traits"][e["Name"]] = {"raw": txt(p.get("PlayerFacingDescription")), "params": params(
                    p, ("DescriptionIntParameters", "DescriptionPercentParameters", "IntProperties", "PercentProperties"))}
    for f in glob.glob(os.path.join(root, "Gameplay/**/RacerStyles/*.json"), recursive=True):
        for e in load(f):
            if e.get("Type") == "RacerStyle":
                res["styles"][e["Name"]] = {"raw": txt((e.get("Properties") or {}).get("PlayerFacingDescription"))}
    json.dump(res, open(out, "w", encoding="utf-8"), indent=1, sort_keys=True, ensure_ascii=False)
    print("extra.json: %d affixes (%d mystery), %d traits, %d styles -> %s" % (
        len(res["affixes"]), len(res["myst"]), len(res["traits"]), len(res["styles"]), out))

if len(sys.argv) == 4 and sys.argv[1] == "--extract-extra":
    extract_extra(sys.argv[2], sys.argv[3])
    sys.exit(0)

# ====================================================================================================== arguments
if len(sys.argv) not in (5, 6):
    sys.exit("usage: gen-perkdata.py <src dir> <png root> <out.lua> <summary.txt> [<asset-list.txt>]\n"
             "       gen-perkdata.py --extract-extra <json root> <out extra.json>")
SRC, PNGROOT, OUT, SUMMARY = sys.argv[1:5]
ASSETLIST = sys.argv[5] if len(sys.argv) == 6 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "notes", "asset-list.txt")

def jload(name):
    return json.load(open(os.path.join(SRC, name), encoding="utf-8"))

AFX_JSON = jload("affixes.json")
ABL_JSON = jload("abilities.json")
STY_JSON = jload("styles.json")
VBD = {v["name"]: v for v in jload("vbds.json")}
EXTRA = jload("extra.json")

PROBLEMS = []   # fatal: every entry fails the run
NOTES = []      # summary only

def fail(fmt, *a):
    PROBLEMS.append(fmt % a if a else fmt)

# ====================================================================================================== text helpers
# Typographic characters the decoded English text uses, mapped to the ASCII the in-game fonts are proven with.
CHARMAP = {"\u2019": "'", "\u2018": "'", "\u201c": '"', "\u201d": '"', "\u2013": "-", "\u2014": "-", "\u2212": "-",
           "\u00d7": "x", "\u2026": "...", "\u00a0": " ", "\u200b": "", "\u00ae": "", "\u2122": ""}
MAPPED = collections.Counter()

def clean(s, where):
    """ASCII (plus the middle dot) single-line text; anything unknown fails the run."""
    s = s or ""
    for k, v in CHARMAP.items():
        if k in s:
            MAPPED[repr(k)] += s.count(k)
            s = s.replace(k, v)
    s = re.sub(r"[\r\n\t]+", " ", s)
    s = re.sub(r" {2,}", " ", s).strip()
    bad = sorted({c for c in s if (ord(c) > 126 and c != "\u00b7") or ord(c) < 32})
    if bad:
        fail("non-ASCII %s in %s: %r", bad, where, s[:80])
    return s

def fill(raw, params):
    return re.sub(r"\{([A-Za-z0-9_]+)\}", lambda m: str(params.get(m.group(1), m.group(0))), raw or "")

def plain(rich):
    s = re.sub(r"<widget[^>]*/>", "", rich or "")
    s = re.sub(r"<[A-Za-z0-9]+>([^<]*)</>", r"\1", s)
    s = re.sub(r"<[^>]+>", "", s)
    return re.sub(r"\s+", " ", s).strip()

def norm(s):
    return re.sub(r"\s+", " ", s or "").strip().rstrip(".").lower()

WIDGET_IDS = collections.defaultdict(set)   # rich-text widget id -> where it is used ("ability", "trait", ...)

def rich_text(raw, params, where, kind, plain_ref=None):
    """Filled game markup; checks that no {param} is left and that it matches the extract's plain text."""
    r = clean(fill(raw, params), where)
    left = re.findall(r"\{[A-Za-z0-9_]+\}", r)
    if left:
        fail("unfilled %s in %s", left, where)
    for w in re.findall(r'<widget id="([^"]+)"/>', r):
        WIDGET_IDS[w].add(kind)
    if plain_ref is not None and norm(plain(r)) != norm(plain_ref):
        NOTES.append("text mismatch %s: rich=%r plain=%r" % (where, plain(r)[:70], plain_ref[:70]))
    return r

def upper_name(s, where):
    return clean(s, where).upper()

# ====================================================================================================== texture index
class Textures:
    """Texture files by path relative to TEX (no extension): the PNG exports and the asset list."""
    def __init__(self, png_root, asset_list):
        self.png, self.assets = set(), set()
        roots = []
        if os.path.isdir(os.path.join(png_root, "Icons")) or os.path.isdir(os.path.join(png_root, "Content")):
            roots.append(png_root)
        for d in [png_root] + sorted(glob.glob(os.path.join(png_root, "*"))):
            t = os.path.join(d, TEXFS)
            if os.path.isdir(t):
                roots.append(t)
        self.roots = roots
        for r in roots:
            for f in glob.glob(os.path.join(r, "**", "*.png"), recursive=True):
                self.png.add(os.path.relpath(f, r)[:-4].replace(os.sep, "/"))
        if os.path.exists(asset_list):
            for line in open(asset_list, encoding="utf-8", errors="replace"):
                p = line.rstrip("\n").split("\t")[-1]
                if p.startswith(TEXFS) and p.endswith(".uasset"):
                    self.assets.add(p[len(TEXFS):-7])
        self.byname = collections.defaultdict(set)
        for rel in self.png | self.assets:
            self.byname[rel.rsplit("/", 1)[-1]].add(rel)

    def rel(self, objpath, where):
        """'/Game/.../Textures/Icons/X/T.T' -> 'Icons/X/T' (checked against the PNG export)."""
        if not objpath:
            return None
        m = re.match(r"^" + re.escape(TEX) + r"([A-Za-z0-9_/]+)/([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$", objpath)
        if not m or m.group(2) != m.group(3):
            fail("bad texture path %r (%s)", objpath, where)
            return None
        return self.need(m.group(1) + "/" + m.group(2), where)

    def find(self, name, folder, where, optional=False):
        """A texture known by name only: the file with exactly that name in <folder> (large art has its own folder;
        T_UI_AFX_Afterburner_RefillOnLanding_V1_Icn exists in both Icons/Affixes and LargeAffixIcons)."""
        if not name:
            return None
        cands = self.byname.get(name, set())
        pick = [c for c in cands if c.rsplit("/", 1)[0] == folder]
        if len(pick) != 1:
            if not optional:
                fail("texture %s not found (or ambiguous: %s) for %s", name, sorted(cands), where)
            return None
        if optional and pick[0] not in self.png:
            return None
        return self.need(pick[0], where)

    def need(self, rel, where):
        if rel not in self.png:
            fail("texture %s (%s) is not in the PNG export%s", rel, where,
                 " (asset list has it)" if rel in self.assets else "")
        return rel

TX = Textures(PNGROOT, ASSETLIST)
if not TX.roots:
    sys.exit("no PNG export found under %s" % PNGROOT)
ASSET_FILES = set()
if os.path.exists(ASSETLIST):
    for line in open(ASSETLIST, encoding="utf-8", errors="replace"):
        p = line.rstrip("\n").split("\t")[-1]
        if p.startswith("Griffin/Content/Griffin/") and p.endswith(".uasset"):
            ASSET_FILES.add("/Game/Griffin/" + p[len("Griffin/Content/Griffin/"):-7])
else:
    NOTES.append("asset list %s missing: object paths only checked for form" % ASSETLIST)

def objpath(pkg, where, cls=False):
    """'/Game/X/Name' -> '/Game/X/Name.Name' (or 'Name_C' for a Blueprint class), checked against the asset list."""
    m = re.match(r"^/Game/[A-Za-z0-9_/]+/([A-Za-z0-9_]+)$", pkg or "")
    if not m:
        fail("bad object path %r (%s)", pkg, where)
        return None
    if ASSET_FILES and pkg not in ASSET_FILES:
        fail("%s (%s) is not in the asset list", pkg, where)
    return pkg + "." + m.group(1) + ("_C" if cls else "")

# ====================================================================================================== upgrade parts
# EVehiclePartSlot order. Names: GfnVehicleUIConfig.PartStatNames (stat), VU_<vu>_10.PlayerFacingName (part), icons
# GfnVehicleUIConfig.PartStatIcons (decoded 2026-10-09). Effects: perks-loadout.md §1.4 [V]. `needs`/`partly` = §4.3.
STATS = [
    {"key": "Cornering", "vu": "RepulsorGrip", "name": "CORNERING", "part": "REPULSOR GRIP", "art": "Cornering",
     "lv10": "TURN RADIUS -40% AT LEVEL 10 (PODS -32%)",
     "desc": "More grip and less side drag for tighter turns.",
     "rich": "More grip and less side drag for tighter turns."},
    {"key": "Acceleration", "vu": "FuelInjector", "name": "AFTERBURNER", "part": "FUEL INJECTOR", "art": "Acceleration",
     "lv10": "THRUST +90% (PODS +150%), AFTERBURNER TOP SPEED +25 MPH AT LEVEL 10",
     "desc": "More thrust at every speed, a stronger Afterburner and stronger brakes.",
     "rich": 'More thrust at every speed, a stronger <widget id="Afterburner"/><H1>Afterburner</> and stronger brakes.'},
    {"key": "Resilience", "vu": "StructuralBracing", "name": "RESILIENCE", "part": "STRUCTURAL BRACING",
     "art": "Resilience", "lv10": "IMPACT YANK -95%, EXPLOSION OFFSET -80% AT LEVEL 10", "partly": "critmalf",
     "desc": "Shrugs off impacts and explosions, shortens conditions and slows the build-up of Critical Malfunctions.",
     "rich": 'Shrugs off impacts and explosions, shortens conditions and slows the build-up of <widget '
             'id="CritMalfunction"/><H1>Critical Malfunctions</>.'},
    {"key": "Boost", "vu": "TurboJetManifold", "name": "RAMJET", "part": "TURBOJET MANIFOLD", "art": "Boost",
     "lv10": "RAMJET ACCELERATION +60%, TOP SPEED +50 MPH (PODS +150) AT LEVEL 10", "needs": "ramjet",
     "desc": "More Ramjet acceleration and Ramjet top speed.",
     "rich": 'More <widget id="Ramjet"/><H1>Ramjet</> acceleration and <H1>Ramjet</> top speed.'},
    {"key": "AbilityUsage", "vu": "PowerCell", "name": "BATTERY", "part": "POWER CELL", "art": "Battery",
     "lv10": "ENERGY 3 + 13 = 16 AT LEVEL 10",
     "desc": "More Energy for Abilities: 3 plus the Power Cell bonus.",
     "rich": 'More <widget id="Energy"/><H1>Energy</> for <widget id="Ability"/><H1>Abilities</>: 3 plus the Power '
             'Cell bonus.'},
    {"key": "Advanced", "vu": "Advanced", "name": "ADVANCED", "part": "VECTOR SERVO", "art": "Advanced",
     "lv10": "THE CLASS MOVE AT FULL STRENGTH AT LEVEL 10",
     "desc": "Improves the class move: Drift, Kinetic Burst, Knife Edge or Air Brake.",
     "rich": "Improves the class move: <H1>Drift</>, <H1>Kinetic Burst</>, <H1>Knife Edge</> or <H1>Air Brake</>."},
]
# GfnVehicleUIConfig.AdvancedPartStatNames, by EVehicleArchetype (Car 0, Plane 1, Bike 2, Skimmer 3); effects §1.4
ADVANCED = {0: "DRIFT", 1: "AIR BRAKE", 2: "KINETIC BURST", 3: "KNIFE EDGE"}
ADVANCED_DESC = {0: "Stronger Drift: more drift intent and a tighter drift turn.",
                 1: "Stronger Air Brake: more grip, drag and turn while air braking.",
                 2: "Stronger Kinetic Burst: the energy brake charges faster and grips harder.",
                 3: "Stronger Knife Edge: more grip, drag and turn on the knife edge."}
BATTERY = [0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13]   # TNS_Upgrade_Battery_NN energy bonus per level (base 3), PL §1.4
STACKS = [0, 0, 2, 3, 4, 5, 6, 7, 9, 11, 13]    # VU_*.StacksToApply per level (of 13), PL §1.4
for i, s in enumerate(STATS):
    s["icon"] = TX.need("Icons/BuildStats/T_UI_BuildStats_%s_Icn" % s["art"], "STATS[%d]" % i)
    s["large"] = TX.need("Icons/BuildStats/LargeBuildStatIcons/T_UI_BuildStat_%s_Lg_Icn" % s["art"], "STATS[%d]" % i)
    for lv in range(11):
        n = "001" if lv == 1 else "%02d" % lv
        objpath("/Game/Griffin/Vehicles/Common/Upgrades/UpgradeDefinitions/VU_%s_%s" % (s["vu"], n), "STATS[%d]" % i)

RAW = os.path.join(SRC, "raw")
RAW_CHECKED = []
if os.path.isdir(RAW):
    # the hand-written table against the decodes: names, icons, slots, per-level power / stacks / battery bonus
    def rawprops(rel):
        for e in json.load(open(os.path.join(RAW, rel), encoding="utf-8")):
            if e.get("Properties") is not None:
                return e["Properties"]
        return {}
    def txt(v):
        return (v.get("LocalizedString") or v.get("SourceString") or "") if isinstance(v, dict) else ""
    ui = rawprops("UI/Config/GfnVehicleUIConfig.json")
    names = {kv["Key"].split("::")[-1]: plain(txt(kv["Value"])).upper() for kv in ui.get("PartStatNames", [])}
    icons = {kv["Key"].split("::")[-1]: kv["Value"]["AssetPathName"] for kv in ui.get("PartStatIcons", [])}
    adv = {kv["Key"].split("::")[-1]: plain(txt(kv["Value"])).upper() for kv in ui.get("AdvancedPartStatNames", [])}
    for arch, cls in ((0, "Car"), (1, "Plane"), (2, "Bike"), (3, "Skimmer")):
        if adv.get(cls) != ADVANCED[arch]:
            fail("ADVANCED[%d] = %s, GfnVehicleUIConfig says %s", arch, ADVANCED[arch], adv.get(cls))
    for i, s in enumerate(STATS):
        if names.get(s["key"]) != s["name"]:
            fail("STATS[%d].name %s, GfnVehicleUIConfig.PartStatNames says %s", i, s["name"], names.get(s["key"]))
        if TX.rel(icons.get(s["key"]), "STATS icon") != s["icon"]:
            fail("STATS[%d].icon %s, GfnVehicleUIConfig.PartStatIcons says %s", i, s["icon"], icons.get(s["key"]))
        for lv in range(11):
            n = "001" if lv == 1 else "%02d" % lv
            p = rawprops("Vehicles/Common/Upgrades/UpgradeDefinitions/VU_%s_%s.json" % (s["vu"], n))
            where = "VU_%s_%s" % (s["vu"], n)
            if p.get("PartSlot") != "EVehiclePartSlot::" + s["key"]:
                fail("%s: PartSlot %s, STATS says %s", where, p.get("PartSlot"), s["key"])
            if plain(txt(p.get("PlayerFacingName"))).upper() != s["part"]:
                fail("%s: name %s, STATS says %s", where, txt(p.get("PlayerFacingName")), s["part"])
            if (p.get("PowerLevel") or 0) != lv or (p.get("UserFacingStatIncrease") or 0) != lv:
                fail("%s: PowerLevel %s / stat %s", where, p.get("PowerLevel"), p.get("UserFacingStatIncrease"))
            if s["key"] == "AbilityUsage":
                tns = re.sub(r"^.*'(.*)'$", r"\1", (p.get("TunesetToApply") or {}).get("ObjectName", ""))
                bonus = 0
                if tns:
                    t = rawprops("Vehicles/Common/Upgrades/StatTuneSets/%s.json" % tns)
                    ops = [o for o in t.get("Operations", []) if o.get("Property") == "TotalAbilityEnergy"]
                    bonus = ops[0]["IntParam"] if ops else None
                if bonus != BATTERY[lv]:
                    fail("%s: battery bonus %s, BATTERY says %d", where, bonus, BATTERY[lv])
            elif (p.get("StacksToApply") or 0) != STACKS[lv]:
                fail("%s: StacksToApply %s, STACKS says %d", where, p.get("StacksToApply"), STACKS[lv])
            if lv == 10 and TX.rel((p.get("LargeIcon") or {}).get("AssetPathName"), where) != s["large"]:
                fail("%s: LargeIcon differs from STATS[%d].large", where, i)
    RAW_CHECKED.append("STATS names/icons/slots, ADVANCED, per-level PowerLevel, STACKS, BATTERY (66 VU_*, 10 TNS)")
else:
    NOTES.append("raw/ missing: the STATS / ADVANCED / STACKS / BATTERY table is not checked against the decodes")

# ====================================================================================================== abilities
FAM_ORDER = ["Shield", "Surge", "Vent", "Autopilot", "Disruptor", "Mine", "Shockwave", "Repair"]   # §2.5 picker order
CRASH_FAM = "IonBlast"
ABIL = {}
for a in ABL_JSON:
    cls = a["cls"]
    if cls.endswith("_AI_C"):
        continue                                   # AI-only copies (PL §2.2)
    aid = cls[len("BP_Ability_"):-2]
    fam = a["path"].split("/Abilities/")[1].split("/")[0]
    where = "ability " + aid
    desc = clean(a["desc"], where)
    ABIL[aid] = {
        "id": aid, "fam": fam, "alvl": a["level"],
        "from": (a.get("upgradedFrom") or "")[len("BP_Ability_"):-2] or None,
        "name": upper_name(a["name"], where), "desc": desc,
        "rich": rich_text(a.get("rawdesc"), a.get("params") or {}, where, "ability", desc),
        "icon": TX.rel(a.get("iconpath"), where),
        "sub": TX.rel(a.get("subiconpath"), where) if a.get("subiconpath") else None,
        "large": TX.find(a.get("largeicon"), "Icons/Abilities/LargeAbilityIcons", where),
        "cls": objpath(a["path"], where, cls=True), "cfg": a.get("cfgType") or None,
        "energy": a.get("energy"), "crash": fam == CRASH_FAM,
    }
    if not ABIL[aid]["cfg"]:
        fail("ability %s has no config class (RC-4)", aid)
SCRIPT_OBJECTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "work", "script-objects.tsv")
if os.path.exists(SCRIPT_OBJECTS):   # RC-4: perkapply reads EnergyCost from /Script/Griffin.Default__<cfg>
    cdos = set()
    for line in open(SCRIPT_OBJECTS, encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and f[0] == "/Script/Griffin" and f[1].startswith("Default__"):
            cdos.add(f[1][len("Default__"):])
    for x in ABIL.values():
        if x["cfg"] and x["cfg"] not in cdos:
            fail("ability %s: no /Script/Griffin.Default__%s in script-objects.tsv (RC-4)", x["id"], x["cfg"])
else:
    NOTES.append("work/script-objects.tsv missing: the RC-4 config class defaults are not checked")
for x in ABIL.values():
    if x["from"] and x["from"] not in ABIL:
        fail("ability %s upgrades from unknown %s", x["id"], x["from"])
    # tree depth 1..3 (the game's AbilityLevel is 0 / 2 / 3)
    d, p = 1, x
    while p["from"]:
        d, p = d + 1, ABIL[p["from"]]
    x["lvl"] = d
    if {0: 1, 2: 2, 3: 3}.get(x["alvl"]) != d:
        fail("ability %s: AbilityLevel %s does not match its tree depth %d", x["id"], x["alvl"], d)

def tree_order(fam):
    """Base, then each branch (by id) followed by its upgrades: §4.3 (base, branch A, A II, branch B, B II)."""
    kids = collections.defaultdict(list)
    roots = []
    for x in ABIL.values():
        if x["fam"] != fam:
            continue
        (kids[x["from"]] if x["from"] else roots).append(x["id"])
    out = []
    def walk(i):
        out.append(i)
        for k in sorted(kids[i]):
            walk(k)
    for r in sorted(roots):
        walk(r)
    return out

FAMILIES = []
for fam in FAM_ORDER:
    order = tree_order(fam)
    base = ABIL[order[0]]
    FAMILIES.append({"key": fam, "name": base["name"], "icon": base["icon"], "large": base["large"], "order": order})
CRASH = tree_order(CRASH_FAM)
CRASH_INFO = {"key": CRASH_FAM, "name": ABIL[CRASH[0]]["name"], "icon": ABIL[CRASH[0]]["icon"],
              "large": ABIL[CRASH[0]]["large"], "order": CRASH}
EMPTY_ICON = TX.need("Icons/Abilities/T_UI_Ability_Empty_Icn", "EMPTY")

# ====================================================================================================== affixes (parts)
RAR = {"Lowest": 0, "Low": 1, "High": 2, "Highest": 3, "Faulty": 4, "Experimental": 5}
RARITY = ["COMMON", "RARE", "EPIC", "LEGENDARY", "FLAW", "EXPERIMENTAL"]   # PartQualityNames + the two specials
PICK_RANK = {3: 5, 5: 4, 2: 3, 1: 2, 0: 1, 4: 0}   # picker: LEGENDARY first, EXPERIMENTAL, EPIC, RARE, COMMON, FLAW
# Category rules = FG gen_garagedata.py category(): first matching name prefix in this order (longest prefix first),
# Conditions_Cooled* / Conditions_Freeze* -> COOLING, Faulty rarity -> FLAWS, Special/PlaneTests -> POD TRAITS.
# The mystery ladder (Ramming Jet) is in TAKEDOWNS and Particulate Filter (Choke_) in RAMJET, as in FG: that is what
# the §4.3 entry counts (21/17/17/16/4/7/6/12/18/15/53/12) were produced with.
CATS = [  # key, name, keyword glyph (Icons/Keywords/T_UI_Keyword_<x>_Icn), name prefixes, extra flags
    ("afterburner", "AFTERBURNER", "Afterburner", ["Afterburner"], {}),
    ("ramjet", "RAMJET", "Ramjet", ["Ramjet", "Choke"], {"needs": "ramjet"}),
    ("cooling", "COOLING & FROST", "Cooled", ["Cooled", "Frozen"], {}),
    ("surge", "SURGE & OVERCHARGE", "Surge", ["Surging", "Surge", "Overcharged", "Overcharge", "Condition_Surging"], {}),
    ("shield", "SHIELDS", "Shielded", ["Shielded", "FirstPlace"], {}),
    ("takedown", "TAKEDOWNS", "Takedown", ["Takedown", "MYST_Ramjet"], {}),
    ("startland", "START & LANDING", "PerfectLanding", ["PerfectStart", "Ignition", "Landing"], {}),
    ("energy", "ENERGY & ABILITIES", "Battery", ["Energy", "Ability", "LotsOfBattery"], {}),
    ("crash", "CRASH & SYSTEMS", "Crash", ["Crashes", "Crash", "SysMalf", "CritMalf"], {}),
    ("conditions", "CONDITIONS & DRAFT", "Corroded", ["Conditions", "Condition", "Burning", "Concussed", "Concussion",
                                                      "Corrode", "Slipstream", "Slipstreaming"], {}),
    ("flaws", "FLAWS", "SystemMalfunction", [], {"flaws": True}),
    ("pod", "POD TRAITS", "Ramjet", [], {"podOnly": True}),
]
SPEC_CAT_COUNTS = {"afterburner": 21, "ramjet": 17, "cooling": 17, "surge": 16, "shield": 4, "takedown": 7,
                   "startland": 6, "energy": 12, "crash": 18, "conditions": 15, "flaws": 53, "pod": 12}
EXCLUDE = {"AFXCustom_PlaneMemory_Vulnerability", "AFXCustom_Plane_ConditionsProtection"}   # no player text
PLANE_ONLY_EXTRA = {"AFXCustom_Plane_PDay_Unstable"}   # "Only Human": a pod flaw ("not built for flying podracers")

def category(name, folder, rarity):
    if folder == "Special/PlaneTests":
        return "pod"
    if rarity == "Faulty":
        return "flaws"
    body = re.sub(r"^AFX(Custom)?_", "", name)
    for key, _, _, prefixes, _ in CATS:
        for p in sorted(prefixes, key=len, reverse=True):
            if body.startswith(p):
                if key == "conditions" and re.match(r"Conditions?_(Cooled|Freeze)", body):
                    return "cooling"
                return key
    return "conditions"

AFX_DIR = "/Game/Griffin/Vehicles/Common/Upgrades/Affixes/"
rows = [dict(x) for x in AFX_JSON]
for m in EXTRA["myst"]:   # the 4 mystery affixes (Ramming Jet I-III, Fractured Abilities), from extra.json
    fx = EXTRA["affixes"].get(m["name"], {})
    faulty_plain = plain(fill(fx.get("rawFaulty"), fx.get("faultyParams") or {}))
    rows.append({"name": m["name"], "folder": None, "package": m["package"], "title": m["title"],
                 "desc": plain(fill(fx.get("raw"), fx.get("params") or {})), "rawdesc": fx.get("raw", ""),
                 "faulty": faulty_plain, "rarity": m["rarity"], "params": fx.get("params") or {},
                 "iconPath": m["iconPath"], "largeIconPath": m["largeIconPath"], "family": m["family"]})

PARTS = {}
for x in rows:
    n = x["name"]
    if n.startswith("SAFX") or n in EXCLUDE or not (x.get("title") or "").strip():
        continue
    where = "part " + n
    faulty = x["rarity"] == "Faulty"
    fx = EXTRA["affixes"].get(n)
    if fx is None:
        fail("extra.json has no raw texts for %s", n)
        fx = {}
    if faulty:
        desc = clean(x.get("faulty"), where)
        rich = rich_text(fx.get("rawFaulty"), fx.get("faultyParams") or {}, where, "affix", desc)
    else:
        desc = clean(x.get("desc"), where)
        rich = rich_text(x.get("rawdesc"), x.get("params") or {}, where, "affix", desc)
    if not desc:
        fail("%s has no description", n)
    pkg = x.get("package") or (AFX_DIR + ("" if x["folder"] == "." else x["folder"] + "/") + n)
    if "largeIconPath" in x:
        large = TX.rel(x["largeIconPath"], where) if x["largeIconPath"] else None
    else:
        large = TX.find(x.get("largeIcon"), "Icons/Affixes/LargeAffixIcons", where, optional=True)
    fam = x["family"][0] if x.get("family") else None
    PARTS[n] = {
        "id": n, "name": upper_name(x["title"], where), "rarity": RAR[x["rarity"]],
        "cat": category(n, x["folder"], x["rarity"]),
        "fam": fam[0] + 1 if fam else None, "tier": fam[1] + 1 if fam else None, "ntiers": fam[2] if fam else None,
        "faulty": faulty, "planeOnly": x["folder"] == "Special/PlaneTests" or n in PLANE_ONLY_EXTRA,
        "path": objpath(pkg, where), "icon": TX.rel(x.get("iconPath"), where), "large": large,
        "desc": desc, "rich": rich, "params": x.get("params") or {},
    }

# tier ladders: DA_VehicleUpgradeConfig.AffixFamilyLists, numbered 1..52 as in perks-loadout.md §2.3.1 (index + 1)
PART_FAMILIES = {}
for p in PARTS.values():
    if p["fam"]:
        PART_FAMILIES.setdefault(p["fam"], []).append(p)
FAMILY_INFO = {}
for k, lst in sorted(PART_FAMILIES.items()):
    lst.sort(key=lambda p: p["tier"])
    if [p["tier"] for p in lst] != list(range(1, lst[0]["ntiers"] + 1)):
        fail("ladder %d is incomplete: %s", k, [p["id"] for p in lst])
    if len({p["cat"] for p in lst}) != 1:
        fail("ladder %d spans categories %s", k, sorted({p["cat"] for p in lst}))
    keys = set()
    for p in lst:
        keys |= set(p["params"])
    ladder = None
    if len(keys) == 1:
        k1 = keys.pop()
        if all(k1 in p["params"] for p in lst):
            ladder = " / ".join(str(p["params"][k1]) for p in lst)
    FAMILY_INFO[k] = {"name": re.sub(r"\s+[IVX]+$", "", lst[0]["name"]), "tiers": [p["id"] for p in lst],
                      "ladder": ladder}
for k in range(1, max(FAMILY_INFO) + 1):
    if k not in FAMILY_INFO:
        fail("ladder %d has no player-facing tier", k)

# picker lists: one entry per ladder (its top tier) or standalone part; rarity (LEGENDARY first), then name
PART_LIST = collections.OrderedDict((c[0], []) for c in CATS)
for p in PARTS.values():
    if p["fam"] and p["tier"] != p["ntiers"]:
        continue
    PART_LIST[p["cat"]].append(p)
for c in PART_LIST:
    PART_LIST[c].sort(key=lambda p: (-PICK_RANK[p["rarity"]], p["name"], p["id"]))

# ====================================================================================================== traits
# 41 rule traits in 10 groups (CF §3.4.3, display order). Not offered: StartWith* / Plane_* (description only), the
# helpers without text and the duplicates CoolingAtBack_Campaign, BetterTopSpeedWhenNoCrashesDummy,
# EnergyOnEveryOtherAbilityHitB.
TRAIT_GROUPS = [  # key, name, keyword glyph, traits (TRT_ suffixes)
    ("afterburner", "AFTERBURNER", "Afterburner", ["StrongerAfterburner", "AfterburnerLastsLonger",
                                                   "RefillAfterburnerOnOvertake",
                                                   "AfterburnerRefillOnAirtimeAndAdvancedCorner"]),
    ("ramjet", "RAMJET", "Ramjet", ["CriticalRamjetPower", "RamjetExtendedAlarm", "RamjetExtendedAlarmUpgrade",
                                    "RamjetReEngageAfterRelease"]),
    ("cooling", "COOLING", "Cooled", ["ImprovedCooling", "GainCooledWhenInFirstPlace", "GainCooledWhenInPodium",
                                      "CoolingAtBack"]),
    ("surge", "SURGE", "Surge", ["SurgeMoreTopspeed_Trigger", "SurgeTopSpeedSnowball_Trigger", "GainSurgeOnShieldLoss",
                                 "AfterCrashGainSurge", "SurgeWhenSysMalfRecovery"]),
    ("energy", "ENERGY", "Battery", ["NoEnergyGainOverchargeImproved", "AbilitiesReduceAbilityCooldowns",
                                     "EnergyForAbilityHits", "EnergyForOvertakes", "EnergyForTakedowns"]),
    ("takedowns", "TAKEDOWNS", "Takedown", ["SurgeForTakedowns", "SurgeForTakedownsUpgrade"]),
    ("jumps", "JUMPS", "PerfectLanding", ["AfterburnerRefillOnPerfectLanding", "AfterburnerPowerStacksWhenAirborne",
                                          "AllLandingsArePerfect"]),
    ("slipstream", "SLIPSTREAM", "Slipstreaming", ["BetterDrafting", "LongerDrafting", "BiggerDraftingZones"]),
    ("survival", "SURVIVAL", "Crash", ["BetterTopSpeedWhenNoCrashes", "BetterTopSpeedWhenNoCrashesUpgrade",
                                       "OneMoreCrash", "RecoverFromSysMalfFaster", "MalfunctionRepairOnRecovery"]),
    ("heatice", "HEAT & ICE", "Burning", ["StrongerAfterBurnerAndRamjetWhenBurning", "GainBurningWhenRamjet",
                                          "BurningInfiniteRamjetAndAfterburner", "FrozenDoubleDuration",
                                          "FrozenRamjetNoHeat", "OnFrozenGainShield"]),
]
REQUIRES = {"TRT_SurgeTopSpeedSnowball_Trigger": "TRT_SurgeMoreTopspeed_Trigger",            # Feel, Don't Think
            "TRT_AfterburnerPowerStacksWhenAirborne": "TRT_AfterburnerRefillOnPerfectLanding"}  # Potential Energy
GLYPH_FOLDERS = {"Icons/Keywords", "Icons/Affixes", "Icons/BuildStats", "Icons/Abilities"}   # CF §3.4.3 "real glyph"
TR_JSON = STY_JSON["traits"]
TRAITS, TRAIT_ORDER, TRAIT_GROUP_INFO, GLYPH_SWAPS = {}, [], [], []
for gkey, gname, kw, members in TRAIT_GROUPS:
    gicon = TX.need("Icons/Keywords/T_UI_Keyword_%s_Icn" % kw, "trait group " + gkey)
    TRAIT_GROUP_INFO.append({"key": gkey, "name": gname, "icon": gicon})
    for m in members:
        tid = "TRT_" + m
        where = "trait " + tid
        v = TR_JSON.get(tid)
        if not v:
            fail("trait %s not in styles.json", tid)
            continue
        if not (v["tunesets"] or v["effects"] or v["reqs"]):
            fail("trait %s has no rules (description only)", tid)
        fx = EXTRA["traits"].get(tid)
        if fx is None:
            fail("extra.json has no raw text for %s", tid)
            fx = {}
        icon = None
        if v.get("icon"):
            m2 = re.match(r"^" + re.escape(TEX) + r"(.+)/([A-Za-z0-9_]+)\.\2$", v["icon"])
            if m2 and m2.group(1) in GLYPH_FOLDERS and (m2.group(1) + "/" + m2.group(2)) in TX.png:
                icon = m2.group(1) + "/" + m2.group(2)
        if icon is None:   # FPO placeholder, no icon, or a non-glyph texture: the group's keyword glyph (§4.3)
            GLYPH_SWAPS.append("%s (%s) -> %s" % (tid, (v.get("icon") or "-").rsplit("/", 1)[-1].split(".")[0], gicon))
            icon = gicon
        desc = clean(v["desc"], where)
        TRAITS[tid] = {"id": tid, "name": upper_name(v["title"], where), "group": gkey, "desc": desc,
                       "rich": rich_text(fx.get("raw"), fx.get("params") or {}, where, "trait", desc),
                       "icon": icon, "path": objpath("/Game/Griffin/Gameplay/Passives/" + tid, where),
                       "requires": REQUIRES.get(tid)}
        TRAIT_ORDER.append(tid)
rule_traits = sorted(k for k, v in TR_JSON.items() if v["title"] and (v["tunesets"] or v["effects"] or v["reqs"])
                     and k not in ("TRT_CoolingAtBack_Campaign", "TRT_EnergyOnEveryOtherAbilityHitB"))
if sorted(TRAITS) != rule_traits:
    fail("trait groups do not cover the rule traits exactly: missing %s, extra %s",
         sorted(set(rule_traits) - set(TRAITS)), sorted(set(TRAITS) - set(rule_traits)))

# ====================================================================================================== kits (§4.4)
# Style kits, validated like CF validate_presets.py: abilities in slot order Up / Left / Down / Right, the crash
# ability, 4 parts (top tier of each ladder), 3 rule traits. Tune = VBD_PvP_IA_<pilot> levels (Frozen: mod default).
KIT_TABLE = [
    ("Cooling", ["Vent", "Shield", "Surge", "Repair"], "IonBlast_Cooled",
     ["Conditions_Cooled_IncreasedPotency_v4", "Cooled_PowerfulRamjet_v4", "Conditions_CooledLastsLonger_v3",
      "Ramjet_CoolsFaster_v4"], ["ImprovedCooling", "GainCooledWhenInFirstPlace", "GainCooledWhenInPodium"],
     [6, 10, 2, 0, 8, 0]),
    ("Abilities", ["Mine", "Repair", "Shockwave", "Disruptor"], "IonBlast_Overclocked",
     ["Ability_FasterCooldown_v4", "Ability_GainShielded_v2", "Energy_GainSurging", "Cooled_FastAbilityCooldown"],
     ["NoEnergyGainOverchargeImproved", "AbilitiesReduceAbilityCooldowns", "EnergyForAbilityHits"],
     [10, 2, 0, 6, 5, 8]),
    ("Afterburner", ["Surge", "Shield", "Vent", "Autopilot"], "IonBlast",
     ["Afterburner_IncreasedTopSpeed_v4", "Afterburner_MoreDuration_v4", "Afterburner_FasterRecharge_v4",
      "Afterburner_FullFuelIncreasesPower_v4"],
     ["StrongerAfterburner", "AfterburnerLastsLonger", "RefillAfterburnerOnOvertake"], [10, 6, 8, 2, 5, 0]),
    ("Ramjet", ["Surge", "Vent", "Shield", "Autopilot"], "IonBlast_Cooled",
     ["Ramjet_MorePower_v4", "Ramjet_ExtendedAlarm_v4", "Ramjet_HeatReduction_v4", "Ramjet_CriticalResetChance_v3"],
     ["CriticalRamjetPower", "RamjetExtendedAlarm", "RamjetExtendedAlarmUpgrade"], [5, 2, 8, 10, 0, 6]),
    ("Malfunction", ["Repair", "Shield", "Surge", "Vent"], "IonBlast_Shielded",
     ["SysMalf_ShorterMalfunction_v2", "Overcharged_RemoveSysMalf", "SysMalf_PowerfulAfterburner", "SysMalf_GainSurge"],
     ["SurgeWhenSysMalfRecovery", "RecoverFromSysMalfFaster", "MalfunctionRepairOnRecovery"], [0, 8, 5, 2, 6, 10]),
    ("Defence", ["Shield", "Repair", "Surge", "Vent"], "IonBlast_Shielded",
     ["PerfectStart_GainShield_v3", "Ability_GainShielded_v2", "Crash_ReturnWithShield",
      "Shielded_GainOnPerfectLanding_v3"],
     ["BetterTopSpeedWhenNoCrashes", "GainSurgeOnShieldLoss", "OneMoreCrash"], [6, 5, 8, 10, 0, 2]),
    ("Surging", ["Surge_Overtake", "Shield", "Vent", "Autopilot"], "IonBlast",
     ["Condition_Surging_IncreasedPotency_v3", "Surging_AfterburnerMoreDuration_v4", "Surge_GainShielded",
      "Surging_AfterburnerMorePowerful"],
     ["EnergyForOvertakes", "SurgeMoreTopspeed_Trigger", "SurgeTopSpeedSnowball_Trigger"], [0, 8, 2, 6, 10, 5]),
    ("Struggling", ["Autopilot", "Shield", "Surge", "Repair"], "IonBlast",
     ["Crashes_CooledSurgingShieldedWhenOneCrashRemains", "Crash_ReturnWithSurge", "Crashes_IncreaseTopSpeed",
      "CritMalf_PerfectRecoversCrash"], ["CoolingAtBack", "AfterCrashGainSurge", "OneMoreCrash"], [2, 10, 6, 8, 0, 5]),
    ("Drafting", ["Surge", "Shield", "Vent", "Shockwave"], "IonBlast",
     ["Slipstreaming_ImprovedBuffs", "Slipstreaming_LastsUntilImpact", "Slipstream_gainSurging_v3",
      "PerfectStart_ImprovedSlipstreaming_v3"], ["BetterDrafting", "LongerDrafting", "BiggerDraftingZones"],
     [10, 5, 6, 8, 2, 0]),
    ("Burning", ["Vent_Flame", "Shield", "Surge", "Mine"], "IonBlast",
     ["Burning_PowerfulRamjet", "Burning_PowerfulAfterburner", "Burning_GainOvercharged",
      "Conditions_DecreaseBurningPotency_v3"],
     ["StrongerAfterBurnerAndRamjetWhenBurning", "GainBurningWhenRamjet", "BurningInfiniteRamjetAndAfterburner"],
     [6, 8, 0, 10, 2, 5]),
    ("Battling", ["Disruptor", "Shockwave", "Mine", "Shield"], "IonBlast_Overclocked",
     ["Takedown_IncreaseSpeedStat_v4", "Takedown_GainSurgeAndOvercharged_v3", "Takedown_AbilityCooldown",
      "Afterburner_MorePowerPerTakedown_v4"], ["EnergyForTakedowns", "SurgeForTakedowns", "SurgeForTakedownsUpgrade"],
     [0, 6, 10, 2, 8, 5]),
    ("BattlingFlameVent", ["Vent_Flame", "Disruptor", "Shockwave", "Mine"], "IonBlast_Overclocked", None, None, None),
    ("Airborne", ["Shockwave_Punch", "Surge", "Shield", "Vent"], "IonBlast",
     ["Landing_PerfectBoost_v4", "Afterburner_BetterWhileAirborne_v3", "Surge_GainWhileAirborne",
      "Landing_IncreaseSpeedStat_v3"],
     ["AfterburnerRefillOnPerfectLanding", "AfterburnerPowerStacksWhenAirborne", "AllLandingsArePerfect"],
     [2, 0, 5, 8, 6, 10]),
    ("Antagonist", ["Disruptor", "Shockwave", "Mine", "Vent_Flame"], "IonBlast_Overclocked",
     ["Ability_FasterCooldown_v4", "Takedown_AbilityCooldown", "Energy_GainOnTakedown_v4", "Energy_AddOnTakedown_v2"],
     ["EnergyForAbilityHits", "EnergyForTakedowns", "NoEnergyGainOverchargeImproved"], [6, 10, 2, 0, 8, 0]),
    ("Frozen", ["Vent_Freezing", "Shield", "Surge", "Mine_Frozen"], "IonBlast_Cooled",
     ["Frozen_IncreaseSpeed", "Frozen_PowerfulRamjet", "Frozen_MoreCooling", "Frozen_ReducedSteeringPenalty_v3"],
     ["FrozenRamjetNoHeat", "OnFrozenGainShield", "FrozenDoubleDuration"], [6, 8, 5, 8, 2, 2]),
]
# speeder styles: key -> source RacerStyle asset, campaign Lv1 style that holds the art (RC-8)
SPEEDER_STYLES = [
    ("Cooling", "Pvp_Style_Cooling", "CAM_Style_Cooling_Lv1"),
    ("Abilities", "Pvp_Style_Abilities", "CAM_Style_Abilities_Lv1"),
    ("Afterburner", "Pvp_Style_Afterburner", "CAM_Style_Afterburner_Lv1"),
    ("Ramjet", "Pvp_Style_Ramjet", "CAM_Style_Ramjet_Lv1"),
    ("Malfunction", "Pvp_Style_Malfunction", "CAM_Style_Malfunction_Lv1"),
    ("Defence", "Pvp_Style_Defence", "CAM_Style_Defence_Lv1"),
    ("Surging", "Pvp_Style_Surging", "CAM_Style_Surging_Lv1"),
    ("Struggling", "Pvp_Style_Struggling", "CAM_Style_Struggling_Lv1"),
    ("Drafting", "Pvp_Style_Drafting", "CAM_Style_Drafting_Lv1"),
    ("Burning", "Pvp_Style_Burning", "CAM_Style_Burning_Lv1"),
    ("Battling", "Pvp_Style_Battling", "CAM_Style_Battling_Lv1"),
    ("BattlingFlameVent", "Pvp_Style_Battling_FlameVent", "CAM_Style_Battling_Lv1"),   # no own art: Battling's
    ("Airborne", "Pvp_Style_Airborne", "CAM_Style_Airborne_Lv1"),
    ("Antagonist", "Pvp_Style_Antagonist", "CAM_Style_Antagonist_Lv1"),
    ("Frozen", "CAM_Style_Frozen_Lv3", "CAM_Style_Frozen_Lv1"),                         # campaign-only, all 4 traits
]
STYLE_NAME_OVERRIDE = {"BattlingFlameVent": "BRAWLER · FLAME VENT"}   # the game calls both "Brawler"
# pod kits (§4.4): style = Pvp_IA_Plane_<Veg>; parts 1-2 = the pod's trait pair, 3-4 = the base kit's parts 1-2;
# abilities, crash, tune and traits = the base kit's. Pod_Pepper is based on Drafting (RC-2: no ramjet on pods).
POD_KITS = [
    ("Pod_Cabbage", "Pvp_IA_Plane_Cabbage", "Airborne", "CabbageCretornis"),
    ("Pod_Celery", "Pvp_IA_Plane_Celery", "Defence", "CeleryHexing"),
    ("Pod_Garlic", "Pvp_IA_Plane_Garlic", "Malfunction", "GarlicSordes"),
    ("Pod_Swede", "Pvp_IA_Plane_Swede", "BattlingFlameVent", "SwedeNesodon"),
    ("Pod_Onion", "Pvp_IA_Plane_Onion", "Afterburner", "OnionDearc"),
    ("Pod_Pepper", "Pvp_IA_Plane_Pepper", "Drafting", "PepperTarchia"),
]
# the game's quick-race tiers (DA_PresetBuilds "01 - Mastiff [0%]" ...): levels, abilities and crash, no parts
TIER_KITS = [("tier1", "TIER 1 · MASTIFF", "VBD_000_1Mastiff"), ("tier2", "TIER 2 · DALMATIAN", "VBD_011_2Dal"),
             ("tier3", "TIER 3 · HUSKY", "VBD_023_3Husky"), ("tier4", "TIER 4 · CORGI", "VBD_035_4Corgi"),
             ("tier5", "TIER 5 · SPANIEL", "VBD_046_5Spaniel"), ("tier6", "TIER 6 · WHIPPET", "VBD_058_6Whippet")]
PART_KEYS = ["Cornering", "Acceleration", "Resilience", "Boost", "AbilityUsage", "Advanced"]

def vbd_levels(name):
    v = VBD.get(name)
    if not v:
        fail("build %s not in vbds.json", name)
        return [0] * 6
    return [int((v.get("levels") or {}).get(k, 0)) for k in PART_KEYS]

ST = STY_JSON["styles"]
STYLES, STYLE_ORDER = {}, {"speeder": [], "pod": []}
for key, src, cam in SPEEDER_STYLES:
    s, c = ST.get(src), ST.get(cam)
    if not s or not c:
        fail("style %s / %s not in styles.json", src, cam)
        continue
    where = "style " + key
    desc = clean(s["desc"], where)
    build = s.get("build") or ""
    STYLES[key] = {
        "key": key, "name": STYLE_NAME_OVERRIDE.get(key) or upper_name(s["title"], where), "desc": desc, "short": desc,
        "rich": rich_text(EXTRA["styles"].get(src, {}).get("raw"), {}, where, "style", desc),
        "path": objpath(s["path"], where),
        "icon": TX.rel(s.get("icon") or c.get("icon"), where),
        "bg": TX.rel(s.get("bg") or c.get("bg"), where) if (s.get("bg") or c.get("bg")) else None,
        "pod": False, "src": src,
        # the style's own Instant Action build (VehicleBuildOverride): the RC-14 launch-base fallback for speeders
        "build": objpath(VBD[build]["path"], where) if build in VBD else None,
    }
    if not STYLES[key]["icon"] or not STYLES[key]["bg"]:
        fail("speeder style %s has no icon or backdrop art (RC-8)", key)
    STYLE_ORDER["speeder"].append(key)
for key, src, base, pair in POD_KITS:
    s = ST.get(src)
    if not s:
        fail("style %s not in styles.json", src)
        continue
    where = "style " + key
    name = upper_name(s["title"], where)
    desc = clean(s["desc"], where)
    body = re.sub(r"^" + re.escape(name) + r":\s*", "", desc, flags=re.I)   # "VULPTEREEN 327: Built on ..."
    short = re.split(r"(?<=[.!?])\s", body, maxsplit=1)[0]
    raw = re.sub(r"^<B>[^<]*:</>\s*", "", EXTRA["styles"].get(src, {}).get("raw") or "")
    STYLES[key] = {
        "key": key, "name": name, "desc": body, "short": short,
        "rich": rich_text(raw, {}, where, "style", body),
        "path": objpath(s["path"], where),
        "icon": TX.rel(s.get("icon"), where),   # the pod pilot's head shot, as the game shows it
        "bg": None,                             # its Background is the full-body render: the figure, not a backdrop
        "pod": True, "src": src, "base": base, "build": None,
    }
    STYLE_ORDER["pod"].append(key)

KITS, KIT_ROWS = collections.OrderedDict(), {}
for key, ab, crash, parts, traits, tune in KIT_TABLE:
    KIT_ROWS[key] = (ab, crash, parts, traits, tune)
for key, ab, crash, parts, traits, tune in KIT_TABLE:
    if parts is None:   # BattlingFlameVent: parts, traits and tune as Battling
        _, _, parts, traits, tune = KIT_ROWS["Battling"]
    KITS[key] = {"key": key, "kind": "style", "label": STYLES.get(key, {}).get("name", key), "style": key,
                 "tune": list(tune), "ab": list(ab), "crash": crash, "parts": ["AFX_" + p for p in parts],
                 "traits": ["TRT_" + t for t in traits]}
for key, src, base, pair in POD_KITS:
    b = KITS[base]
    KITS[key] = {"key": key, "kind": "pod", "label": STYLES[key]["name"], "style": key, "base": base,
                 "tune": list(b["tune"]), "ab": list(b["ab"]), "crash": b["crash"],
                 "parts": ["AFX_PlaneTrait_%s_1" % pair, "AFX_PlaneTrait_%s_2" % pair] + b["parts"][:2],
                 "traits": list(b["traits"])}
for key, label, bname in TIER_KITS:
    v = VBD.get(bname) or {}
    ab = [a[len("BP_Ability_"):-2] if a else False for a in (v.get("abilities") or [])]
    ab = (ab + [False] * 4)[:4]
    crash = (v.get("crash") or "")[len("BP_Ability_"):-2] or False
    KITS[key] = {"key": key, "kind": "tier", "label": label, "tune": vbd_levels(bname),
                 "build": objpath(v["path"], "kit " + key) if v.get("path") else None,
                 "ab": ab, "crash": crash, "parts": []}
    if v.get("affixes") or v.get("planeAffixes"):
        fail("tier build %s has affixes", bname)
for key, s in STYLES.items():
    s["traits"] = list(KITS[key]["traits"])   # the STYLE row sets the 3 trait slots to these (§2.5)

# ====================================================================================================== systems (RC-2)
# needs = the item does nothing without that system on the car; partly = mixed effects (still offered, tag line).
# Seeded by the keyword scan below (Ramjet / Redlining / Critical Malfunction); every hit must be classified here.
NEEDS_RAMJET = {   # parts outside the RAMJET category (stems, version suffix dropped) and traits
    "AFX_Cooled_PowerfulRamjet", "AFX_Burning_PowerfulRamjet", "AFX_Frozen_PowerfulRamjet", "AFX_SysMalf_PowerfulRamjet",
    "AFX_Takedown_ResetHeat", "AFX_Surging_ResetRamjet", "AFX_MYST_Ramjet_MorePowerPerTakedown",
    "AFX_Afterburner_FullyRechargeWhenRamjetReady", "AFX_Afterburner_RamjetCharge",
    "AFX_Afterburner_OverheatingIncreasesPowerOnce", "AFX_Afterburner_OverheatingStacksFuel",
    "AFX_Afterburner_OverheatIncreasesPowerUntilCrash", "AFX_Overcharged_RamjetActivatesOvercharged",
    "AFX_Cooled_CoolRamjetWhileSlipstream", "AFX_Faulty_Overheating_AppliesBurn", "AFX_Faulty_Overheating_AppliesCorrode",
    "AFX_Faulty_Overheating_AppliesFrozen", "AFX_Faulty_Ramjet_HeatIncrease", "AFX_Faulty_Ramjet_LessPower",
    "AFX_Faulty_Ramjet_ReducedAlarm",
    "TRT_CriticalRamjetPower", "TRT_RamjetExtendedAlarm", "TRT_RamjetExtendedAlarmUpgrade",
    "TRT_RamjetReEngageAfterRelease", "TRT_FrozenRamjetNoHeat", "TRT_GainBurningWhenRamjet",
}
NEEDS_CRITMALF_PREFIX = ("AFX_CritMalf_", "AFX_Faulty_CritMalf_")
PARTLY = {   # mixed effects: offered, with a "partly" tag line
    "Autopilot": "ramjet",            # "... Ramjet heating reduced while active."
    "Vent": "ramjet", "VentV2": "ramjet", "Vent_Auto": "ramjet", "Vent_Freezing": "ramjet", "Vent_Flame": "ramjet",
    "Vent_Acid": "ramjet",            # every Vent: "Gain Cooled and reduce Ramjet heat" (§4.3 names Vent)
    "TRT_MalfunctionRepairOnRecovery": "ramjet", "TRT_StrongerAfterBurnerAndRamjetWhenBurning": "ramjet",
    "TRT_BurningInfiniteRamjetAndAfterburner": "ramjet",
    "TRT_RecoverFromSysMalfFaster": "critmalf",   # "... Critical Malfunction is easier to clear." (§4.3 lists it)
}
KEYWORDS = re.compile(r"ramjet|redlin|critical malfunction", re.I)

def stem(i):
    return re.sub(r"_[vV]\d+$", "", i)

def system_of(i, cat=None):
    if cat == "ramjet" or stem(i) in NEEDS_RAMJET or i in NEEDS_RAMJET:
        return "ramjet"
    if i.startswith(NEEDS_CRITMALF_PREFIX):
        return "critmalf"
    return None

SCAN = []
for p in PARTS.values():
    p["needs"] = system_of(p["id"], p["cat"])
    p["partly"] = PARTLY.get(p["id"])
    SCAN.append(("part", p["id"], p["name"], p["desc"], p["needs"], p["partly"]))
for t in TRAITS.values():
    t["needs"] = system_of(t["id"])
    t["partly"] = PARTLY.get(t["id"])
    SCAN.append(("trait", t["id"], t["name"], t["desc"], t["needs"], t["partly"]))
for a in ABIL.values():
    a["needs"] = system_of(a["id"])
    a["partly"] = PARTLY.get(a["id"])
    SCAN.append(("ability", a["id"], a["name"], a["desc"], a["needs"], a["partly"]))
for kind, i, name, desc, needs, partly in SCAN:
    if KEYWORDS.search(desc) and not (needs or partly):
        fail("keyword scan: %s %s (%s) mentions a system but is not classified: %r", kind, i, name, desc)
    if (needs or partly) and not KEYWORDS.search(desc) and kind != "part":
        fail("%s %s is tagged %s but its text names no system", kind, i, needs or partly)
for i in list(NEEDS_RAMJET) + list(PARTLY):
    if not (any(stem(p) == i or p == i for p in PARTS) or i in TRAITS or i in ABIL):
        fail("classified id %s does not exist", i)

# ====================================================================================================== checks
def check_kit(k):
    key, ab, crash, parts, traits = k["key"], k["ab"], k["crash"], k["parts"], k.get("traits")
    for a in ab:
        if a and (a not in ABIL or ABIL[a]["crash"]):
            fail("kit %s: ability %s missing or a crash ability", key, a)
    fams = [ABIL[a]["fam"] for a in ab if a and a in ABIL]
    if len(fams) != len(set(fams)):
        fail("kit %s: two abilities of one family %s", key, fams)
    if crash and crash not in CRASH:
        fail("kit %s: crash ability %s missing", key, crash)
    seen = set()
    for p in parts:
        x = PARTS.get(p)
        if not x:
            fail("kit %s: part %s missing", key, p)
            continue
        if x["fam"] and x["tier"] != x["ntiers"]:
            fail("kit %s: part %s is tier %d of %d, not the top tier", key, p, x["tier"], x["ntiers"])
        f = x["fam"] or p
        if f in seen:
            fail("kit %s: two parts of one family (%s)", key, p)
        seen.add(f)
        if x["planeOnly"] and k["kind"] != "pod":
            fail("kit %s: plane-only part %s in a speeder kit", key, p)
    for t in traits or []:
        if t not in TRAITS:
            fail("kit %s: trait %s missing or not a rule trait", key, t)
    if traits is not None and len(set(traits)) != len(traits):
        fail("kit %s: duplicate traits", key)
    if len(k["tune"]) != 6 or not all(0 <= v <= 10 for v in k["tune"]):
        fail("kit %s: bad tune %s", key, k["tune"])

for k in KITS.values():
    check_kit(k)
for key, src, cam in SPEEDER_STYLES:     # tune = the style's Instant Action build where it has one
    b = (ST.get(src) or {}).get("build")
    if b and vbd_levels(b) != KITS[key]["tune"]:
        fail("kit %s: tune %s differs from %s %s", key, KITS[key]["tune"], b, vbd_levels(b))
    if not b and key != "Frozen":
        fail("style %s has no build", src)
for key, _, base, pair in POD_KITS:
    for p in KITS[key]["parts"][:2]:
        if PARTS.get(p, {}).get("cat") != "pod":
            fail("pod kit %s: %s is not a pod trait", key, p)

counts = {
    "abilities": len(ABIL), "families": len(FAMILIES), "family members": sum(len(f["order"]) for f in FAMILIES),
    "crash": len(CRASH), "parts": len(PARTS), "ladders": len(FAMILY_INFO),
    "ladder tiers": sum(len(f["tiers"]) for f in FAMILY_INFO.values()),
    "single": sum(1 for p in PARTS.values() if not p["fam"] and p["cat"] not in ("flaws", "pod")),
    "flaws": sum(1 for p in PARTS.values() if p["cat"] == "flaws"),
    "pod traits": sum(1 for p in PARTS.values() if p["cat"] == "pod"),
    "traits": len(TRAITS), "trait groups": len(TRAIT_GROUP_INFO),
    "speeder styles": len(STYLE_ORDER["speeder"]), "pod styles": len(STYLE_ORDER["pod"]), "kits": len(KITS),
}
SPEC_COUNTS = {"abilities": 45, "families": 8, "family members": 41, "crash": 4, "parts": 316, "ladders": 52,
               "ladder tiers": 170, "single": 81, "flaws": 53, "pod traits": 12, "traits": 41, "trait groups": 10,
               "speeder styles": 15, "pod styles": 6, "kits": 27}
for k, v in SPEC_COUNTS.items():
    if counts[k] != v:
        fail("count %s = %d, spec %d", k, counts[k], v)
for c, n in SPEC_CAT_COUNTS.items():
    if len(PART_LIST[c]) != n:
        fail("category %s has %d entries, spec %d", c, len(PART_LIST[c]), n)
listed = {p["id"] for lst in PART_LIST.values() for p in lst}
for p in PARTS.values():
    top = FAMILY_INFO[p["fam"]]["tiers"][-1] if p["fam"] else p["id"]
    if top not in listed:
        fail("part %s is reachable from no picker list", p["id"])
for f in FAMILIES:
    if len(f["order"]) not in (5, 6):
        fail("family %s has %d variants", f["key"], len(f["order"]))
for t in TRAITS.values():
    if t["requires"] and t["requires"] not in TRAITS:
        fail("trait %s requires unknown %s", t["id"], t["requires"])
for s in STATS:
    for w in re.findall(r'<widget id="([^"]+)"/>', s["rich"]):
        if not ({"ability", "trait"} & WIDGET_IDS.get(w, set())):
            fail("STATS %s uses widget id %s that no ability/trait text uses", s["key"], w)
    if norm(plain(s["rich"])) != norm(s["desc"]):
        fail("STATS %s rich/desc differ", s["key"])

# ====================================================================================================== Lua output
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}

def lstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

class Raw(str):
    """A value written to the Lua file as is (a zero-based table)."""

def lua(v):
    if isinstance(v, Raw):
        return str(v)
    if v is None:
        return "nil"
    if v is True or v is False:
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return lstr(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua(x) for x in v) + " }" if v else "{}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            if isinstance(k, int):
                parts.append("[%d] = %s" % (k, lua(x)))
            elif IDENT.match(k) and k not in LUA_KEYWORDS:
                parts.append("%s = %s" % (k, lua(x)))
            else:
                parts.append("[%s] = %s" % (lstr(k), lua(x)))
        return "{ " + ", ".join(parts) + " }" if parts else "{}"
    raise TypeError(repr(v))

def key(k):
    return k if IDENT.match(k) and k not in LUA_KEYWORDS else "[%s]" % lstr(k)

def zero_based(lst):
    return "{ [0] = " + ", ".join(lua(x) for x in lst) + " }"

def pick(d, fields, bools=()):
    """Ordered entry; booleans in `bools` are written only when true (absent = false)."""
    out = collections.OrderedDict()
    for f in fields:
        v = d.get(f)
        if f in bools and not v:
            continue
        out[f] = v
    return out

L = []
w = L.append
w("-- perkdata.lua (G4 data) - GENERATED by tools/gen-perkdata.py from work/decoded/perks/*.json; do not edit by hand.")
w("-- Static perk catalog of the RACERS step (notes/design/vehicle-step-v2.md §4.3, §4.4, §5.3; RC-2, RC-4, RC-8).")
w("-- Pure data: no functions, no game calls, no require. Source paks %s." % DATA_VERSION)
w("--")
w("-- Paths. Textures are relative to D.TEX without the object suffix; expand with")
w("--   D.TEX .. rel .. \".\" .. rel:match(\"[^/]+$\")")
w("--   (\"Icons/X/T_UI_Y\" -> \"/Game/Griffin/UI/Library/Textures/Icons/X/T_UI_Y.T_UI_Y\").")
w("-- Every texture exists in the PNG export (checked by the generator); none is derived from an asset name and none")
w("-- comes from a soft pointer at runtime. cls / path / build are full object paths (U.class / U.obj).")
w("-- Ids: ABILITIES = BP_Ability_<id>_C suffixes, PARTS = affix asset names, TRAITS = TRT_ asset names, STYLES and")
w("-- KITS = keys below. PARTS omit false booleans (faulty, planeOnly). Names are upper case; texts are ASCII plus \"·\".")
w("-- desc = plain text (params filled), rich = the game's markup (<widget id=\"X\"/>, <H1>..</>) for")
w("-- WBP_Character_Ability.ItemDescription.")
w("-- needs = \"ramjet\" | \"critmalf\": the item does nothing without that system on the car (RC-2; hidden when off,")
w("-- PerkHideInert); partly = the same keys for items with a mixed effect (still offered, tag line).")
w("")
w("local D = {}")
w("")
w("D.VERSION = %s" % lstr(DATA_VERSION))
w("D.TEX = %s" % lstr(TEX))
w("D.EMPTY_ICON = %s   -- an empty ability slot" % lstr(EMPTY_ICON))
w("D.LEVEL_MAX, D.POWER_MAX, D.ENERGY_BASE = 10, 60, 3   -- levels 0..10 per part, PowerLevel 0..60, base Energy")
w("")
w("-- Upgrade parts by EVehiclePartSlot (0..5): key = the enum name (vbds level keys), vu = VU_<vu>_<NN> stem")
w("-- (level 1 = _001, else %02d), name = stat (PartStatNames), part = the VU's PlayerFacingName. Slot 5's stat name per")
w("-- class is D.ADVANCED[arch]. RAMJET (3) keeps counting for POWER on a car without a ramjet (needs = tag only).")
w("D.STATS = {")
for i, s in enumerate(STATS):
    w("  [%d] = %s," % (i, lua(pick(s, ["key", "vu", "name", "part", "icon", "large", "lv10", "desc", "rich", "needs",
                                        "partly"]))))
w("}")
w("D.ADVANCED = %s   -- by EVehicleArchetype: Car 0, Plane 1, Bike 2, Skimmer 3" % lua(dict(ADVANCED)))
w("D.ADVANCED_DESC = {")
for k in sorted(ADVANCED_DESC):
    w("  [%d] = %s," % (k, lstr(ADVANCED_DESC[k])))
w("}")
w("D.BATTERY = %s   -- Power Cell energy bonus per level (Energy = 3 + it)" % zero_based(BATTERY))
w("D.STACKS = %s    -- stacking TuneSet stacks per level (of 13)" % zero_based(STACKS))
w("")
w("-- Ability families of the 4 d-pad slots, picker order; order = L/R order (base, branch A, A II, branch B, B II).")
w("D.FAMILIES = {")
for f in FAMILIES:
    w("  %s," % lua(pick(f, ["key", "name", "icon", "large", "order"])))
w("}")
w("D.CRASH = %s   -- the crash slot, L/R order" % lua(CRASH))
w("D.CRASH_FAM = %s" % lua(pick(CRASH_INFO, ["key", "name", "icon", "large"])))
w("-- lvl = upgrade depth 1 (base), 2 (branch), 3 (branch II) = level pips (the game's AbilityLevel is 0 / 2 / 3);")
w("-- from = the ability it upgrades; cfg = native config class: EnergyCost on U.cdo(\"/Script/Griffin.Default__\" .. cfg)")
w("-- (RC-4); energy = an EnergyCost the cooked config stores (crash abilities: 0), which wins over the CDO default.")
w("D.ABILITIES = {")
for f in [x["key"] for x in FAMILIES] + [CRASH_FAM]:
    for aid in (tree_order(f)):
        a = ABIL[aid]
        w("  %s = %s," % (key(aid), lua(pick(a, ["id", "fam", "lvl", "from", "name", "desc", "rich", "icon", "sub",
                                                 "large", "cls", "cfg", "energy", "crash", "needs", "partly"],
                                             bools=("crash",)))))
w("}")
w("")
w("-- Part (affix) picker categories, picker order. podOnly = pods only; flaws = hidden when PerkFlaws is false.")
w("D.PART_CATS = {")
for ckey, cname, kw, _, extra in CATS:
    d = collections.OrderedDict([("key", ckey), ("name", cname),
                                 ("icon", TX.need("Icons/Keywords/T_UI_Keyword_%s_Icn" % kw, "category " + ckey)),
                                 ("podOnly", bool(extra.get("podOnly"))), ("flaws", bool(extra.get("flaws"))),
                                 ("needs", extra.get("needs"))])
    w("  %s," % lua(d))
w("}")
w("D.RARITY = %s   -- by EGfnRarity; pips = rarity + 1 for 0..3" % zero_based(RARITY))
w("-- rarity = EGfnRarity (0 COMMON .. 3 LEGENDARY, 4 FLAW, 5 EXPERIMENTAL); fam = tier ladder (D.PART_FAMILIES index,")
w("-- = DA_VehicleUpgradeConfig.AffixFamilyLists index + 1), tier = its position; faulty = starts Faulty (Status 2);")
w("-- planeOnly = pods only. Standalone parts have no fam/tier.")
w("D.PARTS = {")
for p in sorted(PARTS.values(), key=lambda p: p["id"]):
    w("  %s = %s," % (key(p["id"]), lua(pick(p, ["id", "name", "rarity", "cat", "fam", "tier", "faulty", "planeOnly",
                                                 "path", "icon", "large", "desc", "rich", "needs", "partly"],
                                             bools=("faulty", "planeOnly")))))
w("}")
w("-- Tier ladders: tiers in upgrade order (I..IV); ladder = the one changing value per tier, when there is one.")
w("D.PART_FAMILIES = {")
for k in sorted(FAMILY_INFO):
    w("  [%d] = %s," % (k, lua(pick(FAMILY_INFO[k], ["name", "tiers", "ladder"]))))
w("}")
w("-- Picker order per category: one entry per ladder (its top tier) or standalone part; LEGENDARY first, then name.")
w("D.PART_LIST = {")
for c, lst in PART_LIST.items():
    w("  %s = %s," % (key(c), lua([p["id"] for p in lst])))
w("}")
w("")
w("-- 41 rule traits (the description-only TRT_StartWith* / TRT_Plane_* are never offered). requires = the trait")
w("-- whose effect this one extends (tag line only, not enforced).")
w("D.TRAIT_GROUPS = {")
for g in TRAIT_GROUP_INFO:
    w("  %s," % lua(pick(g, ["key", "name", "icon"])))
w("}")
w("D.TRAITS = {")
for tid in TRAIT_ORDER:
    t = TRAITS[tid]
    w("  %s = %s," % (key(tid), lua(pick(t, ["id", "name", "group", "desc", "rich", "icon", "path", "requires",
                                             "needs", "partly"]))))
w("}")
w("D.TRAIT_ORDER = {")
for g in TRAIT_GROUP_INFO:
    w("  %s," % ", ".join(lstr(t) for t in TRAIT_ORDER if TRAITS[t]["group"] == g["key"]))
w("}")
w("")
w("-- Racer styles: traits = the 3 traits the STYLE row puts in the trait slots (= the style kit's); short = one")
w("-- sentence for the PILOT stage; icon / bg = real art (RC-8), bg = nil -> dark backdrop (pods: setup.arcadeBg);")
w("-- build = the style's Instant Action build (speeders, RC-14 fallback base); base = a pod style's base kit.")
w("D.STYLES = {")
for k in STYLE_ORDER["speeder"] + STYLE_ORDER["pod"]:
    s = STYLES[k]
    w("  %s = %s," % (key(k), lua(pick(s, ["key", "name", "desc", "short", "rich", "path", "icon", "bg", "traits",
                                           "pod", "base", "build"]))))
w("}")
w("D.STYLE_ORDER = {")
w("  speeder = %s," % lua(STYLE_ORDER["speeder"]))
w("  pod = %s," % lua(STYLE_ORDER["pod"]))
w("}")
w("")
w("-- Kits (§4.4). kind = \"style\" (key = a STYLES key; the pilot's own one is the \"pilot\" kit, \"s_<key>\" in")
w("-- loadouts) | \"pod\" | \"tier\" (style and traits unchanged, no parts). label = the kit name without \" KIT\";")
w("-- tune = levels by slot 0..5; ab = slots 1..4 (Up, Left, Down, Right), false = empty; crash = id or false;")
w("-- parts = the kit's parts (top tiers; perks.lua pads to PerkPartSlots); \"max\" is derived by perks.lua.")
w("D.KITS = {")
for k, kit in KITS.items():
    d = pick(kit, ["key", "kind", "label", "style", "base", "build", "tune", "ab", "crash", "parts", "traits"])
    d["tune"] = Raw(zero_based(kit["tune"]))
    w("  %s = %s," % (key(k), lua(d)))
w("}")
w("D.TIERS = %s" % lua([k for k, _, _ in TIER_KITS]))
w("")
w("return D")
LUA_TEXT = "\n".join(L) + "\n"

# ====================================================================================================== summary
S = []
s_ = S.append
s_("perkdata.summary.txt - tools/gen-perkdata.py, data %s" % DATA_VERSION)
s_("inputs: %s (abilities.json, affixes.json, styles.json, vbds.json, extra.json)" % os.path.abspath(SRC))
s_("png export roots: %s" % ", ".join(os.path.relpath(r, PNGROOT) or "." for r in TX.roots))
s_("asset list: %s (%d object files)" % (ASSETLIST, len(ASSET_FILES)))
s_("raw decodes checked: %s" % ("; ".join(RAW_CHECKED) or "none"))
s_("")
s_("== counts (spec §4.3)")
for k, v in counts.items():
    s_("  %-16s %4d  %s" % (k, v, "ok" if SPEC_COUNTS.get(k) == v else "SPEC %s" % SPEC_COUNTS.get(k)))
s_("  categories:")
for ckey, cname, kw, _, _ in CATS:
    n = sum(1 for p in PARTS.values() if p["cat"] == ckey)
    s_("    %-11s %-20s %3d parts, %3d picker entries %s" % (ckey, cname, n, len(PART_LIST[ckey]),
                                                             "ok" if SPEC_CAT_COUNTS[ckey] == len(PART_LIST[ckey])
                                                             else "SPEC %d" % SPEC_CAT_COUNTS[ckey]))
s_("  parts without a large icon: %d (%s)" % (sum(1 for p in PARTS.values() if not p["large"]),
                                             ", ".join(sorted(p["id"] for p in PARTS.values() if not p["large"]))))
s_("")
s_("== ability families (L/R order)")
for f in FAMILIES + [dict(CRASH_INFO, order=CRASH)]:
    s_("  %-16s %s" % (f["name"], ", ".join("%s (%s, %d%s)" % (ABIL[i]["name"], i, ABIL[i]["lvl"],
                                                              ", E" + str(ABIL[i]["energy"])
                                                              if ABIL[i]["energy"] is not None else "")
                                            for i in f["order"])))
s_("  config classes (RC-4 EnergyCost CDO): %s" % ", ".join(sorted({a["cfg"] for a in ABIL.values()})))
s_("")
kit_problems = [p for p in PROBLEMS if p.startswith("kit ") or p.startswith("pod kit ")]
s_("== kits (validate_presets-style: every id resolves; parts are top tiers): %s" % (
    "ALL OK" if not kit_problems else "%d PROBLEM(S)" % len(kit_problems)))
for k, kit in KITS.items():
    s_("  %-18s %-6s %-24s tune %-15s PL %2d  ab %s  crash %s" % (
        k, kit["kind"], kit["label"], "/".join(str(v) for v in kit["tune"]), sum(kit["tune"]),
        ",".join(a or "-" for a in kit["ab"]), kit["crash"] or "-"))
    if kit["parts"]:
        s_("      parts  %s" % ", ".join("%s (%s, %s%s)" % (p, PARTS[p]["name"], RARITY[PARTS[p]["rarity"]],
                                                            ", needs " + PARTS[p]["needs"] if PARTS[p].get("needs") else "")
                                         if p in PARTS else p + " MISSING" for p in kit["parts"]))
    if kit.get("traits"):
        s_("      traits %s" % ", ".join("%s (%s%s)" % (t, TRAITS[t]["name"], ", needs " + TRAITS[t]["needs"]
                                                        if TRAITS[t].get("needs") else "")
                                         if t in TRAITS else t + " MISSING" for t in kit["traits"]))
s_("")
s_("== styles (RC-8 art)")
for k in STYLE_ORDER["speeder"] + STYLE_ORDER["pod"]:
    s = STYLES[k]
    s_("  %-18s %-22s %-28s icon %s  bg %s  build %s" % (k, s["name"], s["src"], s["icon"], s["bg"] or "nil (dark)",
                                                       (s["build"] or "-").rsplit(".", 1)[-1]))
s_("")
s_("== trait icons replaced by the group glyph (FPO, missing or not a glyph folder; CF §3.4.3)")
for g in GLYPH_SWAPS:
    s_("  " + g)
s_("")
s_("== systems (RC-2): keyword scan Ramjet / Redlining / Critical Malfunction, for a human check")
for kind, i, name, desc, needs, partly in sorted(SCAN, key=lambda x: (x[4] or "~", x[5] or "~", x[0], x[1])):
    if needs or partly or KEYWORDS.search(desc):
        tag = ("needs " + needs) if needs else ("partly " + partly) if partly else "UNCLASSIFIED"
        s_("  %-15s %-8s %-52s %-30s %s" % (tag, kind, i, name, desc[:90]))
s_("  totals: needs ramjet %d, needs critmalf %d, partly %d" % (
    sum(1 for x in SCAN if x[4] == "ramjet"), sum(1 for x in SCAN if x[4] == "critmalf"),
    sum(1 for x in SCAN if x[5])))
s_("  not tagged, but naming heat (the heat gauge belongs to the ramjet; a live pod race shows whether these matter):")
for kind, i, name, desc, needs, partly in sorted(SCAN, key=lambda x: (x[0], x[1])):
    if not (needs or partly) and re.search(r"\bheat\b|temperature", desc, re.I):
        s_("    %-8s %-52s %-30s %s" % (kind, i, name, desc[:90]))
s_("")
s_("== rich-text widget ids (WBP_Character_Ability renders ability and trait texts natively; ids used only by")
s_("   affix texts were not seen in that widget: V-RC-06 should glance at one)")
for wid in sorted(WIDGET_IDS):
    s_("  %-18s %s" % (wid, ",".join(sorted(WIDGET_IDS[wid]))))
s_("")
s_("== text normalisation: %s" % (", ".join("%s x%d" % kv for kv in sorted(MAPPED.items())) or "none"))
dup = collections.defaultdict(list)
for p in PARTS.values():
    dup[p["name"]].append(p["id"])
s_("== parts sharing a display name: %s" % ("; ".join("%s = %s" % (n, ", ".join(sorted(v)))
                                                     for n, v in sorted(dup.items()) if len(v) > 1) or "none"))
for n in NOTES:
    s_("note: " + n)

# ====================================================================================================== write
size = len(LUA_TEXT.encode("utf-8"))
if size > SIZE_LIMIT:
    fail("perkdata.lua is %d bytes, over the %d cap", size, SIZE_LIMIT)
elif size > SIZE_TARGET:
    s_("WARNING: %d bytes is over the %d-byte target of §5.3: the contract alone (full object paths, desc + rich and"
       " two textures for 316 parts) is ~190 KB of PARTS" % (size, SIZE_TARGET))
fd, tmp = tempfile.mkstemp(suffix=".lua")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(LUA_TEXT)
r = subprocess.run(["luac5.4", "-p", tmp], capture_output=True, text=True)
if r.returncode != 0:
    fail("luac5.4 -p: %s", (r.stderr or r.stdout).strip())
s_("")
s_("== result: %d bytes, luac5.4 -p %s, %d problem(s)" % (size, "ok" if r.returncode == 0 else "FAILED", len(PROBLEMS)))
for p in PROBLEMS:
    s_("PROBLEM: " + p)
open(SUMMARY, "w", encoding="utf-8").write("\n".join(S) + "\n")
if PROBLEMS:
    if os.path.exists(tmp):
        os.unlink(tmp)
    print("\n".join("PROBLEM: " + p for p in PROBLEMS))
    sys.exit("gen-perkdata: %d problem(s); %s not written (see %s)" % (len(PROBLEMS), OUT, SUMMARY))
shutil.move(tmp, OUT)
os.chmod(OUT, 0o644)
print("wrote %s (%d bytes); summary %s" % (OUT, size, SUMMARY))

#!/usr/bin/env python3
# gen-custdata.py - generates SWGRCouch/Scripts/custdata.lua, the static vehicle-customisation catalog of the guests'
# GARAGE (garage.lua; docs/dev/guest-garage.md).
#
# Usage (always python3 -I):
#   python3 -I tools/gen-custdata.py <cue4cli json root> <out.lua>
#       json root  a cue4cli json dump of the paks (any CL), made with
#                    cue4cli --paks <Paks> --no-loc json --out <root> \
#                      'LCD_LiveryCommon|/LAD_|/Liveries/.*/(LM|LC|LP|IM|IC)_[A-Za-z0-9_]+\.|/Customisation/[A-Za-z]+/TH_[A-Za-z0-9_]+\.|/Presets/.*PRE_[A-Za-z0-9_]+\.'
#
# What the game keeps (decoded 2026-10-15, docs/dev/guest-garage.md section 1):
#   * LCD_LiveryCommon (CstLiveryCommonData): LiveryPaletteMap / PatinaMap / IconMaskMap / IconPaletteMap, each a
#     TMap<FGameplayTag, option data asset>; LAD_<Class> (CstLiveryArchetypeData): LiveryMaskMap (the livery templates
#     of that class). A vehicle recipe names its options by these TAGS (LiveryMaskTag, LiveryPaletteTag, PatinaTag,
#     IconMaskTag, IconPaletteTag), never by asset.
#   * every option asset (CstCustomisationOptionDataAsset): ItemName, Cost, IsAvailableToPlayerByDefault, UnlockedBy,
#     TagToUnlockWhenPurchased; colours: CstLiveryColourData.LiveryColours[0..2], CstLiveryIconColourData.IconColours.
#   * PRE_* (CstVehiclePresetRecipe CDO): the preset's own tags (absent = FGameplayTag None).
# Lua never reads a soft pointer: every path below is a static string from the decoded data.
# Every check failure exits 1 and leaves the previous out.lua untouched.
import glob, json, os, re, sys

ARCH = {"Car": 0, "Plane": 1, "Bike": 2, "Skimmer": 3}


def fail(msg):
    sys.stderr.write("gen-custdata: " + msg + "\n")
    sys.exit(1)


def load(p):
    d = json.load(open(p, encoding="utf-8"))
    return d if isinstance(d, list) else [d]


def props(p):
    for e in load(p):
        if e.get("Properties") is not None and not str(e.get("Type", "")).endswith("GeneratedClass"):
            return e["Properties"]
    return {}


def obj_path(op):
    # "/GriffinSharedVehicles/.../LM_Ace01.0" -> "/GriffinSharedVehicles/.../LM_Ace01.LM_Ace01"
    base = op.rsplit(".", 1)[0]
    return base + "." + base.rsplit("/", 1)[1]


def json_of(root, op):
    # an object path -> its decoded file (the plugin mount maps to Griffin/Plugins/GriffinSharedVehicles/Content)
    base = op.rsplit(".", 1)[0]
    if base.startswith("/GriffinSharedVehicles/"):
        rel = "Griffin/Plugins/GriffinSharedVehicles/Content/" + base[len("/GriffinSharedVehicles/"):]
    elif base.startswith("/Game/"):
        rel = "Griffin/Content/" + base[len("/Game/"):]
    else:
        fail("unknown mount: " + op)
    f = os.path.join(root, rel + ".json")
    if not os.path.isfile(f):
        fail("missing decoded asset " + f)
    return f


def ascii_name(s):
    s = (s or "").strip()
    s = s.replace("’", "'").replace("–", "-")
    if any(ord(ch) > 126 for ch in s):
        fail("non-ASCII name " + repr(s))
    return s


def pretty(s):
    # "Ace01" -> "ACE 01", "Assassin02" -> "ASSASSIN 02", "All Gold" -> "ALL GOLD"
    s = re.sub(r"([A-Za-z])(\d)", r"\1 \2", s)
    return s.upper()


def hexes(pr, key):
    out = []
    for k in (key, key + "[1]", key + "[2]", key + "[3]"):
        v = pr.get(k)
        if isinstance(v, dict) and "Hex" in v:
            out.append(v["Hex"][-6:] if len(v["Hex"]) >= 6 else v["Hex"])
    return out


def option(root, tag, op, colour_key=None):
    pr = props(json_of(root, op))
    e = {"tag": tag, "path": obj_path(op), "asset": os.path.basename(op.rsplit(".", 1)[0])}
    nm = (pr.get("ItemName") or {}).get("LocalizedString") or (pr.get("ItemName") or {}).get("SourceString")
    e["name"] = pretty(ascii_name(nm)) if nm else ("NONE" if tag.count(".") <= 1 else pretty(tag.rsplit(".", 1)[1]))
    if pr.get("IsAvailableToPlayerByDefault") is True or tag.count(".") <= 1:
        e["def"] = True
    if pr.get("IsHiddenWhileLocked") is True:
        e["hidden"] = True
    if isinstance(pr.get("Cost"), int):
        e["cost"] = pr["Cost"]
    ub = (pr.get("UnlockedBy") or {}).get("TagName")
    if ub and ub != "None":
        e["unlock"] = ub
    if colour_key:
        c = hexes(pr, colour_key)
        if c:
            e["colours"] = c
    return e


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_entry(e):
    keys = ["tag", "name", "asset", "path", "def", "hidden", "cost", "unlock", "colours"]
    parts = []
    for k in keys:
        if k not in e:
            continue
        v = e[k]
        if isinstance(v, bool):
            parts.append("%s = %s" % (k, "true" if v else "false"))
        elif isinstance(v, int):
            parts.append("%s = %d" % (k, v))
        elif isinstance(v, list):
            parts.append("%s = { %s }" % (k, ", ".join(lua_str(x) for x in v)))
        else:
            parts.append("%s = %s" % (k, lua_str(v)))
    return "{ " + ", ".join(parts) + " }"


def main():
    if len(sys.argv) != 3:
        fail("usage: gen-custdata.py <cue4cli json root> <out.lua>")
    root, out = sys.argv[1], sys.argv[2]
    lcd_f = glob.glob(os.path.join(root, "**/LCD_LiveryCommon.json"), recursive=True)
    if len(lcd_f) != 1:
        fail("LCD_LiveryCommon.json not found exactly once under " + root)
    lcd = props(lcd_f[0])

    def common(mapname, colour_key=None):
        lst = []
        for e in lcd.get(mapname, []):
            lst.append(option(root, e["Key"]["TagName"], e["Value"]["ObjectPath"], colour_key))
        if not lst:
            fail(mapname + " is empty")
        return lst

    palettes = common("LiveryPaletteMap", "LiveryColours")
    patinas = common("PatinaMap")
    decals = common("IconMaskMap")
    decal_colours = common("IconPaletteMap", "IconColours")

    masks = {}
    for cls, arch in ARCH.items():
        f = glob.glob(os.path.join(root, "**/LAD_%s.json" % cls), recursive=True)
        if len(f) != 1:
            fail("LAD_%s.json not found exactly once" % cls)
        lst = [option(root, e["Key"]["TagName"], e["Value"]["ObjectPath"]) for e in props(f[0]).get("LiveryMaskMap", [])]
        if len(lst) < 2:
            fail("LAD_%s has %d masks" % (cls, len(lst)))
        masks[arch] = lst

    # preset defaults: every PRE_* of the four classes' Presets folders (sub folders of pods included, the
    # Shakedown / Diorama / part presets left out: vehicles.lua never offers them)
    presets = {}
    for p in sorted(glob.glob(os.path.join(root, "**/Presets/**/PRE_*.json"), recursive=True)):
        rel = p.replace("\\", "/")
        if "/Shakedown/" in rel or "/Diorama" in rel or re.search(r"/PRE_[A-Za-z]+_(Engine|Root)", rel):
            continue
        name = os.path.basename(p)[:-5]
        pr = props(p)
        d = {}
        for k, short in (("LiveryMaskTag", "mask"), ("LiveryPaletteTag", "palette"), ("PatinaTag", "patina"),
                         ("IconMaskTag", "decal"), ("IconPaletteTag", "decalColour")):
            t = (pr.get(k) or {}).get("TagName")
            if t and t != "None":
                d[short] = t
        presets[name] = d
    if len(presets) < 40:
        fail("only %d presets decoded" % len(presets))

    # themes: model base -> TH_ item name / unlock (CstThemeData), checked against the presets
    themes = {}
    for p in sorted(glob.glob(os.path.join(root, "**/Customisation/*/TH_*.json"), recursive=True)):
        pr = props(p)
        base = os.path.basename(p)[3:-5]
        pre = (pr.get("presetRecipe") or {}).get("ObjectPath", "")
        pre_id = os.path.basename(pre.rsplit(".", 1)[0]) if pre else None
        t = {"preset": pre_id, "path": None}
        th_rel = os.path.relpath(p, root).replace("\\", "/")[:-5]
        if th_rel.startswith("Griffin/Content/"):
            t["path"] = "/Game/" + th_rel[len("Griffin/Content/"):]
        t["path"] = t["path"] + "." + os.path.basename(th_rel) if t["path"] else None
        if pr.get("IsAvailableToPlayerByDefault") is True:
            t["def"] = True
        if isinstance(pr.get("Cost"), int):
            t["cost"] = pr["Cost"]
        ub = (pr.get("UnlockedBy") or {}).get("TagName")
        if ub and ub != "None":
            t["unlock"] = ub
        nm = (pr.get("ItemName") or {}).get("LocalizedString")
        if nm:
            t["name"] = ascii_name(nm).upper()
        themes[base] = t
    if len(themes) < 36:
        fail("only %d themes decoded" % len(themes))

    L = []
    L.append("-- custdata.lua (garage data) - GENERATED by tools/gen-custdata.py from a cue4cli json dump of the paks; do not")
    L.append("-- edit by hand. Static vehicle-customisation catalog of the guests' GARAGE (garage.lua, docs/dev/guest-garage.md).")
    L.append("-- Pure data: no functions, no game calls, no require.")
    L.append("--")
    L.append("-- A vehicle recipe (FCstSavedVehicleRecipeData, the struct PlayerVehicleCustomisationComponent:")
    L.append("-- Server_UpdateVehicleRecipe uploads) names its livery by GAMEPLAY TAGS: LiveryMaskTag (template, per class:")
    L.append("-- LAD_<Class>.LiveryMaskMap), LiveryPaletteTag (colours), PatinaTag, IconMaskTag (decal), IconPaletteTag (decal")
    L.append("-- colours), all from LCD_LiveryCommon's maps. Entries keep the maps' order; the root tag (\"Customisation.Livery\",")
    L.append("-- \"Customisation.Patina\") is the NONE / default entry. path = the option's data asset (CstOptionFunctionLibrary")
    L.append("-- unlock checks), def = IsAvailableToPlayerByDefault, cost / unlock = its Cost / UnlockedBy tag, colours = hex")
    L.append("-- swatches. PRESETS[id] = the tags a PRE_* preset sets itself (absent = None). THEMES[base] = the game's \"Choose")
    L.append("-- Model\" entry (CstThemeData) of a base model: preset, name, unlock data.")
    L.append("")
    L.append("local D = {}")
    L.append("")
    L.append("D.MASKS = {")
    for arch in sorted(masks):
        L.append("  [%d] = {" % arch)
        for e in masks[arch]:
            L.append("    " + lua_entry(e) + ",")
        L.append("  },")
    L.append("}")
    for nm, lst in (("PALETTES", palettes), ("PATINAS", patinas), ("DECALS", decals), ("DECAL_COLOURS", decal_colours)):
        L.append("")
        L.append("D.%s = {" % nm)
        for e in lst:
            L.append("  " + lua_entry(e) + ",")
        L.append("}")
    L.append("")
    L.append("D.PRESETS = {")
    for name in sorted(presets):
        d = presets[name]
        L.append("  %s = { %s }," % (name, ", ".join("%s = %s" % (k, lua_str(d[k])) for k in sorted(d))))
    L.append("}")
    L.append("")
    L.append("D.THEMES = {")
    for base in sorted(themes):
        t = themes[base]
        parts = []
        for k in ("preset", "name", "path", "def", "cost", "unlock"):
            if k in t and t[k] is not None:
                v = t[k]
                parts.append("%s = %s" % (k, "true" if v is True else (str(v) if isinstance(v, int) else lua_str(v))))
        L.append("  %s = { %s }," % (base, ", ".join(parts)))
    L.append("}")
    L.append("")
    L.append("return D")
    txt = "\n".join(L) + "\n"
    tmp = out + ".tmp"
    open(tmp, "w", encoding="ascii").write(txt)
    os.replace(tmp, out)
    print("gen-custdata: %s: masks %s, %d palettes, %d patinas, %d decals, %d decal colours, %d presets, %d themes, %d bytes"
          % (out, ",".join("%d:%d" % (a, len(masks[a])) for a in sorted(masks)), len(palettes), len(patinas),
             len(decals), len(decal_colours), len(presets), len(themes), len(txt)))


if __name__ == "__main__":
    main()

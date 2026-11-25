#!/usr/bin/env python3
"""Generates a Jetpack Compose app with many screens, for testing screen maps at scale.

    testapps/mapgen/mapgen.py --out DIR [--seed N] [--screens N] [--sections N] [--depth N] [--fanout N]
                              [--list-items MIN-MAX] [--images N] [--links F] [--animated N]
                              [--mutate KIND=N,...] [--mutation-seed N] [--package ID] [--version N] [--build]

Everything comes from --seed: the same arguments give the same app, byte for byte. The app is a real Compose
application: a bottom bar of sections, each a tree of screens up to --depth deep, reached by tapping (navigation-compose,
no deep links needed). Screens come in many kinds (long lists, grids of images, forms, tabs, pagers, dashboards with
charts, settings, dialogs and bottom sheets, nested horizontal lists, detail pages, article pages, filter chips), each
with its own seeded variation in content, layout, colors and controls.

--mutate makes a second build of the same app that differs in known ways, for diffs: `restyle` changes a screen's
colors and spacing (pixels), `retext` its words (text), `restructure` adds or drops blocks of controls (structure),
`relink` points one of its buttons at another screen (routes), `add` adds a new screen under an existing one, `remove`
drops a leaf screen. The second build comes from the same --seed with --mutation-seed choosing what to change, and
DIR/mutations.json lists every change with the screen's title: what a comparison of the two builds should report.

DIR/model.json describes the app (every screen, its kind, title, parent, children and links). With --build the project
is built with its Gradle wrapper and the APK copied to DIR/app.apk (needs JDK 17 and an Android SDK: ANDROID_HOME, or
~/Library/Android/sdk).

Words that apksim's crawler skips by default (delete, share, send, buy, subscribe...) never appear in the generated
words, so a walk can reach every screen. --animated N gives N screens an endless animation (screens a walk cannot
settle).
"""
import argparse
import json
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------------------------------------- words

NOUNS = ("Atlas Beacon Canyon Delta Ember Fjord Grove Harbor Island Jasper Kestrel Lagoon Meadow Nebula Orchard Prairie "
         "Quarry Reef Summit Tundra Upland Valley Willow Yarrow Zephyr Aurora Basalt Cobalt Dune Estuary Fern Glacier "
         "Heath Inlet Juniper Kelp Lichen Marsh Nimbus Oasis Pebble Quartz Ridge Sierra Thistle Umber Vista Wharf "
         "Garden Library Studio Market Station Gallery Workshop Kitchen Archive Journal Planner Tracker Ledger Album "
         "Compass Lantern Harvest Voyage Signal Canvas Pocket Circuit Rhythm Spectrum").split()
ADJ = ("Quiet Bright Hidden Golden Silver Northern Southern Eastern Western Early Late Gentle Rapid Calm Wild Lucid "
       "Deep Open Little Grand Amber Coral Ivory Olive Indigo Crimson Misty Sunny Frosty Velvet Rustic Modern Classic "
       "Daily Weekly Local Global Favorite Recent Popular Featured").split()
VERBS = "Browse Explore Open View Visit Discover Review Inspect Show Read Plan Track Compare Check Find Learn".split()
WORDS = ("the river carries light across the stones while evening settles over quiet fields and distant hills keep "
         "their colors long after the town has gone to sleep a small boat waits by the pier with nets folded and the "
         "market opens early with bread fruit cheese and flowers in wooden crates people walk slowly under the trees "
         "talking about weather travel music and the long summer ahead maps and notes lie open on the table beside a "
         "cup of tea and a pencil worn short from use").split()
FIRST = "Ada Ben Cleo Dev Eli Fay Gus Hana Ivo Jun Kai Lena Milo Nia Omar Pia Quin Rae Sol Tess Uma Vik Wren Yara Zed".split()
LAST = "Abbott Baker Chen Duarte Ellis Fischer Garcia Haddad Ito Jensen Kowalski Lopez Moreau Nakamura Okafor Patel".split()
# apksim's crawler skips controls labelled with these (scripts/crawl.py DEFAULT_SKIP); none may appear above.
SKIPPED = set("delete remove erase clear reset sign out log logout purchase buy pay checkout order subscribe "
              "unsubscribe send submit post publish share uninstall deactivate close account cancel confirm transfer "
              "withdraw donate".split())
assert not SKIPPED & {w.lower() for w in NOUNS + ADJ + VERBS + WORDS + FIRST + LAST}

ICONS = ("Home Star Favorite Person Info List Search ShoppingCart Notifications Email Phone Place DateRange Edit Add "
         "Check Settings ThumbUp Build Face Lock Refresh Warning AccountCircle AccountBox Call CheckCircle Create Done "
         "LocationOn MailOutline PlayArrow").split()
# Accent palettes: (primary, container) as ARGB.
PALETTE = [(0xFF3F51B5, 0xFFE8EAF6), (0xFF00897B, 0xFFE0F2F1), (0xFFD81B60, 0xFFFCE4EC), (0xFF6D4C41, 0xFFEFEBE9),
           (0xFF5E35B1, 0xFFEDE7F6), (0xFF039BE5, 0xFFE1F5FE), (0xFF7CB342, 0xFFF1F8E9), (0xFFF4511E, 0xFFFBE9E7),
           (0xFF546E7A, 0xFFECEFF1), (0xFFC0CA33, 0xFFF9FBE7)]
KINDS = ["list", "grid", "form", "tabs", "pager", "dashboard", "settings", "dialogs", "rows", "detail", "article", "chips"]


def title_for(r):
    return f"{r.choice(ADJ)} {r.choice(NOUNS)}"


def sentence(r, n):
    return " ".join(r.choice(WORDS) for _ in range(n)).capitalize() + "."


def kstr(s):
    return json.dumps(s, ensure_ascii=False).replace("$", "\\$")


# ---------------------------------------------------------------------------------------------------------- model

def make_screen(r, sid, kind, section, parent, depth, a, used):
    lo, hi = a.list_items
    title = title_for(r)
    while title in used:  # every screen's title is its own, so a map's screens can be told apart by name
        title = title_for(r)
    used.add(title)
    return {"id": sid, "kind": kind, "section": section, "parent": parent, "depth": depth, "children": [], "links": [],
            "title": title, "seed": r.randrange(1 << 30), "accent": r.randrange(len(PALETTE)),
            "pad": r.choice([8, 12, 16, 20]), "animated": False, "items": r.randint(lo, hi), "blocks": r.randint(2, 5)}


def build_model(a):
    r = random.Random(a.seed)
    screens, sections, order, used = {}, [], [], set()
    for i in range(max(1, min(a.sections, 5))):
        sid = f"s{len(screens)}"
        screens[sid] = make_screen(r, sid, r.choice(["list", "dashboard", "grid", "rows"]), i, None, 0, a, used)
        sections.append({"root": sid, "label": r.choice(NOUNS), "icon": r.choice(ICONS[:12])})
        order.append(sid)
    while len(screens) < a.screens:
        open_ = [s for s in screens.values() if s["depth"] < a.depth and len(s["children"]) < a.fanout]
        if not open_:
            break
        # Of three candidates, the shallowest with the fewest children: bushy trees rather than long chains.
        p = min(r.sample(open_, min(3, len(open_))), key=lambda s: (s["depth"], len(s["children"])))
        sid = f"s{len(screens)}"
        screens[sid] = make_screen(r, sid, r.choice(KINDS), p["section"], p["id"], p["depth"] + 1, a, used)
        p["children"].append(sid)
        order.append(sid)
    ids = list(screens)
    for sid in ids:
        if r.random() < a.links:
            t = r.choice(ids)
            if t != sid and t not in screens[sid]["children"]:
                screens[sid]["links"].append(t)
    for sid in r.sample(ids[len(sections):], min(a.animated, max(0, len(ids) - len(sections)))):
        screens[sid]["animated"] = True
    return {"seed": a.seed, "sections": sections, "screens": screens, "order": order}


def mutate(model, spec, mseed, a):
    """Applies KIND=N mutations and returns what changed: the ground truth a diff of the two builds should find."""
    r = random.Random(mseed)
    S = model["screens"]
    roots = {sec["root"] for sec in model["sections"]}
    changes, touched = [], set()

    def pick(pred):
        cands = sorted((s for s in S.values() if pred(s) and s["id"] not in touched and not s["animated"]), key=lambda s: s["id"])
        if not cands:
            return None
        s = r.choice(cands)
        touched.add(s["id"])
        return s

    for kind, n in spec:
        for _ in range(n):
            if kind == "restyle":
                s = pick(lambda s: True)
                if not s: break
                s["accent"] = (s["accent"] + 1 + r.randrange(len(PALETTE) - 1)) % len(PALETTE)
                s["pad"] = 28 if s["pad"] != 28 else 4
                changes.append({"kind": kind, "id": s["id"], "title": s["title"], "expect": "modified", "reason": "visual"})
            elif kind == "retext":
                s = pick(lambda s: True)
                if not s: break
                s["seed"] = r.randrange(1 << 30)  # new words in the body; the title stays
                changes.append({"kind": kind, "id": s["id"], "title": s["title"], "expect": "modified", "reason": "text"})
            elif kind == "restructure":
                s = pick(lambda s: True)
                if not s: break
                s["blocks"] = s["blocks"] + 2 if s["blocks"] < 5 else s["blocks"] - 2
                changes.append({"kind": kind, "id": s["id"], "title": s["title"], "expect": "modified", "reason": "structure"})
            elif kind == "relink":
                s = pick(lambda s: True)
                if not s: break
                t = r.choice(sorted(x for x in S if x != s["id"] and x not in s["children"] and x not in s["links"]))
                s["links"] = [t] + s["links"][1:]
                changes.append({"kind": kind, "id": s["id"], "title": s["title"], "expect": "modified", "reason": "routes", "to": S[t]["title"]})
            elif kind == "add":
                p = pick(lambda s: s["depth"] < a.depth)
                if not p: break
                i = len(S)
                while f"s{i}" in S:
                    i += 1
                sid = f"s{i}"
                c = make_screen(r, sid, r.choice(KINDS), p["section"], p["id"], p["depth"] + 1, a, {x["title"] for x in S.values()})
                S[sid] = c
                p["children"].append(sid)
                model["order"].append(sid)
                touched.add(sid)
                changes.append({"kind": kind, "id": sid, "title": c["title"], "expect": "added", "parent": p["title"]})
                changes.append({"kind": "add-parent", "id": p["id"], "title": p["title"], "expect": "modified", "reason": "routes"})
            elif kind == "remove":
                s = pick(lambda s: not s["children"] and s["id"] not in roots)
                if not s: break
                for o in S.values():
                    if s["id"] in o["children"] or s["id"] in o["links"]:
                        o["children"] = [c for c in o["children"] if c != s["id"]]
                        o["links"] = [c for c in o["links"] if c != s["id"]]
                        changes.append({"kind": "remove-parent", "id": o["id"], "title": o["title"], "expect": "modified", "reason": "routes"})
                del S[s["id"]]
                model["order"].remove(s["id"])
                changes.append({"kind": kind, "id": s["id"], "title": s["title"], "expect": "removed"})
            else:
                sys.exit(f"mapgen: unknown mutation {kind!r} (restyle, retext, restructure, relink, add, remove)")
    return changes


# ---------------------------------------------------------------------------------------------------------- images

def png(w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(pixel(x, y))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def make_image(seed, w=240, h=160):
    r = random.Random(seed)
    c1 = [r.randrange(40, 230) for _ in range(3)]
    c2 = [r.randrange(40, 230) for _ in range(3)]
    style, cx, cy, rad, stripe = r.randrange(4), r.randrange(w), r.randrange(h), r.randrange(20, 70), r.randrange(8, 24)

    def px(x, y):
        t = (x + y) / (w + h)
        base = [int(p * (1 - t) + q * t) for p, q in zip(c1, c2)]
        if style == 0 and (x - cx) ** 2 + (y - cy) ** 2 < rad * rad:
            return [255 - v for v in base]
        if style == 1 and (x // stripe) % 2 == 0:
            return [min(255, v + 40) for v in base]
        if style == 2 and ((x // stripe) + (y // stripe)) % 2 == 0:
            return [max(0, v - 50) for v in base]
        if style == 3 and abs(y - h // 2 - int(30 * math.sin(x / 15))) < 6:
            return [250, 250, 250]
        return base
    return png(w, h, px)


# ---------------------------------------------------------------------------------------------------------- kotlin

def fn(sid):
    return "Screen" + sid.upper()


def nav_button(target, S, label=None, filled=False):
    t = S[target]
    lab = label or f"{random.Random(t['seed']).choice(VERBS)} {t['title']}"
    kind = "Button" if filled else "OutlinedButton"
    return f'{kind}(onClick = {{ nav.navigate("{target}") }}, modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {{ Text({kstr(lab)}) }}'


def blocks(s, r):
    """s['blocks'] blocks of extra content: what `restructure` changes."""
    b = []
    for i in range(s["blocks"]):
        t = r.randrange(4)
        if t == 0:
            b.append(f'ElevatedCard(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {{ Text({kstr(sentence(r, 10))}, Modifier.padding(12.dp)) }}')
        elif t == 1:
            b.append(f'Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {{ Icon(Icons.Filled.{r.choice(ICONS)}, null, tint = accent); Text({kstr(title_for(r))}, Modifier.padding(start = 8.dp)) }}')
        elif t == 2:
            v = f'b{i}'
            b.append(f'var {v} by remember {{ mutableStateOf(false) }}\nRow(verticalAlignment = Alignment.CenterVertically) {{ Checkbox({v}, {{ {v} = it }}); Text({kstr(sentence(r, 5))}) }}')
        else:
            b.append(f'Text({kstr(sentence(r, 16))}, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 4.dp))')
    return b


def links(s, S):
    """Navigation goes in nav_row, at the top; the body has none (so a walk that tries only a screen's first controls
    still reaches every screen)."""
    return []


def nav_row(s, S):
    """The screen's way onward, under its top bar: a button per child (the first filled) and per link elsewhere."""
    if not s["children"] and not s["links"]:
        return ""
    b = [nav_button(c, S, filled=i == 0).replace("Modifier.fillMaxWidth().padding(vertical = 2.dp)", "Modifier.padding(end = 6.dp)")
         for i, c in enumerate(s["children"])]
    b += [nav_button(t, S, label=f"Jump to {S[t]['title']}").replace("Modifier.fillMaxWidth().padding(vertical = 2.dp)", "Modifier.padding(end = 6.dp)")
          for t in s["links"]]
    return "FlowRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {\n" + "\n".join(b) + "\n}\n"


def column(lines, pad=True, weight=False):
    m = "Modifier" + (".weight(1f)" if weight else ".fillMaxSize()") + ".verticalScroll(rememberScrollState())" + (".padding(horizontal = pad.dp)" if pad else "")
    return f"Column({m}) {{\n" + "\n".join(lines) + "\n}"


def lazy(rows, s, S, r):
    """A LazyColumn of rows, then the screen's blocks and links as items at its end."""
    tail = [f"Column(Modifier.padding(horizontal = 16.dp)) {{\n" + "\n".join(blocks(s, r) + links(s, S)) + "\n}"]
    return "LazyColumn(Modifier.fillMaxSize()) {\n" + "\n".join(f"item {{\n{x}\n}}" for x in rows + tail) + "\n}"


def body(s, S, a):
    r = random.Random(s["seed"])
    kids, n, k, sid = s["children"], s["items"], s["kind"], s["id"]

    def img(i):
        return f"R.drawable.img_{(s['seed'] + i) % a.images:02d}"

    def target(i):
        # A row leads to a child screen if there are any, else to the shared item page.
        return f'"{kids[i % len(kids)]}"' if kids else f'"item/{sid}/{i}"'

    if k == "list":
        rows = []
        for i in range(n):
            who = f"{r.choice(FIRST)} {r.choice(LAST)}"
            lead = (f"Image(painterResource({img(i)}), null, Modifier.size(48.dp).clip(CircleShape), contentScale = ContentScale.Crop)"
                    if i % 3 == 0 else f"Icon(Icons.Filled.{r.choice(ICONS)}, null, tint = accent)")
            rows.append(f'Row(Modifier.fillMaxWidth().clickable {{ nav.navigate({target(i)}) }}.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {{\n'
                        f'{lead}\nColumn(Modifier.weight(1f).padding(start = 12.dp)) {{ Text({kstr(who)}, style = MaterialTheme.typography.titleSmall); '
                        f'Text({kstr(sentence(r, 6))}, style = MaterialTheme.typography.bodySmall, maxLines = 1) }}\n'
                        f'Text("{r.randint(1, 59)}m", style = MaterialTheme.typography.labelSmall)\n}}\nHorizontalDivider()')
        return lazy(rows, s, S, r)
    if k == "grid":
        cells = [f'Card(Modifier.padding(4.dp).clickable {{ nav.navigate({target(i)}) }}) {{ Image(painterResource({img(i)}), {kstr(title_for(r))}, Modifier.fillMaxWidth().aspectRatio(1.5f), contentScale = ContentScale.Crop); '
                 f'Text({kstr(title_for(r))}, Modifier.padding(8.dp), style = MaterialTheme.typography.labelLarge, maxLines = 1) }}' for i in range(n)]
        tail = "Column(Modifier.padding(horizontal = 12.dp)) {\n" + "\n".join(blocks(s, r) + links(s, S)) + "\n}"
        return (f"LazyVerticalGrid(columns = GridCells.Fixed({r.choice([2, 2, 3])}), modifier = Modifier.fillMaxSize()) {{\n"
                + "\n".join(f"item {{ {c} }}" for c in cells) + f"\nitem(span = {{ GridItemSpan(maxLineSpan) }}) {{\n{tail}\n}}\n}}")
    if k == "rows":
        rws = []
        for i in range(max(3, n // 8)):
            cnt = r.randint(5, 14)
            to = f'"{kids[i % len(kids)]}"' if kids else f'"item/{sid}/" + j'
            rws.append(f'Text({kstr(r.choice(ADJ) + " " + r.choice(NOUNS))}, Modifier.padding(16.dp, 12.dp, 16.dp, 4.dp), style = MaterialTheme.typography.titleMedium)\n'
                       f'LazyRow(contentPadding = PaddingValues(horizontal = 12.dp)) {{ items({cnt}) {{ j -> Card(Modifier.width(140.dp).padding(4.dp).clickable {{ nav.navigate({to}) }}) {{ '
                       f'Image(painterResource(imgs[(j + {(s["seed"] + i) % 97}) % imgs.size]), null, Modifier.fillMaxWidth().height(90.dp), contentScale = ContentScale.Crop); '
                       f'Text("{r.choice(NOUNS)} ${{j + 1}}", Modifier.padding(6.dp)) }} }} }}')
        return lazy(rws, s, S, r)
    if k == "form":
        f = []
        for i in range(r.randint(3, 6)):
            lab = r.choice(["Name", "City", "Note", "Title", "Street", "Code", "Nickname", "Company", "Tag"])
            f.append(f'var f{i} by remember {{ mutableStateOf("") }}\nOutlinedTextField(f{i}, {{ f{i} = it }}, label = {{ Text({kstr(lab)}) }}, modifier = Modifier.fillMaxWidth())')
        f.append(f'var sw by remember {{ mutableStateOf(false) }}\nRow(verticalAlignment = Alignment.CenterVertically) {{ Switch(sw, {{ sw = it }}); Text({kstr(title_for(r))}, Modifier.padding(start = 8.dp)) }}')
        f.append(f'var sl by remember {{ mutableFloatStateOf({r.randint(1, 9) / 10}f) }}\nSlider(sl, {{ sl = it }})')
        f.append('var ra by remember { mutableIntStateOf(0) }\n' + "\n".join(
            f'Row(verticalAlignment = Alignment.CenterVertically) {{ RadioButton(ra == {i}, {{ ra = {i} }}); Text({kstr(title_for(r))}) }}' for i in range(3)))
        f.append(f'var cb by remember {{ mutableStateOf(true) }}\nRow(verticalAlignment = Alignment.CenterVertically) {{ Checkbox(cb, {{ cb = it }}); Text({kstr(sentence(r, 4))}) }}')
        return column(f + blocks(s, r) + links(s, S))
    if k == "tabs":
        tabs = [r.choice(NOUNS) for _ in range(r.randint(2, 4))]
        pages = [f"{ti} -> Column(Modifier.padding(16.dp)) {{\n" + "\n".join(
            f"Text({kstr(sentence(r, r.randint(6, 14)))}, Modifier.padding(vertical = 4.dp))" for _ in range(r.randint(3, 8))) + "\n}" for ti in range(len(tabs))]
        return ('var tab by remember { mutableIntStateOf(0) }\nPrimaryTabRow(selectedTabIndex = tab) {\n'
                + "\n".join(f'Tab(tab == {i}, {{ tab = {i} }}, text = {{ Text({kstr(t)}) }})' for i, t in enumerate(tabs)) + "\n}\n"
                + "Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = pad.dp)) {\nwhen (tab) {\n"
                + "\n".join(pages) + "\n}\n" + "\n".join(blocks(s, r) + links(s, S)) + "\n}")
    if k == "pager":
        pages = r.randint(3, 7)
        return (f'val ps = rememberPagerState {{ {pages} }}\nHorizontalPager(ps, Modifier.fillMaxWidth().height(220.dp)) {{ p ->\n'
                f'Box(Modifier.fillMaxSize().padding(12.dp)) {{ Image(painterResource(imgs[(p + {s["seed"] % 97}) % imgs.size]), null, Modifier.fillMaxSize().clip(RoundedCornerShape(16.dp)), contentScale = ContentScale.Crop)\n'
                f'Text("Page ${{p + 1}} of {pages}", Modifier.align(Alignment.BottomStart).background(Color(0x99000000)).padding(8.dp), color = Color.White) }}\n}}\n'
                + column(blocks(s, r) + links(s, S), weight=True))
    if k == "dashboard":
        vals = [r.randint(5, 95) for _ in range(r.randint(5, 12))]
        stats = [(r.choice(NOUNS), r.randint(10, 9999)) for _ in range(4)]

        def card_row(lst):
            return "Row(Modifier.fillMaxWidth()) {\n" + "\n".join(
                f'Card(Modifier.weight(1f).padding(4.dp)) {{ Column(Modifier.padding(12.dp)) {{ Text({kstr(l)}, style = MaterialTheme.typography.labelMedium); '
                f'Text("{v}", style = MaterialTheme.typography.headlineSmall, color = accent) }} }}' for l, v in lst) + "\n}"
        return column([card_row(stats[:2]), card_row(stats[2:]),
                       f'Card(Modifier.fillMaxWidth().padding(4.dp)) {{ Canvas(Modifier.fillMaxWidth().height(160.dp).padding(12.dp)) {{ val v = listOf({", ".join(f"{x}f" for x in vals)}); val bw = size.width / v.size\n'
                       f'v.forEachIndexed {{ i, x -> drawRect(accent, Offset(i * bw + bw * 0.15f, size.height * (1 - x / 100f)), Size(bw * 0.7f, size.height * x / 100f)) }} }} }}',
                       f'LinearProgressIndicator(progress = {{ {r.randint(1, 9) / 10}f }}, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), color = accent)',
                       f'Row(verticalAlignment = Alignment.CenterVertically) {{ CircularProgressIndicator(progress = {{ {r.randint(1, 9) / 10}f }}, color = accent); Text({kstr(sentence(r, 5))}, Modifier.padding(start = 12.dp)) }}',
                       ] + blocks(s, r) + links(s, S))
    if k == "settings":
        rows = []
        for i in range(r.randint(6, 14)):
            if i % 4 == 3:
                rows.append(f'Text({kstr(r.choice(ADJ) + " options")}, Modifier.padding(0.dp, 16.dp, 0.dp, 4.dp), color = accent, style = MaterialTheme.typography.labelLarge)')
            else:
                rows.append(f'var t{i} by remember {{ mutableStateOf({"true" if r.random() < .5 else "false"}) }}\n'
                            f'ListItem(headlineContent = {{ Text({kstr(title_for(r))}) }}, supportingContent = {{ Text({kstr(sentence(r, 6))}) }}, trailingContent = {{ Switch(t{i}, {{ t{i} = it }}) }})')
        return column(rows + blocks(s, r) + links(s, S))
    if k == "dialogs":
        return column([
            'var dlg by remember { mutableStateOf(false) }\nvar sheet by remember { mutableStateOf(false) }\nvar menu by remember { mutableStateOf(false) }',
            f'Button(onClick = {{ dlg = true }}) {{ Text({kstr("Open " + r.choice(NOUNS) + " dialog")}) }}',
            f'Button(onClick = {{ sheet = true }}) {{ Text({kstr("Open " + r.choice(NOUNS) + " sheet")}) }}',
            f'Box {{ OutlinedButton(onClick = {{ menu = true }}) {{ Text({kstr(r.choice(ADJ) + " menu")}) }}\nDropdownMenu(menu, {{ menu = false }}) {{\n'
            + "\n".join(f'DropdownMenuItem(text = {{ Text({kstr(title_for(r))}) }}, onClick = {{ menu = false }})' for _ in range(4)) + "\n} }",
            f'if (dlg) AlertDialog(onDismissRequest = {{ dlg = false }}, confirmButton = {{ TextButton({{ dlg = false }}) {{ Text("OK") }} }}, '
            f'title = {{ Text({kstr(title_for(r))}) }}, text = {{ Text({kstr(sentence(r, 12))}) }})',
            'if (sheet) ModalBottomSheet(onDismissRequest = { sheet = false }) { Column(Modifier.padding(16.dp)) {\n'
            + "\n".join(f'ListItem(headlineContent = {{ Text({kstr(title_for(r))}) }}, leadingContent = {{ Icon(Icons.Filled.{r.choice(ICONS)}, null) }})' for _ in range(r.randint(3, 6))) + "\n} }",
        ] + blocks(s, r) + links(s, S))
    if k in ("detail", "article"):
        head = [f'Image(painterResource({img(0)}), null, Modifier.fillMaxWidth().height(200.dp).padding(top = 8.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)',
                f'Text({kstr(title_for(r))}, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 12.dp))',
                f'Text({kstr(f"{r.choice(FIRST)} {r.choice(LAST)} · {r.randint(2, 28)} min read")}, style = MaterialTheme.typography.labelMedium, color = accent)']
        if k == "detail":
            head.append("FlowRow {\n" + "\n".join(f'AssistChip(onClick = {{}}, label = {{ Text({kstr(r.choice(NOUNS))}) }}, modifier = Modifier.padding(end = 6.dp))' for _ in range(r.randint(2, 6))) + "\n}")
        paras = [f'Text({kstr(sentence(r, r.randint(14, 40)))}, Modifier.padding(vertical = 6.dp), style = MaterialTheme.typography.bodyLarge)'
                 for _ in range(r.randint(3, 9 if k == "article" else 4))]
        return column(head + paras + blocks(s, r) + links(s, S))
    if k == "chips":
        tags = sorted({r.choice(NOUNS) for _ in range(r.randint(6, 14))})
        return column(['val sel = remember { mutableStateListOf<Int>() }',
                       "FlowRow {\n" + "\n".join(f'FilterChip({i} in sel, {{ if ({i} in sel) sel.remove({i}) else sel.add({i}) }}, label = {{ Text({kstr(t)}) }}, modifier = Modifier.padding(end = 6.dp))' for i, t in enumerate(tags)) + "\n}",
                       'Text(if (sel.isEmpty()) "Nothing selected" else "${sel.size} selected", style = MaterialTheme.typography.labelLarge)']
                      + [f'ListItem(headlineContent = {{ Text({kstr(title_for(r))}) }}, supportingContent = {{ Text({kstr(sentence(r, 8))}) }}, leadingContent = {{ Icon(Icons.Filled.{r.choice(ICONS)}, null, tint = accent) }})'
                         for _ in range(r.randint(3, 8))] + blocks(s, r) + links(s, S))
    raise ValueError(k)


def screen_kt(s, S, a):
    accent, container = PALETTE[s["accent"]]
    anim = ""
    if s["animated"]:
        anim = ('val inf = rememberInfiniteTransition(label = "spin")\nval ang by inf.animateFloat(0f, 360f, infiniteRepeatable(tween(1600, easing = LinearEasing)), label = "a")\n'
                'Canvas(Modifier.fillMaxWidth().height(36.dp)) { rotate(ang) { drawRect(accent, Offset(size.width / 2 - 14f, 4f), Size(28f, 28f)) } }\n')
    return (f'@Composable\nfun {fn(s["id"])}(nav: NavController) {{\nval accent = Color(0x{accent:08X}); val pad = {s["pad"]}\n'
            f'ScreenFrame({kstr(s["title"])}, Color(0x{container:08X}), accent, nav, root = {"true" if s["parent"] is None else "false"}) {{\n'
            f'{nav_row(s, S)}{anim}{body(s, S, a)}\n}}\n}}\n')


HEADER = """@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@file:Suppress("UNUSED_VARIABLE", "UnusedImport")
package {pkg}

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.shape.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.*
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.*
import androidx.navigation.NavController
"""

MAIN = """@file:OptIn(ExperimentalMaterial3Api::class)
package {pkg}

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.*

val imgs = listOf({imgs})

class MainActivity : ComponentActivity() {{
  override fun onCreate(savedInstanceState: Bundle?) {{
    super.onCreate(savedInstanceState)
    setContent {{ MaterialTheme {{ App() }} }}
  }}
}}

data class Section(val route: String, val label: String, val icon: ImageVector)
val sections = listOf({sections})

@Composable
fun App() {{
  val nav = rememberNavController()
  val entry by nav.currentBackStackEntryAsState()
  Scaffold(bottomBar = {{
    NavigationBar {{
      sections.forEach {{ s ->
        NavigationBarItem(selected = entry?.destination?.route == s.route, onClick = {{
          nav.navigate(s.route) {{ {tabnav} }}
        }}, icon = {{ Icon(s.icon, null) }}, label = {{ Text(s.label) }})
      }}
    }}
  }}) {{ inner ->
    NavHost(nav, startDestination = "{start}", modifier = Modifier.padding(inner)) {{
{routes}
      composable("item/{{sid}}/{{n}}") {{ e -> ItemDetail(e.arguments?.getString("sid") ?: "", e.arguments?.getString("n")?.toIntOrNull() ?: 0, nav) }}
    }}
  }}
}}

@Composable
fun ScreenFrame(title: String, container: Color, accent: Color, nav: NavController, root: Boolean, content: @Composable ColumnScope.() -> Unit) {{
  Column(Modifier.fillMaxSize()) {{
    TopAppBar(title = {{ Text(title) }}, colors = TopAppBarDefaults.topAppBarColors(containerColor = container, titleContentColor = accent),
      navigationIcon = {{ if (!root) IconButton(onClick = {{ nav.popBackStack() }}) {{ Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }} }})
    content()
  }}
}}

/** The page of a list row that leads to no child screen: one structure whatever the row. */
@Composable
fun ItemDetail(sid: String, n: Int, nav: NavController) {{
  ScreenFrame("Item ${{n + 1}}", Color(0xFFF5F5F5), Color(0xFF424242), nav, root = false) {{
    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {{
      Image(painterResource(imgs[(n + sid.length) % imgs.size]), null, Modifier.fillMaxWidth().height(180.dp), contentScale = ContentScale.Crop)
      Text("Item ${{n + 1}} of $sid", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 12.dp))
      Text("Details for this entry, with its notes, history and related places.", Modifier.padding(vertical = 8.dp))
      var fav by remember {{ mutableStateOf(false) }}
      Row(verticalAlignment = Alignment.CenterVertically) {{ Checkbox(fav, {{ fav = it }}); Text("Keep for later") }}
    }}
  }}
}}
"""

GRADLE_SETTINGS = """pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
  repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
  repositories { google(); mavenCentral() }
}
rootProject.name = "MapGen"
include(":app")
"""
GRADLE_ROOT = """plugins {
  id("com.android.application") version "9.0.1" apply false
  id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
}
"""
GRADLE_APP = """plugins {{
  id("com.android.application")
  id("org.jetbrains.kotlin.plugin.compose")
}}
android {{
  namespace = "{pkg}"
  compileSdk = 36
  defaultConfig {{ applicationId = "{pkg}"; minSdk = 26; targetSdk = 36; versionCode = {version}; versionName = "{version}.0" }}
  buildTypes {{ release {{ isMinifyEnabled = false }} }}
  compileOptions {{ sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }}
  buildFeatures {{ compose = true; buildConfig = false; aidl = false; shaders = false }}
  packaging {{ resources {{ excludes += "/META-INF/{{AL2.0,LGPL2.1}}" }} }}
}}
kotlin {{ jvmToolchain(17) }}
dependencies {{
  implementation(platform("androidx.compose:compose-bom:2026.03.01"))
  implementation("androidx.core:core-ktx:1.18.0")
  implementation("androidx.activity:activity-compose:1.13.0")
  implementation("androidx.compose.ui:ui")
  implementation("androidx.compose.material3:material3")
  implementation("androidx.compose.material:material-icons-core")
  implementation("androidx.navigation:navigation-compose:2.9.6")
}}
"""
MANIFEST = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="{label}" android:theme="@android:style/Theme.Material.Light.NoActionBar">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
    </activity>
  </application>
</manifest>
"""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def render(model, a, out):
    S, pkg = model["screens"], a.package
    src = os.path.join(out, "app/src/main")
    kdir = os.path.join(src, "java", *pkg.split("."))
    if os.path.isdir(os.path.join(out, "app/src")):
        shutil.rmtree(os.path.join(out, "app/src"))
    write(os.path.join(out, "settings.gradle.kts"), GRADLE_SETTINGS)
    write(os.path.join(out, "build.gradle.kts"), GRADLE_ROOT)
    write(os.path.join(out, "gradle.properties"), "org.gradle.jvmargs=-Xmx4g\nandroid.useAndroidX=true\n")
    write(os.path.join(out, "app/build.gradle.kts"), GRADLE_APP.format(pkg=pkg, version=a.version))
    write(os.path.join(src, "AndroidManifest.xml"), MANIFEST.format(label=f"MapGen {a.seed}"))
    write(os.path.join(out, "local.properties"), f"sdk.dir={os.environ.get('ANDROID_HOME') or os.path.expanduser('~/Library/Android/sdk')}\n")
    tpl = os.path.join(HERE, "template")
    os.makedirs(os.path.join(out, "gradle/wrapper"), exist_ok=True)
    shutil.copy(os.path.join(tpl, "gradlew"), os.path.join(out, "gradlew"))
    for f in ("gradle-wrapper.jar", "gradle-wrapper.properties"):
        shutil.copy(os.path.join(tpl, "gradle/wrapper", f), os.path.join(out, "gradle/wrapper", f))
    os.chmod(os.path.join(out, "gradlew"), 0o755)
    dd = os.path.join(src, "res/drawable-nodpi")
    os.makedirs(dd, exist_ok=True)
    for i in range(a.images):
        with open(os.path.join(dd, f"img_{i:02d}.png"), "wb") as f:
            f.write(make_image(a.seed * 1000 + i))
    by_sec = {}
    for sid in model["order"]:
        by_sec.setdefault(S[sid]["section"], []).append(S[sid])
    for sec, lst in by_sec.items():
        for part in range(0, len(lst), 40):  # files of at most 40 screens, so the compiler is not fed one huge file
            write(os.path.join(kdir, f"Section{sec}_{part // 40}.kt"),
                  HEADER.format(pkg=pkg) + "\n" + "\n".join(screen_kt(s, S, a) for s in lst[part:part + 40]))
    routes = "\n".join(f'      composable("{sid}") {{ {fn(sid)}(nav) }}' for sid in model["order"])
    secs = ", ".join(f'Section("{sec["root"]}", {kstr(sec["label"])}, Icons.Filled.{sec["icon"]})' for sec in model["sections"])
    write(os.path.join(kdir, "Main.kt"), MAIN.format(pkg=pkg, imgs=", ".join(f"R.drawable.img_{i:02d}" for i in range(a.images)),
                                                     sections=secs, start=model["sections"][0]["root"], routes=routes,
                                                     tabnav=("popUpTo(nav.graph.findStartDestination().id) { saveState = true }; launchSingleTop = true; restoreState = true"
                                                             if a.keep_section_state else "popUpTo(nav.graph.findStartDestination().id); launchSingleTop = true")))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", required=True, help="project folder to write (its app/src is replaced)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--screens", type=int, default=150, help="screens in all, section roots included (default 150)")
    p.add_argument("--sections", type=int, default=4, help="bottom bar sections, 1 to 5 (default 4)")
    p.add_argument("--depth", type=int, default=5, help="deepest screen below a section root (default 5)")
    p.add_argument("--fanout", type=int, default=4, help="most children of one screen (default 4)")
    p.add_argument("--list-items", default="20-80", help="rows of a list screen, MIN-MAX (default 20-80)")
    p.add_argument("--images", type=int, default=24, help="distinct pictures in the app (default 24)")
    p.add_argument("--links", type=float, default=0.15, help="share of screens with a link to a screen elsewhere (default 0.15)")
    p.add_argument("--animated", type=int, default=0, help="screens with an endless animation (default 0)")
    p.add_argument("--keep-section-state", action="store_true",
                   help="a tab reopens its section where it was left (saveState/restoreState, as many apps do); by default "
                        "a tab opens the section's root, so where a tab leads does not depend on what was visited before")
    p.add_argument("--mutate", default="", help="KIND=N,... of restyle, retext, restructure, relink, add, remove")
    p.add_argument("--mutation-seed", type=int, default=1)
    p.add_argument("--package", default="dev.greenroom.mapgen")
    p.add_argument("--version", type=int, default=1, help="versionCode (default 1)")
    p.add_argument("--build", action="store_true", help="build with Gradle and copy the APK to OUT/app.apk")
    a = p.parse_args()
    lo, _, hi = a.list_items.partition("-")
    a.list_items = (int(lo), int(hi or lo))
    a.images = max(1, a.images)
    if a.screens < min(a.sections, 5):
        sys.exit("mapgen: --screens must be at least --sections")
    spec = []
    for part in filter(None, a.mutate.split(",")):
        k, _, n = part.partition("=")
        spec.append((k.strip(), int(n or 1)))

    model = build_model(a)
    changes = mutate(model, spec, a.mutation_seed, a) if spec else []
    os.makedirs(a.out, exist_ok=True)
    render(model, a, a.out)
    with open(os.path.join(a.out, "model.json"), "w") as f:
        json.dump({"args": {k: v for k, v in vars(a).items() if k not in ("out", "build")}, **model}, f, indent=1, sort_keys=True)
    with open(os.path.join(a.out, "mutations.json"), "w") as f:
        json.dump(changes, f, indent=1)
    kinds = {}
    for s in model["screens"].values():
        kinds[s["kind"]] = kinds.get(s["kind"], 0) + 1
    print(f"mapgen: {len(model['screens'])} screens in {len(model['sections'])} sections, deepest {max(s['depth'] for s in model['screens'].values())}, "
          f"{sum(len(s['links']) for s in model['screens'].values())} cross links, {a.images} images; "
          + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items())) + (f"; {len(changes)} changes in mutations.json" if changes else ""))
    if a.build:
        env = dict(os.environ)
        if "JAVA_HOME" not in env:
            jh = subprocess.run(["/usr/libexec/java_home", "-v", "17"], capture_output=True, text=True).stdout.strip()
            if jh:
                env["JAVA_HOME"] = jh
        r = subprocess.run(["./gradlew", "-q", "--console=plain", "assembleDebug"], cwd=a.out, env=env)
        if r.returncode:
            sys.exit(f"mapgen: the Gradle build failed ({r.returncode})")
        apk = os.path.join(a.out, "app.apk")
        shutil.copy(os.path.join(a.out, "app/build/outputs/apk/debug/app-debug.apk"), apk)
        print(f"mapgen: built {apk} ({os.path.getsize(apk) // 1024} KB)")


if __name__ == "__main__":
    main()

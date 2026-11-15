#!/usr/bin/env python3
"""Generates the app's Lottie animations (200x200, 60 fps, transparent).
Brand: cobalt #0B57A8, gold #D9A81E, success #1E7B45. Run: python3 tool/make_lottie.py"""
import json, math

def rgb(h): return [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)] + [1]
COBALT, GOLD, GREEN, WHITE, AMBER = rgb('#0B57A8'), rgb('#D9A81E'), rgb('#1E7B45'), rgb('#FFFFFF'), rgb('#F2C94C')
OUT = {"x": [0.16], "y": [1]}          # ease-out (arrivals)
INOUT = {"x": [0.45], "y": [0]}        # for loops (sine-like)

def st(v): return {"a": 0, "k": v}
def kf(frames, ease_out=True):
    """frames: [(t, value), ...]. Each segment eased."""
    k = []
    for i, (t, v) in enumerate(frames):
        e = {"t": t, "s": v if isinstance(v, list) else [v]}
        if i < len(frames) - 1:
            e["o"] = {"x": [0.3], "y": [0]} if ease_out else {"x": [0.45], "y": [0]}
            e["i"] = OUT if ease_out else {"x": [0.55], "y": [1]}
        k.append(e)
    return {"a": 1, "k": k}

def tr(p=(0, 0), a=(0, 0), s=(100, 100), r=0, o=100):
    return {"ty": "tr", "p": st(list(p)), "a": st(list(a)), "s": st(list(s)), "r": st(r), "o": st(o)}
def fill(c, o=100): return {"ty": "fl", "c": st(c), "o": st(o), "r": 1}
def stroke(c, w, o=100): return {"ty": "st", "c": st(c), "o": st(o), "w": st(w), "lc": 2, "lj": 2}
def ellipse(d, p=(0, 0)): return {"ty": "el", "p": st(list(p)), "s": st([d, d])}
def path(v, i=None, o=None, closed=False):
    z = [[0, 0]] * len(v)
    return {"ty": "sh", "ks": st({"v": v, "i": i or z, "o": o or z, "c": closed})}
def group(*items): return {"ty": "gr", "it": list(items) + [tr()]}

def layer(ind, name, shapes, op, p=(100, 100), a=(0, 0), s=None, r=None, o=None):
    ks = {"p": p if isinstance(p, dict) else st(list(p) + [0]),
          "a": st(list(a) + [0]),
          "s": s or st([100, 100, 100]),
          "r": r or st(0),
          "o": o or st(100)}
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1, "ks": ks, "ao": 0,
            "shapes": shapes, "ip": 0, "op": op, "st": 0, "bm": 0}

def comp(name, op, layers):
    return {"v": "5.7.0", "fr": 60, "ip": 0, "op": op, "w": 200, "h": 200, "nm": name,
            "ddd": 0, "assets": [], "layers": layers}

def s3(v): return [v, v, 100]

# 1) goal reached: disc pops, check draws, confetti bursts (plays once)
def goal():
    op = 90
    layers = []
    check = group(path([[-24, 2], [-7, 19], [26, -16]]),
                  {"ty": "tm", "s": st(0), "e": kf([(14, 0), (36, 100)]), "o": st(0), "m": 1},
                  stroke(WHITE, 11))
    layers.append(layer(1, "check", [check], op))
    layers.append(layer(2, "disc", [group(ellipse(92), fill(GREEN))], op,
                        s=kf([(0, s3(0)), (14, s3(112)), (22, s3(100))])))
    colors = [GOLD, COBALT, GREEN, GOLD, COBALT, GREEN, GOLD, COBALT, GREEN, GOLD]
    for n in range(10):
        ang = math.radians(n * 36 + 12)
        dist = 78 if n % 2 == 0 else 64
        end = [100 + dist * math.cos(ang), 100 + dist * math.sin(ang), 0]
        shape = ellipse(10) if n % 3 else {"ty": "rc", "p": st([0, 0]), "s": st([12, 6]), "r": st(2)}
        layers.append(layer(3 + n, f"confetti{n}", [group(shape, fill(colors[n]))], op,
                            p=kf([(10, [100, 100, 0]), (46, end)]),
                            r=kf([(10, 0), (70, 220 if n % 2 else -220)]),
                            o=kf([(10, 0), (14, 100), (52, 100), (72, 0)])))
    return comp("goal-reached", op, layers)

# 2) badge unlock: gold star pops with a ring and a sparkle (plays once)
def badge():
    op = 72
    star = {"ty": "sr", "sy": 1, "d": 1, "pt": st(5), "p": st([0, 0]), "r": st(0),
            "ir": st(22), "is": st(0), "or": st(46), "os": st(0)}
    return comp("badge-unlock", op, [
        layer(1, "sparkle", [group(
            {"ty": "sr", "sy": 1, "d": 1, "pt": st(4), "p": st([0, 0]), "r": st(0),
             "ir": st(3), "is": st(0), "or": st(13), "os": st(0)}, fill(WHITE))], op,
            p=(114, 88), s=kf([(24, s3(0)), (36, s3(120)), (50, s3(0))])),
        layer(2, "star", [group(star, fill(GOLD))], op,
              s=kf([(0, s3(0)), (16, s3(116)), (26, s3(100))]),
              r=kf([(0, -24), (26, 0)])),
        layer(3, "ring", [group(ellipse(100), stroke(GOLD, 5))], op,
              s=kf([(8, s3(60)), (44, s3(150))]),
              o=kf([(8, 0), (12, 90), (44, 0)])),
    ])

# 3) streak flame: gentle flicker (loops; first and last frame match)
def flame():
    op = 90
    v = [[0, -70], [38, 15], [0, 50], [-38, 15]]
    i = [[0, 0], [8, -38], [21, 0], [0, 22]]
    o = [[0, 0], [0, 22], [-21, 0], [-8, -38]]
    shape = path(v, i, o, True)
    def sway(a, b, c):
        return kf([(0, [100, 100, 100]), (22, [a, b, 100]), (45, [b, a, 100]),
                   (67, [c, b, 100]), (90, [100, 100, 100])], ease_out=False)
    return comp("streak-flame", op, [
        layer(1, "inner", [group(shape, fill(AMBER))], op, p=(100, 150), a=(0, 50),
              s=kf([(0, [52, 52, 100]), (30, [48, 58, 100]), (60, [55, 50, 100]),
                    (90, [52, 52, 100])], ease_out=False)),
        layer(2, "outer", [group(shape, fill(GOLD))], op, p=(100, 150), a=(0, 50),
              s=sway(96, 107, 103),
              r=kf([(0, 0), (30, 3), (60, -3), (90, 0)], ease_out=False)),
    ])

# 4) walker: a simple walk cycle for empty states (loops)
def walker():
    op = 72
    def limb(ind, name, origin, length, swing, phase):
        a, b = (swing, -swing) if phase == 0 else (-swing, swing)
        return layer(ind, name, [group(path([[0, 0], [0, length]]), stroke(COBALT, 10))], op,
                     p=origin, r=kf([(0, a), (36, b), (72, a)], ease_out=False))
    bob = lambda y: kf([(0, [100, y, 0]), (18, [100, y - 3, 0]), (36, [100, y, 0]),
                        (54, [100, y - 3, 0]), (72, [100, y, 0])], ease_out=False)
    return comp("walker", op, [
        limb(1, "arm-front", (100, 76), 34, 28, 0),
        limb(2, "leg-front", (100, 118), 46, 26, 1),
        layer(3, "torso", [group(path([[0, -42], [0, 0]]), stroke(COBALT, 11))], op, p=bob(118)),
        layer(4, "head", [group(ellipse(28), fill(COBALT))], op, p=bob(56)),
        limb(5, "leg-back", (100, 118), 46, 26, 0),
        limb(6, "arm-back", (100, 76), 34, 28, 1),
    ])

def name_everything(node, counter=[0]):
    """lottie's colour overrides need every shape to carry a name (nm)."""
    if isinstance(node, dict):
        if 'ty' in node and 'nm' not in node:
            counter[0] += 1
            node['nm'] = f"{node['ty']}{counter[0]}"
        for v in node.values():
            name_everything(v)
    elif isinstance(node, list):
        for v in node:
            name_everything(v)

for name, fn in [("goal_reached", goal), ("badge_unlock", badge),
                 ("streak_flame", flame), ("walker", walker)]:
    data = fn()
    name_everything(data)
    with open(f"assets/lottie/{name}.json", "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(name, len(json.dumps(data, separators=(",", ":"))), "bytes")

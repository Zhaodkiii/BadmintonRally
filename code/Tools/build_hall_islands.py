"""Build P009's individual scene textures from the approved production paintings.

The 800 x 450 landmarks are painting coordinates. The renderer reconstructs their
surfaces in world space with the projection recorded in paintedRiversideHall().
The master paintings and the registered overview are never bundled in the game.
"""

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def registered_wings(r):
    """Register the extensions separately on each side, keeping the central source."""
    src = cv2.imread(str(r / "河岸球馆-拆件绘景母版.png"))
    wide = cv2.imread(str(r / "河岸球馆-P009侧翼扩绘.jpg"))
    h, w = src.shape[:2]
    pad = round(w * 0.25)
    top = round(h * 0.23)
    bot = round(h * 0.20)
    sift = cv2.SIFT_create(nfeatures=13000)
    a, da = sift.detectAndCompute(src, None)
    b, db = sift.detectAndCompute(wide, None)
    good = [
        (a[x.queryIdx].pt, b[x.trainIdx].pt)
        for x, y in cv2.BFMatcher().knnMatch(da, db, k=2)
        if x.distance < 0.77 * y.distance
    ]
    if len(good) < 12:
        raise ValueError("Insufficient marks in production paintings")
    output = cv2.copyMakeBorder(src, 0, 0, pad, pad, cv2.BORDER_REPLICATE)
    X = np.arange(-pad, w + pad)[None, :]
    for side in [0, 1]:
        use = [
            (a, b)
            for a, b in good
            if (a[0] < w * 0.32 if side == 0 else a[0] > w * 0.67)
        ]
        fr = np.float32([b for a, b in use])
        to = np.float32([a for a, b in use])
        # Affine continuation is stable outside the original frame.
        T, inliers = cv2.estimateAffine2D(
            fr, to, method=cv2.RANSAC, ransacReprojThreshold=5, maxIters=5000
        )
        if T is None or inliers.sum() < 12:
            raise ValueError(f"Unable to register wing {side}")
        T[0, 2] += pad
        im = cv2.warpAffine(
            wide, T, (w + 2 * pad, h), borderMode=cv2.BORDER_REFLECT_101
        )
        alpha = (
            np.clip((w * 0.035 - X) / (w * 0.04), 0, 1)
            if side == 0
            else np.clip((X - w * 0.967) / (w * 0.04), 0, 1)
        )
        output = np.uint8(output * (1 - alpha[:, :, None]) + im * alpha[:, :, None])
    ceiling = cv2.imread(str(r / "河岸球馆-P009顶棚扩绘.jpg"))
    if ceiling is None:
        raise FileNotFoundError("Missing approved upward extension for the ceiling")
    # Match the upper part only. Far-wall points would bias perspective in the
    # extension, particularly at the cafe-side springing of the arch.
    anchor_kp, anchor_desc = sift.detectAndCompute(output[: h // 2], None)
    cap_kp, cap_desc = sift.detectAndCompute(ceiling, None)
    pairs = [
        (cap_kp[m.trainIdx].pt, anchor_kp[m.queryIdx].pt)
        for m, n in cv2.BFMatcher().knnMatch(anchor_desc, cap_desc, k=2)
        if m.distance < 0.75 * n.distance
    ]
    full_w = output.shape[1]
    transforms = []
    for center_x in [full_w * 0.15, full_w * 0.5, full_w * 0.85]:
        region = [(a, b) for a, b in pairs if abs(b[0] - center_x) < full_w * 0.26]
        if len(region) < 12:
            region = pairs
        fr, to = (np.float32(x) for x in zip(*region))
        T, inliers = cv2.estimateAffine2D(
            to, fr, method=cv2.RANSAC, ransacReprojThreshold=5, maxIters=5000
        )
        if T is None or inliers.sum() < 12:
            raise ValueError("Ceiling cannot be registered")
        transforms.append(T)
    yy, xx = np.mgrid[-top:36, 0:full_w].astype(np.float32)
    weights = [
        np.maximum(0, 1 - np.abs(xx / full_w - center) / 0.35)
        for center in [0.15, 0.50, 0.85]
    ]
    total = np.maximum(sum(weights), 0.001)
    map_x = np.zeros_like(xx)
    map_y = np.zeros_like(yy)
    for weight, T in zip(weights, transforms):
        map_x += (T[0, 0] * xx + T[0, 1] * yy + T[0, 2]) * weight / total
        map_y += (T[1, 0] * xx + T[1, 1] * yy + T[1, 2]) * weight / total
    cap = cv2.remap(
        ceiling, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101
    )
    mix = np.linspace(0, 1, 36, dtype=np.float32)[:, None, None]
    output[:36] = np.uint8(cap[top:] * (1 - mix) + output[:36] * mix)
    output = np.vstack([cap[:top], output, output[-bot:][::-1]])
    encoded = cv2.imencode(".jpg", output, [cv2.IMWRITE_JPEG_QUALITY, 97])[1]
    return src, cv2.imdecode(encoded, cv2.IMREAD_COLOR)


def export_islands(image, wide, out):
    out.mkdir(parents=True, exist_ok=True)
    H, W = image.shape[:2]
    scale = np.array([W / 800, H / 450])

    def poly(points):
        a = np.zeros((H, W), np.uint8)
        cv2.fillPoly(a, [np.round(np.array(points) * scale).astype(np.int32)], 255)
        return a

    def sub(mask, *others):
        for other in others:
            mask = cv2.subtract(mask, other)
        return mask

    # Arch follows the final beam from left springing point to the right.
    back = [
        (255, 178),
        (262, 165),
        (277, 151),
        (300, 140),
        (327, 132),
        (355, 127),
        (385, 124),
        (413, 127),
        (445, 134),
        (475, 146),
        (495, 157),
        (511, 174),
    ]
    roof = poly(
        [
            (0, 0),
            (800, 0),
            (800, 18),
            (733, 52),
            (655, 106),
            (579, 143),
            (524, 171),
            *back[::-1],
            (220, 159),
            (176, 133),
            (112, 96),
            (34, 57),
            (0, 58),
        ]
    )
    ground = poly(
        [
            (0, 343),
            (40, 335),
            (95, 316),
            (169, 283),
            (223, 267),
            (263, 253),
            (498, 253),
            (538, 262),
            (604, 285),
            (676, 312),
            (746, 330),
            (800, 348),
            (800, 451),
            (0, 451),
        ]
    )
    wall = poly([*back, (516, 257), (254, 257)])
    left = poly([(0, 0), (264, 0), (264, 451), (0, 451)])
    right = sub(np.full((H, W), 255, np.uint8), left)
    sideL = sub(left.copy(), roof, wall, ground)
    sideR = sub(right.copy(), roof, wall, ground)
    # The distant river opening is behind the steps. Faces on the apron and the
    # front steel column receive their own depth so they separate during motion.
    river = poly(
        [
            (573, 149),
            (648, 105),
            (799, 19),
            (800, 215),
            (747, 211),
            (738, 200),
            (723, 202),
            (714, 222),
            (684, 228),
            (677, 214),
            (660, 218),
            (651, 229),
            (582, 225),
        ]
    )
    river = cv2.bitwise_and(river, sideR)
    river = cv2.bitwise_and(
        river,
        poly([(578, 175), (657, 130), (716, 94), (800, 52), (800, 235), (575, 235)]),
    )
    cafe = poly(
        [
            (0, 101),
            (42, 88),
            (91, 101),
            (143, 121),
            (163, 145),
            (182, 171),
            (185, 194),
            (169, 195),
            (169, 276),
            (92, 303),
            (0, 330),
        ]
    )
    cafe = cv2.bitwise_and(cafe, sideL)
    column = poly(
        [
            (15, 0),
            (54, 0),
            (58, 36),
            (52, 42),
            (50, 76),
            (52, 238),
            (50, 332),
            (34, 336),
            (28, 328),
            (29, 79),
            (16, 73),
        ]
    )
    wall = cv2.bitwise_and(wall, cv2.bitwise_not(roof))
    groups = [
        ("Vault", roof),
        ("Terminal", wall),
        ("Quay", river),
        ("Cafe", cafe),
        ("LeftGallery", sub(sideL.copy(), cafe)),
        ("RightGallery", sub(sideR.copy(), river)),
        ("Apron", ground.copy()),
    ]
    # Keep the main play volume clear. All upper-level panels come from discrete
    # local texture islands; the framing painting is never installed in the bundle.
    # Left foreground spectator and pier form a near silhouette.
    col = cv2.bitwise_and(column, cv2.bitwise_or(roof, cv2.bitwise_or(cafe, sideL)))
    groups = [(key, sub(mask.copy(), col)) for key, mask in groups] + [("Pier", col)]
    # Extend the local UV islands into the registered gallery wings.
    pad = round(W * 0.25)
    top = round(H * 0.23)
    bot = round(H * 0.20)
    image = wide
    wideMasks = []
    for key, mask in groups:
        padded = cv2.copyMakeBorder(mask, top, bot, pad, pad, cv2.BORDER_REPLICATE)
        wideMasks.append((key, padded))
    groups = wideMasks
    data = []
    for key, mask in groups:
        # Neighbouring meshes share their boundary depth. Give both real source
        # texels across that margin instead of inventing a coloured halo.
        distance = cv2.distanceTransform(255 - mask, cv2.DIST_L2, 5)
        thick = np.uint8(np.clip(6 - distance, 0, 1) * 255)
        y, x = np.nonzero(thick)
        x0, x1 = int(x.min()), int(x.max() + 1)
        y0, y1 = int(y.min()), int(y.max() + 1)
        rgb = cv2.bitwise_and(image, image, mask=np.uint8(distance <= 8))
        rgba = cv2.merge([*cv2.split(rgb), thick])
        crop = rgba[y0:y1, x0:x1]
        cv2.imwrite(str(out / (key + ".png")), crop, [cv2.IMWRITE_PNG_COMPRESSION, 8])
        data.append(
            dict(
                name=key,
                rect=[
                    (x0 - pad) / W * 800,
                    (y0 - top) / H * 450,
                    (x1 - pad) / W * 800,
                    (y1 - top) / H * 450,
                ],
            )
        )
    (out / "Layout.json").write_text(json.dumps(data, indent=2))


if __name__ == "__main__":
    project = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--art", type=Path, default=project / "assets/美术/球场场景设定"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=project / "code/Clients/iOS/Resources/RiversideHall.scnassets",
    )
    args = parser.parse_args()
    export_islands(*registered_wings(args.art), args.output)

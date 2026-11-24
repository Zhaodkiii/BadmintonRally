"""Local RallyCapture review store and reproducible experimental RBF training."""
import argparse
import csv
from datetime import datetime
import json
from pathlib import Path
import sqlite3

import tempfile

import joblib
import numpy as np
from sklearn.metrics import classification_report
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC
from train_curves import CHANNELS, clock_fit, split, collect

ROOT = Path(__file__).resolve().parents[2] / "data/动作采集"
STORE = Path(__file__).resolve().parents[2] / "data/动作采集分析/本地训练台"
MATCH = ROOT / "比赛实时诊断"
TOOLS = Path(__file__).resolve().parent


def db():
    STORE.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(STORE / "reviews.sqlite")
    conn.row_factory = sqlite3.Row
    conn.execute("""create table if not exists reviews (
        session text, original real, peak real, label text, participant text,
        primary key(session,original))""")
    conn.execute("""create table if not exists specialist_audit (
        session text, original real, label text, status text, reason text, video_s real,
        primary key(session,original))""")
    return conn


def rows(path):
    with path.open(encoding="utf-8-sig") as file:
        return list(csv.DictReader(file))


def batches(session):
    for path in sorted((MATCH / session / "batches").glob("*.json")):
        yield json.loads(path.read_text())


def match_frames(session):
    samples = {f["t"]: f["v"][:6] for batch in batches(session) for f in batch["frames"]}
    return np.array([[t, *samples[t]] for t in sorted(samples)])


def sample_frames(session):
    if (MATCH / session).is_dir():
        return match_frames(session)
    return np.array([[float(r[c]) for c in ["t_phone", *CHANNELS]]
                     for r in rows(ROOT / session / "samples.csv")])


def aligned_video(session, peak):
    folder = ROOT / session
    segments = [folder] if folder.is_dir() else sorted((MATCH / session / "视频").glob("*"))
    for segment in segments:
        try:
            slope, offset = clock_fit(segment / "clocks.jsonl")
            frames = rows(segment / "frames.csv")
            host = peak * slope + offset
            if not frames or not float(frames[0]["t_mac"]) <= host <= float(frames[-1]["t_mac"]):
                continue
            frame = min(frames, key=lambda r: abs(float(r["t_mac"]) - host))
            if abs(float(frame["t_mac"]) - host) < .10 and (segment / "camera.mov").is_file():
                return segment / "camera.mov", float(frame["video_s"])
        except (OSError, KeyError, ValueError):
            continue
    return None


def features(samples, peak):
    if not len(samples):
        raise ValueError("缺少 IMU")
    t = samples[:, 0]
    target = peak + np.arange(-24, 1) * .01
    window = samples[max(0, t.searchsorted(target[0], side="right") - 1):
                     t.searchsorted(target[-1]) + 1]
    if len(window) < 2 or window[0, 0] > target[0] or window[-1, 0] < peak or np.diff(window[:, 0]).max() > .04:
        raise ValueError("主挥窗口缺帧")
    axes = np.stack([np.interp(target, window[:, 0], col) for col in window[:, 1:].T], axis=1)
    return np.r_[axes.reshape(5, 5, 6).mean(axis=1).ravel(),
                 np.linalg.norm(axes[:, :3], axis=1).max(), np.linalg.norm(axes[:, 3:], axis=1).max()]


def export_shadow(model, path, version):
    scaler, svm = model.steps[0][1], model.steps[1][1]
    path.write_text(json.dumps(dict(version=version, labels=svm.classes_.tolist(),
        mean=scaler.mean_.tolist(), scale=scaler.scale_.tolist(), gamma=svm._gamma,
        vectors=svm.support_vectors_.tolist(), counts=svm.n_support_.tolist(),
        dual=svm.dual_coef_.tolist(), bias=svm.intercept_.tolist()), ensure_ascii=False))


def train(holdout=None):
    with db() as conn:
        edits = {(r["session"], r["original"]): dict(r) for r in conn.execute("select * from reviews")}
        audit = {(r["session"], r["original"]): dict(r) for r in conn.execute("select * from specialist_audit")}
    version = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    with tempfile.TemporaryDirectory(dir=STORE) as tmp:
        stage = Path(tmp) / "run"
        stage.mkdir()
        data, inventory, rejected = {}, [], []
        for manifest in sorted(ROOT.glob("*/manifest.json")):
            try:
                info = json.loads(manifest.read_text())
                for r in collect(manifest.parent, info, True, rejected):
                    item = {key: r[key] for key in ("session", "label", "participant", "peak_phone_s", "source", "trial")}
                    inventory.append(item)
                    data[r["session"], r["peak_phone_s"]] = dict(session=r["session"], peak=r["peak_phone_s"],
                        participant=r["participant"], label=r["label"], source=r["source"])
            except (ValueError, OSError, KeyError) as err:
                rejected.append([manifest.parent.name, "", str(err)])
        if not inventory:
            raise ValueError("没有可用的专项场次")
        with (stage / "review.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(inventory[0]))
            writer.writeheader()
            writer.writerows(inventory)
        for key, review in edits.items():
            if review["label"] == "排除":
                data.pop(key, None)
            else:
                data[key] = dict(session=review["session"], peak=review["peak"], participant=review["participant"],
                                 label=review["label"], source="人工复核")
        for key, review in audit.items():
            if review["status"] != "可用":
                data.pop(key, None)
            elif key in data and data[key]["source"] == "prompt":
                data[key]["source"] = "录像抽帧复核"
        if audit:
            for key in [key for key, row in data.items() if row["source"] == "prompt"]:
                data.pop(key)
        examples, vectors, skipped = [], [], []
        previous = None
        for key, row in sorted(data.items()):
            if previous != key[0]:
                samples = sample_frames(key[0])
                previous = key[0]
            try:
                vectors.append(features(samples, row["peak"]))
                examples.append(row)
            except ValueError as err:
                skipped.append([*key, str(err)])
        held = split(examples, holdout)
        for r in examples:
            r["split"] = "test" if r["session"] in held else "train"
        mask = np.array([r["split"] == "train" for r in examples])
        labels = np.array([r["label"] for r in examples])
        valid = labels != "背景"
        train_mask, test_mask = mask & valid, ~mask & valid
        if not train_mask.any() or not test_mask.any() or set(labels[test_mask]) - set(labels[train_mask]):
            raise ValueError("需要独立留出场次和完整的训练类别覆盖")
        x = np.array(vectors)
        model = make_pipeline(StandardScaler(), SVC(C=1, gamma="scale", class_weight="balanced"))
        model.fit(x[train_mask], labels[train_mask])
        prediction = model.predict(x[test_mask])
        report = dict(version=version, train=int(train_mask.sum()), test=int(test_mask.sum()),
                      correct=int(sum(prediction == labels[test_mask])), reviewed=sum(r["source"] in {"reviewed", "人工复核"} for r in examples),
                      frame_reviewed=sum(r["source"] == "录像抽帧复核" for r in examples),
                      classes=sorted(set(labels[valid])), skipped=skipped, rejected=rejected,
                      metrics=classification_report(labels[test_mask], prediction, labels=sorted(set(labels[valid])),
                                                    output_dict=True, zero_division=0))
        # Rotate the same virtual grip for both sensors. The held-out recordings stay untouched.
        augmented = [x[train_mask]]
        for degrees in [-8, 8]:
            theta = np.deg2rad(degrees)
            rotation = np.array([[np.cos(theta), -np.sin(theta), 0],
                                 [np.sin(theta), np.cos(theta), 0], [0, 0, 1]])
            variant = x[train_mask].copy()
            variant[:, :30] = (variant[:, :30].reshape(-1, 10, 3) @ rotation.T).reshape(-1, 30)
            augmented.append(variant)
        augmented_model = make_pipeline(StandardScaler(), SVC(C=1, gamma="scale", class_weight="balanced"))
        augmented_model.fit(np.concatenate(augmented), np.tile(labels[train_mask], len(augmented)))
        report["simulated_grip_correct"] = int(sum(augmented_model.predict(x[test_mask]) == labels[test_mask]))
        reviewed = np.array([r["source"] in {"reviewed", "人工复核"} for r in examples])
        detector_train, detector_test = mask & reviewed, ~mask & reviewed
        report["detector"] = "等待训练组和留出组各有人工复核的真实挥拍和背景"
        if len(set(valid[detector_train])) == 2 and len(set(valid[detector_test])) == 2:
            detector = make_pipeline(StandardScaler(), SVC(C=1, gamma="scale", class_weight="balanced"))
            detector.fit(x[detector_train], valid[detector_train])
            report["detector"] = classification_report(valid[detector_test], detector.predict(x[detector_test]),
                                                        output_dict=True, zero_division=0)
            joblib.dump(detector, stage / "swing-detector.joblib")
        for row, pred in zip([r for r in examples if r["split"] == "test" and r["label"] != "背景"], prediction):
            row["prediction"] = pred
        (stage / "examples.json").write_text(json.dumps(examples, ensure_ascii=False, indent=2))
        (stage / "svm-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        joblib.dump(model, stage / "rbf.joblib")
        export_shadow(model, stage / "SwingShadow.json", version)
        stage.rename(STORE / version)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--holdout", nargs="+")
    result = train(parser.parse_args().holdout)
    print(result["version"], result["correct"], "/", result["test"])

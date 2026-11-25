"""Fit response ranges for right-handed rear clears from unlabeled placement trials."""
import argparse
import json
from pathlib import Path


def quantile(values, fraction):
    ordered = sorted(values)
    index = (len(values) - 1) * fraction
    lower = int(index)
    return ordered[lower] + (index - lower) * (ordered[min(lower + 1, len(values)-1)] - ordered[lower])


def fit(session):
    rows = []
    for path in sorted((session / "batches").glob("*.json")):
        packet = json.loads(path.read_bytes())
        if packet["state"]["leftHand"]:
            continue
        for event in packet["events"]:
            c = event.get("contact", {})
            if (c.get("intendedReply") == "高远球" and c.get("area") == "后场"
                    and c["outgoing"]["shot"] == "高远球" and not c["outsideReach"]
                    and not c.get("estimatedBackhand", False) and c["strength"] > 0):
                rows.append(c)
    if len(rows) < 12:
        raise ValueError("At least 12 in-reach rear clear contacts are required")
    cut = int(len(rows)*0.75)
    train = rows[:cut]
    aim = [abs(c["lateral"]) for c in train]
    power = [c["strength"] for c in train]
    return dict(session=session.name, trainTrials=[c["trial"] for c in train],
                heldTrials=[c["trial"] for c in rows[cut:]],
                aimMedian=quantile(aim,.5), aimUpper=quantile(aim,.9),
                soft=quantile(power,.1), strong=quantile(power,.9))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(fit(args.session), indent=2) + "\n")

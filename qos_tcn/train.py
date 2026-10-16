#!/usr/bin/env python3
"""
train.py -- train and evaluate the QoS TCN on the cached CESNET-TLS-Year22 days.

Splits are by TIME, never by shuffling flows (a random split leaks: flows of the
same session land on both sides):
  train  2022-09-01 .. 09-21
  val    2022-09-22 .. 09-25        (model selection)
  test   2022-10-10 .. 10-16        (two weeks after training ends)
  drift  one Wednesday per month, Jan..Dec 2022 (how the September model ages)

For each N in --n-pkts the model sees only the first N payload packets of a flow
(zero-padded if the flow is shorter) -- the early-classification trade-off.

Baseline: gradient-boosted trees on the same N x 4 hardware-encoded inputs, the
kind of model switch-based classifiers (NetBeacon, pForest) run. It shows what
the TCN buys over a model that already fits in a switch.

  python3 train.py                                # N = 4 8 16 30, defaults
  python3 train.py --n-pkts 8 --epochs 3 --per-day 50000      # quick run
Results go to results/<run>/: metrics.json, model_N*.pt, a summary table.
"""
import argparse
import datetime as dt
import glob
import json
import os
import time

import numpy as np
import torch
import torch.nn as nn

from hw_encoding import encode_inputs
from model import QosTCN
from qos_map import QOS_CLASSES

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "..", "datasets", "cesnet", "cache")


def days(a, b):
    d0, d1 = dt.date.fromisoformat(a), dt.date.fromisoformat(b)
    return [(d0 + dt.timedelta(k)).strftime("%Y%m%d") for k in range((d1 - d0).days + 1)]


def load(day_list, per_day, n, seed, label="qos"):
    """Concatenate cached days, sampling up to per_day flows from each.
    Returns (x int16 [m, 4, n], y uint8 [m], plen uint8 [m], days_found)."""
    xs, ys, ps, found = [], [], [], []
    rng = np.random.default_rng(seed)
    for d in day_list:
        f = os.path.join(CACHE, f"tls-{d}.npz")
        if not os.path.exists(f):
            continue
        z = np.load(f)
        m = len(z[label])
        idx = np.sort(rng.choice(m, size=min(per_day, m), replace=False))
        plen = z["plen"][idx]
        valid = np.arange(n)[None, :] < plen[:, None]
        xs.append(encode_inputs(z["ipt_u"][idx, :n], z["size"][idx, :n],
                                z["dirb"][idx, :n], z["push"][idx, :n], valid))
        ys.append(z[label][idx])
        ps.append(plen)
        found.append(d)
    if not xs:
        return None, None, None, []
    return np.concatenate(xs), np.concatenate(ys), np.concatenate(ps), found


def macro_f1(y, p, k):
    f1 = []
    for c in range(k):
        tp = np.sum((p == c) & (y == c)); fp = np.sum((p == c) & (y != c)); fn = np.sum((p != c) & (y == c))
        if tp + fp + fn == 0:
            continue
        f1.append(2 * tp / max(2 * tp + fp + fn, 1))
    return float(np.mean(f1))


def evaluate(model, x, y, k, bs=8192):
    model.eval()
    preds = []
    with torch.no_grad():
        for i in range(0, len(x), bs):
            xb = torch.from_numpy(x[i:i + bs].astype(np.float32) / 256.0)
            preds.append(model(xb).argmax(1).numpy())
    p = np.concatenate(preds)
    return {"acc": float((p == y).mean()), "macro_f1": macro_f1(y, p, k),
            "per_class_recall": [float(((p == c) & (y == c)).sum() / max((y == c).sum(), 1)) for c in range(k)]}


def train_one(n, xtr, ytr, xva, yva, k, args):
    torch.manual_seed(args.seed)
    model = QosTCN(channels=tuple(args.channels), dilations=tuple(args.dilations), n_classes=k,
                   head=args.head, n=n, embed=args.embed)
    # Class-balanced loss: macro-F1 is the metric, and the classes are uneven.
    counts = np.bincount(ytr, minlength=k).astype(np.float64)
    w = torch.tensor(counts.sum() / np.maximum(counts, 1) / k, dtype=torch.float32)
    lossf = nn.CrossEntropyLoss(weight=w)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    steps = args.epochs * ((len(xtr) + args.batch - 1) // args.batch)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps)
    best, best_state = -1, None
    for ep in range(args.epochs):
        model.train()
        perm = np.random.default_rng(args.seed + ep).permutation(len(xtr))
        t, tot = time.time(), 0.0
        for i in range(0, len(perm), args.batch):
            b = perm[i:i + args.batch]
            xb = torch.from_numpy(xtr[b].astype(np.float32) / 256.0)
            yb = torch.from_numpy(ytr[b].astype(np.int64))
            loss = lossf(model(xb), yb)
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            tot += loss.item() * len(b)
        va = evaluate(model, xva, yva, k)
        print(f"    N={n:2d} epoch {ep + 1}/{args.epochs}: loss {tot / len(perm):.3f}  "
              f"val acc {va['acc']:.3f}  macro-F1 {va['macro_f1']:.3f}  ({time.time() - t:.0f}s)", flush=True)
        if va["macro_f1"] > best:
            best, best_state = va["macro_f1"], {kk: v.clone() for kk, v in model.state_dict().items()}
    model.load_state_dict(best_state)
    return model


def baseline_trees(n, xtr, ytr, xte, yte, k, max_train=1_000_000):
    from sklearn.ensemble import HistGradientBoostingClassifier
    m = min(len(xtr), max_train)
    clf = HistGradientBoostingClassifier(max_iter=200, class_weight="balanced", random_state=0)
    clf.fit(xtr[:m].reshape(m, -1), ytr[:m])
    p = clf.predict(xte.reshape(len(xte), -1))
    return {"acc": float((p == yte).mean()), "macro_f1": macro_f1(yte, p, k)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-pkts", type=int, nargs="+", default=[4, 8, 16, 30])
    ap.add_argument("--channels", type=int, nargs="+", default=[32, 32, 64])
    ap.add_argument("--dilations", type=int, nargs="+", default=[1, 2, 4])
    ap.add_argument("--per-day", type=int, default=100_000)
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--batch", type=int, default=1024)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--head", choices=["gap", "last", "flatten"], default="flatten")
    ap.add_argument("--no-embed", dest="embed", action="store_false",
                    help="feed raw Q8.8 values instead of per-field lookup tables")
    ap.add_argument("--no-baseline", action="store_true")
    ap.add_argument("--run", default=dt.datetime.now().strftime("%Y%m%d-%H%M"))
    args = ap.parse_args()
    torch.set_num_threads(min(12, os.cpu_count()))
    out = os.path.join(HERE, "results", args.run)
    os.makedirs(out, exist_ok=True)
    k = len(QOS_CLASSES)
    # One Wednesday per month (the days fetch_cesnet_subset.py takes in tier 1).
    drift_days = ["20220112", "20220216", "20220316", "20220413", "20220518", "20220615",
                  "20220713", "20220817", "20220914", "20221012", "20221116", "20221214"]
    results = {"args": vars(args), "classes": QOS_CLASSES, "by_n": {}}
    for n in args.n_pkts:
        t0 = time.time()
        xtr, ytr, ptr, dtr = load(days("2022-09-01", "2022-09-21"), args.per_day, n, args.seed)
        xva, yva, _, dva = load(days("2022-09-22", "2022-09-25"), args.per_day // 2, n, args.seed + 1)
        xte, yte, pte, dte = load(days("2022-10-10", "2022-10-16"), args.per_day, n, args.seed + 2)
        print(f"== N={n}: train {len(ytr):,} flows ({len(dtr)} days), val {len(yva):,}, "
              f"test {len(yte):,}; test flows with >= N packets: {100 * (pte >= n).mean():.1f}%", flush=True)
        model = train_one(n, xtr, ytr, xva, yva, k, args)
        r = {"test": evaluate(model, xte, yte, k),
             "test_flows_reaching_n": float((pte >= n).mean()),
             "macs_per_inference": model.macs_per_inference(n),
             "params": sum(p.numel() for p in model.parameters()),
             "majority_class_acc": float(np.bincount(yte, minlength=k).max() / len(yte))}
        r["drift"] = {}
        for d in drift_days:
            xd, yd, _, f = load([d], args.per_day, n, args.seed + 3)
            if f:
                r["drift"][d] = evaluate(model, xd, yd, k)["macro_f1"]
        if not args.no_baseline:
            r["trees_baseline_test"] = baseline_trees(n, xtr, ytr, xte, yte, k)
        torch.save(model.state_dict(), os.path.join(out, f"model_N{n}.pt"))
        results["by_n"][n] = r
        print(f"   TEST  N={n}: acc {r['test']['acc']:.3f}  macro-F1 {r['test']['macro_f1']:.3f}"
              + (f"   | trees: acc {r['trees_baseline_test']['acc']:.3f}  macro-F1 "
                 f"{r['trees_baseline_test']['macro_f1']:.3f}" if 'trees_baseline_test' in r else "")
              + f"   ({time.time() - t0:.0f}s)", flush=True)
        json.dump(results, open(os.path.join(out, "metrics.json"), "w"), indent=1)
    print(f"results: {out}")


if __name__ == "__main__":
    main()

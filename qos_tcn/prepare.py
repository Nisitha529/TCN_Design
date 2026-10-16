#!/usr/bin/env python3
"""
prepare.py -- CESNET-TLS-Year22 day files (.csv.xz) -> compact per-day caches.

For each flows-YYYYMMDD.csv.xz this writes cache/tls-YYYYMMDD.npz holding only
what the model may use, already in the HARDWARE's record units
(hw_encoding.py), so training never sees a value the data plane cannot produce:

  ipt_u  uint16 [n, 30]   inter-packet time, 1.048576 ms units, saturating
  size   uint16 [n, 30]   payload bytes
  dirb   uint8  [n, 30]   1 = direction of the flow's first packet
  push   uint8  [n, 30]
  plen   uint8  [n]       packets present in the sequence (<= 30)
  app    uint8  [n]       service id      (qos_map.load_label_maps order)
  cat    uint8  [n]       category id
  qos    uint8  [n]       QoS class id    (qos_map.QOS_CLASSES)

Deliberately NOT kept: SNI, IPs, ASN, ports, JA3, flow totals and histograms.
They either name the service outright or are only known when the flow has
ended, and the point is classification from the first packets alone.

About 185 bytes per flow; a 450k-flow day is ~80 MB.

  python3 prepare.py                      # every downloaded day, skips done ones
  python3 prepare.py --max-flows 200000   # subsample each day (random, seeded)
"""
import argparse
import glob
import json
import os
import time

import numpy as np
import pandas as pd

from hw_encoding import ipt_ms_to_units
from qos_map import default_servicemap, load_label_maps

L = 30


def default_data():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "datasets", "cesnet")


def parse_day(path, maps, max_flows=None, seed=0):
    df = pd.read_csv(path, usecols=["PPI", "PPI_LEN", "APP", "CATEGORY"])
    if max_flows and len(df) > max_flows:
        df = df.sample(n=max_flows, random_state=seed).sort_index()
    n = len(df)
    ipt = np.zeros((n, L), np.int64)
    size = np.zeros((n, L), np.uint16)
    dirb = np.zeros((n, L), np.uint8)
    push = np.zeros((n, L), np.uint8)
    plen = np.zeros(n, np.uint8)
    for i, s in enumerate(df["PPI"].values):
        p = json.loads(s)                       # [[IPT], [DIR], [SIZE], [PUSH]]
        k = min(len(p[0]), L)
        plen[i] = k
        ipt[i, :k] = p[0][:k]
        dirb[i, :k] = np.asarray(p[1][:k]) > 0
        size[i, :k] = np.minimum(p[2][:k], 2047)
        push[i, :k] = p[3][:k] if len(p) > 3 else 0
    # Direction relative to the flow's FIRST packet: that is what the data
    # plane can know (it remembers who sent first), whatever the dataset's
    # own sign convention is.
    first = dirb[:, :1].copy()
    dirb = np.where(np.arange(L)[None, :] < plen[:, None], (dirb == first).astype(np.uint8), 0)
    app = df["APP"].map(maps["app_id"])
    cat = df["CATEGORY"].map(maps["cat_id"])
    keep = app.notna().values & cat.notna().values
    cat_v = cat.values[keep].astype(np.uint8)
    return dict(ipt_u=ipt_ms_to_units(ipt[keep]), size=size[keep], dirb=dirb[keep],
                push=push[keep], plen=plen[keep], app=app.values[keep].astype(np.uint8),
                cat=cat_v, qos=np.asarray(maps["cat_to_qos"], np.uint8)[cat_v]), int((~keep).sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=default_data())
    ap.add_argument("--max-flows", type=int, default=None)
    args = ap.parse_args()
    maps = load_label_maps(default_servicemap())
    cache = os.path.join(args.data, "cache")
    os.makedirs(cache, exist_ok=True)
    days = sorted(glob.glob(os.path.join(args.data, "tls-year22", "**", "flows-*.csv.xz"), recursive=True))
    days = [d for d in days if os.path.getsize(d) > 1_000_000]     # skip near-empty days
    for d in days:
        day = os.path.basename(d)[6:14]
        out = os.path.join(cache, f"tls-{day}.npz")
        if os.path.exists(out):
            continue
        t = time.time()
        arrs, dropped = parse_day(d, maps, args.max_flows)
        np.savez(out + ".tmp.npz", **arrs)
        os.replace(out + ".tmp.npz", out)
        print(f"{day}: {len(arrs['qos']):8,d} flows ({dropped} unlabelled dropped) "
              f"in {time.time() - t:4.0f}s  qos counts {np.bincount(arrs['qos'], minlength=5).tolist()}",
              flush=True)


if __name__ == "__main__":
    main()

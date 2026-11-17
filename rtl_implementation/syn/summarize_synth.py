#!/usr/bin/env python3
"""
summarize_synth.py -- one table from every run_all_synth.sh job in OUTDIR.

Vivado jobs (*_v, Artix-7 200T): post-synthesis LUT/FF/BRAM/DSP and the
Fmax implied by the worst slack against the job's clock constraint
(period.txt, 4 ns unless stated); if place & route ran, the same figures after
routing (that Fmax is the real one).
Quartus jobs (*_q, Cyclone IV EP4CE115): fitted logic elements, registers,
memory bits, 9-bit multipliers, and Fmax from the timing analyser at the slow
85 C corner (the worst case, the one to quote for a board). If the fitter
failed (e.g. the design does not fit), the mapper's figures are shown instead,
marked "map only".

  summarize_synth.py OUTDIR        writes OUTDIR/SUMMARY.md and prints it
"""
import os
import re
import sys


def read(path):
    try:
        return open(path, errors="replace").read()
    except OSError:
        return ""


def vivado_util(text):
    def cell(name):
        m = re.search(r"^\|\s*" + name + r"\*?\s*\|\s*([\d.]+)\s*\|", text, re.M)
        return m.group(1) if m else "-"
    return cell("Slice LUTs"), cell("Slice Registers"), cell("Block RAM Tile"), cell("DSPs")


def vivado_wns(text, period=4.0):
    m = re.search(r"Design Timing Summary.*?WNS\(ns\).*?\n.*?\n\s*(-?[\d.]+)", text, re.S)
    if not m:
        return "-", "-"
    wns = float(m.group(1))
    return f"{wns:+.2f}", f"{1000.0 / (period - wns):.0f}"


def qfile(d, name):
    """Quartus writes reports into the project folder (or output_files/ when
    PROJECT_OUTPUT_DIRECTORY is set); take whichever exists."""
    for p in (os.path.join(d, name), os.path.join(d, "output_files", name)):
        if os.path.exists(p):
            return read(p)
    return ""


def quartus(d):
    s = qfile(d, "top.fit.summary")
    stage = "fit"
    if not s:
        s, stage = qfile(d, "top.map.summary"), "map only"
    def field(name):
        m = re.search(name + r"\s*:\s*([\d,]+)", s)
        return m.group(1).replace(",", "") if m else "-"
    sta = qfile(d, "top.sta.rpt")
    fmax = "-"
    # the table itself (the first mention is the report's table of contents)
    blk = re.search(r"^; Slow 1200mV 85C Model Fmax Summary.*?\n(.*?)\nThis panel", sta, re.S | re.M)
    if blk:
        vals = re.findall(r";\s*([\d.]+) MHz\s*;\s*([\d.]+) MHz\s*;\s*(\S+)", blk.group(1))
        if vals:
            # logic Fmax, and in brackets the restricted one (capped by pin toggle rate)
            fmax = ", ".join(f"{c}: {float(f):.0f} ({float(r):.0f})" for f, r, c in vals)
    return (field("Total logic elements"), field("Total registers"), field("Total memory bits"),
            field("Embedded Multiplier 9-bit elements"), fmax, stage)


def main():
    out = sys.argv[1]
    rows_v, rows_q = [], []
    for name in sorted(os.listdir(out)):
        d = os.path.join(out, name)
        if not os.path.isdir(d):
            continue
        if name.endswith("_v") and os.path.exists(os.path.join(d, "util.rpt")):
            lut, ff, bram, dsp = vivado_util(read(os.path.join(d, "util.rpt")))
            try:
                per = float(read(os.path.join(d, "period.txt")).strip() or 4.0)
            except ValueError:
                per = 4.0
            wns, fmax = vivado_wns(read(os.path.join(d, "timing.rpt")), per)
            impl = ""
            if os.path.exists(os.path.join(d, "impl_timing.rpt")):
                il, iff, ib, idsp = vivado_util(read(os.path.join(d, "impl_util.rpt")))
                iw, ifm = vivado_wns(read(os.path.join(d, "impl_timing.rpt")), per)
                impl = f"routed: {il} LUT, {iff} FF, WNS {iw} ns, **Fmax {ifm} MHz**"
            rows_v.append(f"| {name} | {per:g} | {lut} | {ff} | {bram} | {dsp} | {wns} | {fmax} | {impl} |")
        elif name.endswith("_q"):
            le, reg, mem, mult, fmax, stage = quartus(d)
            tag = "" if stage == "fit" else f" ({stage})"
            rows_q.append(f"| {name}{tag} | {le} | {reg} | {mem} | {mult} | {fmax} |")

    status = read(os.path.join(out, "status.log"))
    failed = [l for l in status.splitlines() if "FAILED" in l or re.search(r"rc=(?!0\b)\d+", l)]
    lines = ["# Synthesis results", "",
             "## Vivado 2020.2 · Artix-7 xc7a200tfbg484-2", "",
             "Fmax = 1000 / (clock - WNS). Post-synthesis it is an estimate; the routed figure is the real one.", "",
             "| job | clock (ns) | LUT | FF | BRAM tiles | DSP48 | WNS (ns) | est. Fmax (MHz) | after place & route |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---|"] + rows_v + [
             "", "## Quartus Lite · Cyclone IV E EP4CE115F29C7 (DE2-115) · constraint 20 ns (50 MHz)", "",
             "Fitted. Fmax at the slow 1200 mV 85 C corner (worst case): the logic's Fmax, and in brackets",
             "the restricted Fmax, which Quartus caps by the I/O toggle rate when ports are pins.", "",
             "| job | logic elements | registers | memory bits | 9-bit multipliers | Fmax (MHz) |",
             "|---|---:|---:|---:|---:|---|"] + rows_q + [
             "", "Device capacity: Artix-7 200T = 134,600 LUT, 269,200 FF, 365 BRAM tiles, 740 DSP48. "
             "EP4CE115 = 114,480 LE, 3,981,312 memory bits, 532 9-bit multipliers (266 18x18).", ""]
    if failed:
        lines += ["## Failed or timed-out jobs", ""] + [f"- `{l}`" for l in failed] + [""]
    text = "\n".join(lines)
    open(os.path.join(out, "SUMMARY.md"), "w").write(text)
    print(text)


if __name__ == "__main__":
    main()

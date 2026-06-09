#!/usr/bin/env python3
"""Aggregate bench/bench(.simd) outputs from several platforms into a
markdown comparison grid (for $GITHUB_STEP_SUMMARY).

Usage: aggregate_bench.py bench-<platform>.txt [...]
Platform label is taken from the filename: bench-<platform>.txt.

Input lines look like:
    === N = 100000 ===
    Swiss/int                find hit                 18.9 ns/op
Implementation families are normalized: Neon/Sse rows -> "SIMD",
Swiss -> "SWAR", Hashtbl -> "stdlib" (the .Make variants are kept
separate as e.g. "SWAR.Make").
"""

import os
import re
import sys
from collections import defaultdict

ROW = re.compile(r"^(\S+)\s\s+(\S.*?)\s\s+([0-9.]+) ns/op")
SIZE = re.compile(r"^=== N = (\d+) ===")


def norm_impl(name):
    fam, _, key = name.partition("/")
    fam = (
        fam.replace("Neon", "SIMD")
        .replace("Sse", "SIMD")
        .replace("Swiss", "SWAR")
        .replace("Hashtbl", "stdlib")
    )
    return fam, key


def parse(path):
    platform = os.path.basename(path)
    platform = re.sub(r"^bench-", "", re.sub(r"\.txt$", "", platform))
    out = []  # (platform, N, impl_family, keytype, workload, ns)
    n = None
    with open(path) as f:
        for line in f:
            m = SIZE.match(line)
            if m:
                n = int(m.group(1))
                continue
            m = ROW.match(line)
            if m and n is not None:
                fam, key = norm_impl(m.group(1))
                out.append((platform, n, fam, key, m.group(2).strip(), float(m.group(3))))
    return out


def fmt(ns):
    return f"{ns:.1f}" if ns is not None else "—"


def main(paths):
    rows = []
    for p in paths:
        rows.extend(parse(p))
    if not rows:
        print("no benchmark data found", file=sys.stderr)
        return 1

    data = defaultdict(dict)  # (N, key, workload, platform) -> {fam: ns}
    platforms, sizes = [], []
    for platform, n, fam, key, workload, ns in rows:
        data[(n, key, workload, platform)][fam] = ns
        if platform not in platforms:
            platforms.append(platform)
        if n not in sizes:
            sizes.append(n)
    sizes.sort()

    workloads = [
        ("int", "find hit"),
        ("int", "find miss"),
        ("int", "mem 50/50"),
        ("int", "replace existing"),
        ("int", "insert(grow)"),
        ("int", "churn rm/add half"),
        ("int", "iter"),
        ("string", "find hit"),
        ("string", "find miss"),
        ("string", "mem 50/50"),
        ("string", "insert(grow)"),
    ]

    print("# Cross-platform benchmark grid")
    print()
    print("Cells: **SIMD / SWAR / stdlib** ns/op (lower is better).")
    print("SIMD = Swiss_neon (arm64) or Swiss_sse (amd64); SWAR = portable Swiss;")
    print("stdlib = Stdlib.Hashtbl of the same compiler. CI runners are shared")
    print("machines — treat numbers as indicative.")
    for n in sizes:
        print(f"\n## N = {n:,}\n")
        header = "| workload | " + " | ".join(platforms) + " |"
        print(header)
        print("|---" * (len(platforms) + 1) + "|")
        for key, workload in workloads:
            cells = []
            for platform in platforms:
                d = data.get((n, key, workload, platform), {})
                simd = d.get("SIMD")
                swar = d.get("SWAR")
                std = d.get("stdlib")
                if not d:
                    cells.append("—")
                else:
                    cells.append(f"{fmt(simd)} / {fmt(swar)} / {fmt(std)}")
            print(f"| {key} {workload} | " + " | ".join(cells) + " |")

    # functor (Make) headline: find hit only, compact
    print("\n## Make-functor find hit (SIMD.Make / SWAR.Make / stdlib.Make)\n")
    print("| N | " + " | ".join(platforms) + " |")
    print("|---" * (len(platforms) + 1) + "|")
    for n in sizes:
        cells = []
        for platform in platforms:
            d = data.get((n, "int", "find hit", platform), {})
            simd = d.get("SIMD.Make")
            swar = d.get("SWAR.Make")
            std = d.get("stdlib.Make")
            cells.append(
                f"{fmt(simd)} / {fmt(swar)} / {fmt(std)}"
                if (simd or swar or std)
                else "—"
            )
        print(f"| {n:,} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

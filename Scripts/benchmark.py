#!/usr/bin/env python3 -I
"""Repeatable benchmark: Universal Archiver's `archiver` CLI against reference tools on identical
inputs and comparable settings. Writes Markdown and JSON results.

  Scripts/benchmark.py --archiver .build/release/archiver --out Documentation/Benchmarks.md [--scale 1.0]

Datasets are generated deterministically (seeded), so runs are comparable over time. Peak memory is
measured with GNU time (Linux) or /usr/bin/time -l (macOS). Each measurement is the median of N runs.
Comparisons are only made between identical formats and levels; nothing here is a marketing claim.
"""
import argparse, json, os, platform, random, shutil, statistics, subprocess, sys, tempfile, time

p = argparse.ArgumentParser()
p.add_argument("--archiver", required=True)
p.add_argument("--out", default="Documentation/Benchmarks.md")
p.add_argument("--scale", type=float, default=1.0, help="dataset size multiplier")
p.add_argument("--runs", type=int, default=3)
args = p.parse_args()
ARCHIVER = os.path.abspath(args.archiver)
WORK = tempfile.mkdtemp(prefix="ua-bench-")
IS_MAC = platform.system() == "Darwin"

WORDS = ("the of and to in is was that for on as with by at from this which are be or have an it not were but all can had "
         "archive compress extract file folder data stream block entropy dictionary window match literal length offset "
         "apple silicon performance efficiency memory thread queue progress verify checksum integrity").split()


def gen_text(path, size, seed=1):
    r = random.Random(seed)
    with open(path, "w") as f:
        n = 0
        while n < size:
            line = " ".join(r.choice(WORDS) for _ in range(r.randint(6, 16))).capitalize() + ".\n"
            f.write(line)
            n += len(line)


def gen_random(path, size, seed=2):
    r = random.Random(seed)
    with open(path, "wb") as f:
        left = size
        while left > 0:
            n = min(left, 1 << 20)
            f.write(r.randbytes(n))
            left -= n


def mb(x):
    return int(x * 1_000_000 * args.scale)


def build_datasets():
    d = {}
    base = os.path.join(WORK, "data")
    os.makedirs(base)
    # 1. Large text
    t = os.path.join(base, "text"); os.makedirs(t); gen_text(os.path.join(t, "corpus.txt"), mb(120)); d["Large text"] = t
    # 2. Source code: this repository's sources plus dependency checkouts
    s = os.path.join(base, "source"); os.makedirs(s)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for sub in ["Sources", "Tests", ".build/checkouts"]:
        src = os.path.join(repo, sub)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(s, sub.replace("/", "_")), symlinks=True, ignore=shutil.ignore_patterns(".git"))
    d["Source code"] = s
    # 3. Many small files
    m = os.path.join(base, "small"); os.makedirs(m)
    r = random.Random(3)
    for i in range(int(20000 * args.scale)):
        sub = os.path.join(m, f"d{i // 500}")
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, f"f{i}.txt"), "w") as f:
            f.write(" ".join(r.choice(WORDS) for _ in range(r.randint(5, 60))))
    d["20k small files"] = m
    # 4/5. Already-compressed data (stand-in for photos/video: high-entropy bytes)
    c = os.path.join(base, "compressed"); os.makedirs(c)
    for i in range(4):
        gen_random(os.path.join(c, f"IMG_{i}.jpg"), mb(30), seed=10 + i)
    d["Already-compressed (JPEG-like)"] = c
    # 6. Mixed
    x = os.path.join(base, "mixed"); os.makedirs(x)
    gen_text(os.path.join(x, "notes.txt"), mb(40))
    gen_random(os.path.join(x, "movie.mp4"), mb(40), seed=20)
    shutil.copytree(os.path.join(s, "Sources"), os.path.join(x, "Sources"))
    d["Mixed folder"] = x
    return d


def measure(cmd, cwd=None, stdin=None):
    """Returns (seconds, peak_rss_bytes). Median over runs; cleans outputs via callback."""
    if IS_MAC:
        full = ["/usr/bin/time", "-l"] + cmd
    else:
        full = ["/usr/bin/time", "-f", "%M"] + cmd
    t0 = time.perf_counter()
    r = subprocess.run(full, cwd=cwd, input=stdin, capture_output=True, text=True)
    dt = time.perf_counter() - t0
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {r.stderr[-400:]}")
    err = r.stderr.strip().splitlines()
    rss = 0
    if IS_MAC:
        for line in err:
            if "maximum resident set size" in line:
                rss = int(line.split()[0])
    else:
        rss = int(err[-1]) * 1024
    return dt, rss


def size_of(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    return sum(os.path.getsize(os.path.join(a, f)) for a, _, fs in os.walk(path) for f in fs if not os.path.islink(os.path.join(a, f)))


def have(tool):
    return shutil.which(tool) is not None


def cases(src, name):
    """(label, format, ours_cmd(out), reference_label, ref_cmd(out), out_ext). Same format + level."""
    parent, base = os.path.dirname(src), os.path.basename(src)
    c = []
    c.append(("ZIP · Deflate 6", "zip",
              lambda o: [ARCHIVER, "compress", src, "-o", o, "--level", "6", "-q"],
              "Info-ZIP zip -6", lambda o: ["zip", "-q", "-r", "-6", o, base], ".zip", have("zip")))
    c.append(("TAR.GZ · level 6", "tar.gz",
              lambda o: [ARCHIVER, "compress", src, "-o", o, "--level", "6", "-q"],
              "GNU tar + gzip -6", lambda o: ["tar", "-cf", o, "-I", "gzip -6", base], ".tar.gz", have("tar")))
    c.append(("TAR.XZ · level 6", "tar.xz",
              lambda o: [ARCHIVER, "compress", src, "-o", o, "--level", "6", "-q"],
              "GNU tar + xz -6 -T0", lambda o: ["tar", "-cf", o, "-I", "xz -6 -T0", base], ".tar.xz", have("xz")))
    c.append(("TAR.ZST · level 3", "tar.zst",
              lambda o: [ARCHIVER, "compress", src, "-o", o, "--level", "3", "-q"],
              "GNU tar + zstd -3 -T0", lambda o: ["tar", "-cf", o, "-I", "zstd -3 -T0", base], ".tar.zst", have("zstd")))
    c.append(("7z · LZMA2 level 5", "7z",
              lambda o: [ARCHIVER, "compress", src, "-o", o, "--level", "5", "-q"],
              "7-Zip 7z -mx5", lambda o: ["7z", "a", "-bd", "-mx5", o, base], ".7z", have("7z")))
    return c


def main():
    datasets = build_datasets()
    results = []
    for dname, src in datasets.items():
        insize = size_of(src)
        for label, fmt, ours, refname, ref, ext, avail in cases(src, dname):
            row = {"dataset": dname, "input_bytes": insize, "format": label}
            for who, mk in (("ours", ours), ("ref", ref if avail else None)):
                if mk is None:
                    continue
                times, rsss, sizes, xtimes, xrss = [], [], [], [], []
                for i in range(args.runs):
                    out = os.path.join(WORK, f"o-{who}-{i}{ext}")
                    if os.path.exists(out):
                        os.remove(out)
                    dt, rss = measure(mk(out), cwd=os.path.dirname(src))
                    times.append(dt); rsss.append(rss); sizes.append(os.path.getsize(out))
                    # Extraction with our tool for both outputs (cross-reads the reference's archive too).
                    xd = os.path.join(WORK, f"x-{who}-{i}")
                    os.makedirs(xd)
                    xt, xr = measure([ARCHIVER, "extract", out, "-o", xd, "-q"])
                    xtimes.append(xt); xrss.append(xr)
                    shutil.rmtree(xd)
                    os.remove(out)
                row[who] = {"name": "Universal Archiver" if who == "ours" else refname,
                            "seconds": statistics.median(times), "bytes": statistics.median(sizes),
                            "peak_rss": max(rsss), "extract_seconds": statistics.median(xtimes), "extract_peak_rss": max(xrss)}
            results.append(row)
            print(json.dumps(row), flush=True)
    write_report(results)


def fmt_b(n):
    for u in ["B", "KB", "MB", "GB"]:
        if n < 1000:
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1000
    return f"{n:.1f} TB"


def write_report(results):
    cpu = platform.processor() or platform.machine()
    try:
        if not IS_MAC:
            cpu = [l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")][0]
        else:
            cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    except Exception:
        pass
    lines = [
        "# Benchmarks", "",
        f"Generated by `Scripts/benchmark.py` on {time.strftime('%Y-%m-%d')}.", "",
        f"* Machine: {cpu}, {os.cpu_count()} logical CPUs, {platform.system()} {platform.release()} ({platform.machine()})",
        f"* Runs per measurement: {args.runs} (median time; peak memory is the maximum)",
        f"* Dataset scale: {args.scale}",
        "",
        "> These numbers come from the environment above. They are **not** Apple Silicon results; run the",
        "> script on an M-series Mac to obtain those. Only identical formats and levels are compared. The",
        "> 7z rows use the bundled 7-Zip engine on both sides, so they show orchestration overhead, not a",
        "> different compressor. Extraction times use Universal Archiver for both archives.", "",
        "| Dataset | Format | Tool | Compress (s) | Output | Ratio | Peak RSS | Extract (s) | Extract RSS |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for r in results:
        for who in ("ours", "ref"):
            if who not in r:
                continue
            m = r[who]
            lines.append(f"| {r['dataset']} ({fmt_b(r['input_bytes'])}) | {r['format']} | {m['name']} | {m['seconds']:.2f} | {fmt_b(m['bytes'])} | "
                         f"{m['bytes'] / max(1, r['input_bytes']) * 100:.1f}% | {fmt_b(m['peak_rss'])} | {m['extract_seconds']:.2f} | {fmt_b(m['extract_peak_rss'])} |")
    lines += ["", "Raw data: `Benchmarks.json`.", ""]
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    open(args.out, "w").write("\n".join(lines))
    json.dump({"machine": cpu, "cpus": os.cpu_count(), "system": platform.platform(), "results": results},
              open(os.path.join(os.path.dirname(os.path.abspath(args.out)), "Benchmarks.json"), "w"), indent=1)
    print("wrote", args.out)


try:
    main()
finally:
    shutil.rmtree(WORK, ignore_errors=True)

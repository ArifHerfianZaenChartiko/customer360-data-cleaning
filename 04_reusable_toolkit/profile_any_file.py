"""
Profile any tabular file and write a data-quality issue log to Excel.

Reusable first step of a cleaning job: point it at the client's file and get, in minutes,
the list of problems to quote and fix. Nothing in the input file is changed.

Supported input: .csv / .tsv / .txt (delimiter and encoding detected), .xlsx / .xlsm / .xls, .parquet
Large CSV files are read in chunks, so every row is profiled without loading the whole file.

Usage
    python profile_any_file.py <file> [--sheet NAME] [--out FOLDER] [--chunksize 200000]

Output
    <out>/<file name>_profile.xlsx with sheets:
        overview        file, rows, columns, exact duplicate rows
        issue_log       one row per problem: column, issue, rows affected, %, examples, suggested action
        column_profile  one row per column: detected type, filled, blank, distinct, top values

The checks are generic heuristics. Read the issue log as a list of leads to confirm, not as final truth.
"""

import argparse
import bisect
import csv
import re
from collections import Counter
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

PLACEHOLDERS = {"nan", "null", "none", "n/a", "na", "#n/a", "unknown", "-", "--", "?", "missing", "undefined", "nil"}
BOOL_WORDS = {"true", "false", "yes", "no", "y", "n", "t", "f", "0", "1"}
NUMBER = re.compile(r"^[+-]?(\d+([.,]\d+)?|\d{1,3}(,\d{3})+(\.\d+)?|\.\d+)$")
EMAIL = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
DATE_LIKE = re.compile(r"^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}([ T]\d{1,2}:\d{2}(:\d{2})?(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$")
UUID_OR_HEX = re.compile(r"^[0-9a-fA-F]{8,}(-[0-9a-fA-F]{4,}){0,4}$")
DOUBLED = re.compile(r"^([A-Z])\1[a-z]|([a-z])\2\2")  # 'KKevin', 'Haaannah'
ID_NAME = re.compile(r"(^|[_\s(])ids?($|[_\s)])|^id|id$", re.IGNORECASE)
MAX_TRACKED_VALUES = 1_000_000  # distinct values kept per column (enough for most client files)


def id_format(value):
    """Format class of an identifier, so mixed ID formats in one column stand out."""
    if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value):
        return "UUID (lower case)"
    if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value):
        return "UUID (upper/mixed case)"
    if re.fullmatch(r"[0-9a-fA-F]{32}", value):
        return "UUID without dashes"
    # anything else: keep letters/digits structure, e.g. 'PROD-0001' -> 'AAAA-9999'
    return re.sub(r"[a-z]", "a", re.sub(r"[A-Z]", "A", re.sub(r"\d+", "9", value)))


# ----------------------------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------------------------
def detect_encoding(path):
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            with open(path, encoding=enc) as f:
                f.read(2_000_000)
            return enc
        except UnicodeDecodeError:
            continue
    return "latin-1"


def detect_delimiter(path, encoding):
    with open(path, encoding=encoding, newline="") as f:
        sample = f.read(100_000)
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
    except csv.Error:
        return ","


def read_chunks(path, sheet, chunksize):
    """Yield DataFrames of text (dtype=str, blanks kept as ''), so no dirty value is converted silently."""
    suffix = path.suffix.lower()
    text = dict(dtype=str, keep_default_na=False)
    if suffix in (".csv", ".tsv", ".txt"):
        enc = detect_encoding(path)
        sep = "\t" if suffix == ".tsv" else detect_delimiter(path, enc)
        print(f"reading CSV: encoding={enc}, delimiter={sep!r}")
        yield from pd.read_csv(path, sep=sep, encoding=enc, chunksize=chunksize, **text)
    elif suffix in (".xlsx", ".xlsm", ".xls"):
        yield pd.read_excel(path, sheet_name=sheet or 0, **text)
    elif suffix == ".parquet":
        yield pd.read_parquet(path).astype(str).replace({"None": "", "nan": "", "NaT": "", "<NA>": ""})
    else:
        raise SystemExit(f"unsupported file type: {suffix}")


# ----------------------------------------------------------------------------------------------
# Per-column statistics, accumulated chunk by chunk
# ----------------------------------------------------------------------------------------------
class ColumnStats:
    def __init__(self, name):
        self.name = name
        self.rows = 0
        self.blank = 0
        self.outer_space = 0
        self.placeholder = 0
        self.values = Counter()
        self.overflow = False
        self.numeric_ok = 0
        self.numeric_sep = 0
        self.numbers = []
        self.date_like = 0
        self.date_bad = 0
        self.date_future = 0
        self.date_shapes = Counter()
        self.email_like = 0
        self.email_bad = 0
        self.id_like = 0               # UUID / long hex values
        self.id_formats = Counter()    # format class of every value, used for ID columns
        self.packed = 0                # cells holding several values
        self.code_shapes = Counter()   # phone-like / code-like values: digits -> 9, letters -> a
        self.code_like = 0
        self.noise = 0
        self.doubled = 0
        self.examples = {}

    def remember(self, key, values):
        if key not in self.examples and len(values):
            self.examples[key] = "; ".join(repr(v) for v in pd.unique(values)[:3])

    def update(self, s):
        self.rows += len(s)
        stripped = s.str.strip()
        blank = stripped.eq("")
        self.blank += int(blank.sum())

        outer = s.ne(stripped) & ~blank
        self.outer_space += int(outer.sum())
        self.remember("outer_space", s[outer])

        ph = stripped.str.lower().isin(PLACEHOLDERS)
        self.placeholder += int(ph.sum())
        self.remember("placeholder", stripped[ph])

        filled = stripped[~blank & ~ph]
        if not self.overflow:
            self.values.update(filled.tolist())
            self.overflow = len(self.values) > MAX_TRACKED_VALUES

        is_num = filled.str.match(NUMBER)
        self.numeric_ok += int(is_num.sum())
        with_sep = filled[is_num].str.contains(r"\d,\d{3}", regex=True)
        self.numeric_sep += int(with_sep.sum())
        self.remember("numeric_sep", filled[is_num][with_sep])
        nums = pd.to_numeric(filled[is_num].str.replace(",", "", regex=False), errors="coerce")
        self.numbers.append(nums.dropna().to_numpy())
        self.remember("negative", filled[is_num][nums < 0])
        self.remember("non_numeric", filled[~is_num])

        is_date = filled.str.match(DATE_LIKE)
        self.date_like += int(is_date.sum())
        dates = filled[is_date]
        if len(dates):
            self.date_shapes.update(dates.str.replace(r"\d", "9", regex=True).tolist())
            parsed = pd.to_datetime(dates, errors="coerce", utc=True, format="mixed")
            bad = parsed.isna()
            self.date_bad += int(bad.sum())
            self.remember("date_bad", dates[bad])
            future = parsed > pd.Timestamp.now(tz="UTC")
            self.date_future += int(future.sum())
            self.remember("date_future", dates[future])
        self.remember("non_date", filled[~is_date])

        has_at = filled.str.contains("@", regex=False)
        self.email_like += int(has_at.sum())
        bad_email = has_at & ~filled.str.match(EMAIL)
        self.email_bad += int(bad_email.sum())
        self.remember("email_bad", filled[bad_email])

        is_id = filled.str.match(UUID_OR_HEX)
        self.id_like += int(is_id.sum())
        # several values packed in one cell, e.g. 'id1;id2;id3'
        packed = filled.str.contains(r"\S[;|]\S", regex=True) & ~filled.str.contains(" ", regex=False)
        self.packed += int(packed.sum())
        self.remember("packed", filled[packed])

        # identifier-looking values (no spaces, has a digit, 6+ chars): count their format class
        id_candidates = filled[~filled.str.contains(" ", regex=False) & filled.str.contains(r"\d", regex=True)
                               & filled.str.len().ge(6) & ~packed]
        fmt = id_candidates.map(id_format)
        self.id_formats.update(fmt.tolist())
        new_formats = [f for f in fmt.unique() if f"id_format:{f}" not in self.examples]
        if len(new_formats) <= 20:
            for f in new_formats:
                self.remember(f"id_format:{f}", id_candidates[fmt.eq(f)])

        digits = filled.str.count(r"\d")
        letters = filled.str.count(r"[A-Za-z]")
        code = (digits >= 7) & (letters <= 2) & ~is_date & ~is_num & ~is_id
        self.code_like += int(code.sum())
        self.code_shapes.update(filled[code].str.replace(r"\d", "9", regex=True)
                                .str.replace(r"[A-Za-z]", "a", regex=True).tolist())

        words = (letters >= 2) & ~is_id & ~has_at & ~code
        noisy = words & filled.str.contains(r"[!*#$%^~`|<>{}\[\]]|[A-Za-z]\d[A-Za-z]|[A-Za-z]\d$", regex=True)
        self.noise += int(noisy.sum())
        self.remember("noise", filled[noisy])

        obj = filled[words].astype(object)
        doubled = obj.map(lambda v: bool(DOUBLED.search(v)))
        self.doubled += int(doubled.sum())
        self.remember("doubled", obj[doubled])


# ----------------------------------------------------------------------------------------------
# Turning statistics into issues
# ----------------------------------------------------------------------------------------------
def detect_type(c):
    filled = c.rows - c.blank - c.placeholder
    if filled == 0:
        return "empty"
    if c.numeric_ok / filled >= 0.95:
        return "number"
    if c.date_like / filled >= 0.95:
        return "date"
    if c.email_like / filled >= 0.95:
        return "email"
    if c.id_like / filled >= 0.8 or ID_NAME.search(c.name):
        return "id"
    if not c.overflow and {v.lower() for v in c.values} <= BOOL_WORDS:
        return "boolean"
    if c.code_like / filled >= 0.8:
        return "code"
    if not c.overflow and len(c.values) <= max(50, filled * 0.01):
        return "category"
    return "text"


def one_edit_apart(a, b):
    """True when b is a with one letter inserted, deleted, replaced, or two neighbours swapped."""
    if a == b or abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        diff = [i for i in range(len(a)) if a[i] != b[i]]
        return len(diff) == 1 or (len(diff) == 2 and diff[1] == diff[0] + 1
                                  and a[diff[0]] == b[diff[1]] and a[diff[1]] == b[diff[0]])
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    return any(long_[:i] + long_[i + 1:] == short for i in range(len(long_)))


def variant_groups(values, categorical):
    """Group spellings of the same value: case, spaces, punctuation, leetspeak 3->e.
    For categorical columns also: reversed text, a short prefix of one longer value ('pay' -> 'payment')
    and up to 2 extra trailing letters ('refundx'). These looser rules are skipped for free text,
    where 'Niger'/'Nigeria' or 'Maria'/'Mariah' are different values."""
    keys = {}
    for v, n in values.items():
        if not re.search(r"[A-Za-z]", v):
            continue  # numbers like 3 / -3 are not spelling variants
        k = re.sub(r"[^a-z0-9]", "", v.lower().replace("3", "e"))
        if k:
            keys.setdefault(k, []).append((v, n))
    total = {k: sum(n for _, n in g) for k, g in keys.items()}
    ordered = sorted(keys)
    parent = {}  # rarer spelling -> more common spelling; dictionary lookups only, so large columns stay fast
    for k in keys if categorical else []:
        candidates = []
        rev = k[::-1]
        if rev != k and rev in total:
            candidates.append(rev)                          # reversed text
        candidates += [k[:-cut] for cut in (1, 2) if len(k) - cut >= 3 and k[:-cut] in total]  # extra letters
        if len(keys) <= 30 and len(k) >= 2:                 # short code list: one-letter typo ('crad', 'crd')
            candidates += [o for o in keys if o != k and one_edit_apart(k, o)]
        if 3 <= len(k) <= 5:                                # short prefix of exactly one longer value
            i = bisect.bisect_right(ordered, k)
            longer = []
            while i < len(ordered) and ordered[i].startswith(k) and len(longer) < 2:
                longer.append(ordered[i])
                i += 1
            if len(longer) == 1:
                candidates.append(longer[0])
        # In a short code list (status, payment method: up to 30 values) an abbreviation is reliable.
        # In a long list (countries) a loose variant must be a rare spelling of a dominant value
        # (refundx 280 vs refund 5,823), so two real values of similar size (Niger / Nigeria) are never merged.
        factor = 1 if len(keys) <= 30 else 5
        better = [o for o in candidates if total[o] > factor * total[k]]
        if better:
            parent[k] = max(better, key=total.get)
    def root(k):
        while k in parent:  # always points to a strictly more common key, so no cycles
            k = parent[k]
        return k

    groups = {}
    for k, g in keys.items():
        groups.setdefault(root(k), []).extend(g)
    return {k: sorted(g, key=lambda x: -x[1]) for k, g in groups.items() if len(g) > 1}


def issues_for(c, total_rows):
    out = []

    def add(issue, rows, examples, action):
        if rows:
            out.append({"column": c.name, "issue": issue, "rows_affected": int(rows),
                        "pct_of_rows": round(rows / total_rows * 100, 2), "examples": examples,
                        "suggested_action": action})

    kind = detect_type(c)
    filled = c.rows - c.blank - c.placeholder
    add("blank value", c.blank, "", "Convert to null; fill only from a reliable source")
    add("leading/trailing spaces", c.outer_space, c.examples.get("outer_space", ""), "Trim")
    add("placeholder text instead of a value", c.placeholder, c.examples.get("placeholder", ""), "Convert to null")

    if not c.overflow and len(c.values) == 1 and filled == c.rows:
        add("constant column (same value in every row)", c.rows, repr(next(iter(c.values))),
            "Information only: the column carries no information; keep or drop with the client")

    if kind in ("number",) or (kind not in ("id", "date", "code") and filled and c.numeric_ok / filled >= 0.5):
        add("non-numeric value in a numeric column", filled - c.numeric_ok, c.examples.get("non_numeric", ""),
            "Convert words/units to numbers where certain; otherwise null and flag")
        add("number written with a thousand separator", c.numeric_sep, c.examples.get("numeric_sep", ""),
            "Remove separator; check it is not a placeholder")
        nums = np.concatenate(c.numbers) if c.numbers else np.array([])
        add("negative number", int((nums < 0).sum()), c.examples.get("negative", ""),
            "Check if negatives are allowed; otherwise null and flag")
        if len(nums) >= 20:
            q1, q3 = np.percentile(nums, [25, 75])
            iqr = q3 - q1
            lo, hi = q1 - 1.5 * iqr, q3 + 1.5 * iqr
            add(f"outlier (IQR rule, outside {lo:,.2f} .. {hi:,.2f})", int(((nums < lo) | (nums > hi)).sum()), "",
                "Keep and flag for review")

    if kind == "date" or (kind != "id" and filled and c.date_like / filled >= 0.5):
        add("value is not a date in a date column", filled - c.date_like, c.examples.get("non_date", ""),
            "Parse if the format is known; otherwise null and flag")
        if len(c.date_shapes) > 1:
            add(f"dates in {len(c.date_shapes)} different formats (rows not in the most common one)",
                c.date_like - max(c.date_shapes.values()), "; ".join(list(c.date_shapes)[:4]),
                "Parse every format explicitly to one standard (ISO 8601); check day/month order")
        add("impossible date (e.g. month 13, hour 25)", c.date_bad, c.examples.get("date_bad", ""), "Null and flag")
        add("date after today", c.date_future, c.examples.get("date_future", ""),
            "Null and flag if events cannot be in the future")

    if kind in ("number", "date") and not c.overflow and len(c.values) >= 10:
        counts = pd.Series(c.values)
        heavy = counts[(counts > 10 * counts.median()) & (counts >= 20)]
        add("one value repeated far more than others (possible default/placeholder)", int(heavy.sum()),
            "; ".join(f"{v!r} ({n:,})" for v, n in heavy.sort_values(ascending=False).head(3).items()),
            "Confirm with the client; if it is a default value, null and flag")

    if kind == "email" or (filled and c.email_like / filled >= 0.5):
        add("invalid email format", c.email_bad, c.examples.get("email_bad", ""), "Lower-case and trim; flag invalid")

    if kind == "code" and len(c.code_shapes) > 1:
        add(f"values in {len(c.code_shapes)} different formats (rows not in the most common one)",
            c.code_like - max(c.code_shapes.values()), "; ".join(list(c.code_shapes)[:4]),
            "Standardise to one format (e.g. E.164 for phone numbers)")

    if kind in ("text", "category"):
        add("letters mixed with symbols/digits (possible noise)", c.noise, c.examples.get("noise", ""),
            "Remove noise characters where the clean value is certain")
        add("possible doubled-letter typo", c.doubled, c.examples.get("doubled", ""),
            "Fix only where the correct spelling can be confirmed")

    if kind in ("category", "text", "boolean") and not c.overflow:
        groups = variant_groups(c.values, categorical=kind == "category")
        if groups:
            rows = sum(sum(n for _, n in g) - g[0][1] for g in groups.values())
            sample = "; ".join("/".join(v for v, _ in g[:4]) for g in list(groups.values())[:3])
            add(f"same value written in different ways ({len(groups)} groups)", rows, sample,
                "Map every variant to one standard value (mapping table)")

    add("several values packed in one cell (separated by ; or |)", c.packed, c.examples.get("packed", "")[:150],
        "Split into a separate table with one value per row")

    if kind == "id" and len(c.id_formats) > 1:
        main_fmt, main_n = c.id_formats.most_common(1)[0]
        others = [f for f, _ in c.id_formats.most_common()[1:6]]
        add(f"IDs in {len(c.id_formats)} different formats (rows not in the main format: {main_fmt})",
            sum(c.id_formats.values()) - main_n,
            "; ".join(f"{f}: {c.examples.get('id_format:' + f, '')[:60]}" for f in others),
            "Normalise reformattable IDs (case, dashes); null and flag placeholders like 'invalid-...'")

    if kind == "id" and not c.overflow and filled and len(c.values) / filled >= 0.9:
        dup_rows = sum(n - 1 for n in c.values.values() if n > 1)
        add("ID value used more than once (column looks like a unique key)", dup_rows,
            "; ".join(repr(v) for v, n in c.values.most_common(3) if n > 1), "Check for duplicate records; merge or flag")
    return out, kind


# ----------------------------------------------------------------------------------------------
def profile(path, sheet=None, out_dir=None, chunksize=200_000):
    path = Path(path)
    out_dir = Path(out_dir) if out_dir else path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    stats, hashes, columns, total = {}, [], None, 0
    for chunk in read_chunks(path, sheet, chunksize):
        if columns is None:
            columns = list(chunk.columns)
            stats = {col: ColumnStats(col) for col in columns}
        total += len(chunk)
        hashes.append(pd.util.hash_pandas_object(chunk, index=False))
        for col in columns:
            stats[col].update(chunk[col].astype(str))
        print(f"  profiled {total:,} rows")

    dup_rows = int(pd.concat(hashes, ignore_index=True).duplicated().sum())

    issue_rows, profile_rows = [], []
    if dup_rows:
        issue_rows.append({"column": "(all)", "issue": "exact duplicate row", "rows_affected": dup_rows,
                           "pct_of_rows": round(dup_rows / total * 100, 2), "examples": "",
                           "suggested_action": "Drop, keep the first occurrence"})
    for col in columns:
        c = stats[col]
        found, kind = issues_for(c, total)
        issue_rows += found
        profile_rows.append({
            "column": col, "detected_type": kind, "rows": c.rows,
            "filled": c.rows - c.blank, "blank": c.blank,
            "distinct": f">{MAX_TRACKED_VALUES:,}" if c.overflow else len(c.values),
            "top_values": "; ".join(f"{v!r} ({n:,})" for v, n in c.values.most_common(3)),
            "issues_found": len(found),
        })

    issue_log = pd.DataFrame(issue_rows, columns=["column", "issue", "rows_affected", "pct_of_rows",
                                                  "examples", "suggested_action"])
    issue_log = issue_log.sort_values("rows_affected", ascending=False).reset_index(drop=True)
    issue_log.insert(0, "issue_id", [f"ISS-{i:03d}" for i in range(1, len(issue_log) + 1)])
    overview = pd.DataFrame([{
        "file": path.name, "profiled_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "rows": total, "columns": len(columns), "exact_duplicate_rows": dup_rows,
        "issues_found": len(issue_log), "size_mb": round(path.stat().st_size / 1024**2, 2),
    }])
    column_profile = pd.DataFrame(profile_rows)

    out_path = out_dir / f"{path.stem}_profile.xlsx"
    with pd.ExcelWriter(out_path, engine="xlsxwriter", engine_kwargs={"options": {"strings_to_urls": False}}) as w:
        for name, df in {"overview": overview, "issue_log": issue_log, "column_profile": column_profile}.items():
            df.to_excel(w, sheet_name=name, index=False)
            ws = w.sheets[name]
            ws.freeze_panes(1, 0)
            for i, col in enumerate(df.columns):
                width = df[col].astype(str).str.len().max() if len(df) else 0
                ws.set_column(i, i, min(max(width, len(col)) + 2, 70))
    print(f"{total:,} rows, {len(columns)} columns, {len(issue_log)} issues -> {out_path}")
    return out_path


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Profile any CSV / Excel / Parquet file and write an issue log.")
    ap.add_argument("file")
    ap.add_argument("--sheet", help="Excel sheet name (default: first sheet)")
    ap.add_argument("--out", help="output folder (default: next to the input file)")
    ap.add_argument("--chunksize", type=int, default=200_000, help="CSV rows per chunk (default 200,000)")
    args = ap.parse_args()
    profile(args.file, args.sheet, args.out, args.chunksize)

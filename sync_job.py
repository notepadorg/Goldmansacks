"""SQL Server incremental sync -- INSERT-ONLY, two modes chosen in the JSON config.

  incremental.mode = "id"    -> copy rows where ID > destination MAX(ID)
  incremental.mode = "date"  -> Phase 1: load every complete day after destination MAX(date)
                                Phase 2: repair recent days whose destination count is lower

Never deletes / updates / truncates. Uses only pyodbc + the standard library.
Settings live in config/<CONFIG_FILE>  (override with env var CONFIG_FILE).

Commands:
  python sync_job.py --test                 test connections, show counts / max values
  python sync_job.py --check                show what is pending, no insert
  python sync_job.py --once                 run the sync
  python sync_job.py --once --mode date     override the mode from the command line
  python sync_job.py --once --catchup-days 400   (date mode) one-time backfill of old gaps
  python sync_job.py --create-dest          create destination table if missing
  python sync_job.py --email-test           send a test email
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import smtplib
import socket
import sys
import time
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from logging.handlers import TimedRotatingFileHandler
from typing import Any

import pyodbc

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.environ.get("CONFIG_FILE", "sync_config.json")
CONFIG_PATH = os.path.join(BASE_DIR, "config", CONFIG_FILE)
LOCK_PATH = os.path.join(BASE_DIR, "sync_job.lock")


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def _match_key(name: Any) -> str:
    """Case / space / underscore tolerant column-name key."""
    return re.sub(r"[\s_]+", "", str(name).strip().casefold())


def resolve_column_name(columns, expected_name):
    """Return the real column spelling that matches expected_name, or None."""
    expected = _match_key(expected_name)
    for col in columns:
        if _match_key(col) == expected:
            return col
    return None


def quote_id(value: str) -> str:
    """Escape and bracket a SQL Server identifier."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("SQL identifier cannot be empty")
    return "[" + value.replace("]", "]]") + "]"


def full_table(section: dict[str, Any]) -> str:
    """Bracket-quoted schema.table from a config section."""
    return f"{quote_id(section.get('schema', 'dbo'))}.{quote_id(section['table'])}"


def describe_target(section: dict[str, Any]) -> str:
    """Readable server / database / table text for logs."""
    return (f"{section.get('server', '?')} / {section.get('database', '?')} / "
            f"{section.get('schema', 'dbo')}.{section.get('table', '?')}")


def _day(d) -> datetime:
    """Midnight of the given date."""
    return datetime(d.year, d.month, d.day)


def _today() -> datetime:
    """Midnight at the start of today (local machine time)."""
    return datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)


def _key_value(v):
    """Normalise a value for row matching (datetime -> millisecond precision)."""
    if isinstance(v, datetime):
        return v.replace(microsecond=(v.microsecond // 1000) * 1000)
    return v


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def load_config(mode_override: str | None = None) -> dict[str, Any]:
    """Read and validate the JSON config (mode-aware)."""
    if not os.path.exists(CONFIG_PATH):
        raise FileNotFoundError(f"Config file not found: {CONFIG_PATH}")
    with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
        cfg = json.load(handle)
    for name in ("source", "destination", "incremental", "logging", "email"):
        if name not in cfg:
            raise ValueError(f"Missing config section: {name}")

    inc = cfg["incremental"]
    if mode_override:
        inc["mode"] = mode_override
    if "applock_name" not in inc and inc.get("application_lock_name"):
        inc["applock_name"] = inc["application_lock_name"]
    inc["mode"] = str(inc.get("mode", "id")).strip().lower()
    if inc["mode"] not in ("id", "date"):
        raise ValueError("incremental.mode must be 'id' or 'date'")

    needed = "id_column" if inc["mode"] == "id" else "date_column"
    if not str(inc.get(needed, "")).strip():
        raise ValueError(f"incremental.{needed} cannot be empty when mode is '{inc['mode']}'")
    if inc["mode"] == "date" and not str(inc.get("id_column", "")).strip() \
            and not inc.get("match_columns"):
        raise ValueError("date mode needs incremental.match_columns (or id_column)")
    if int(cfg.get("performance", {}).get("batch_size", 5000)) < 1:
        raise ValueError("performance.batch_size must be at least 1")
    return cfg


# ---------------------------------------------------------------------------
# Cleaning + column mapping
# ---------------------------------------------------------------------------
def normalize_column_name(name: Any, style: str = "original") -> str:
    """Remove punctuation/spacing, then apply the configured casing."""
    text = str(name).strip()
    text = re.sub(r"[^0-9A-Za-z _]+", "", text)
    text = re.sub(r"[\s_]+", "", text).strip("_")
    if style == "upper":
        return text.upper()
    if style == "lower":
        return text.lower()
    if style == "firstcap":
        return text.capitalize()
    return text


def column_style_from_config(cfg: dict[str, Any]) -> str:
    """Configured column-name style ('original' when normalisation is off)."""
    settings = cfg.get("cleaning", {})
    if not settings.get("normalize_column_names", True):
        return "original"
    return settings.get("column_name_style", "original")


def clean_values(cfg: dict[str, Any], rows: list[list[Any]]) -> None:
    """Strip configured characters / whitespace from string cells, in place."""
    settings = cfg.get("cleaning", {})
    chars = settings.get("strip_characters", ["'", '"'])
    trim = bool(settings.get("trim_whitespace", True))
    pattern = re.compile("[" + re.escape("".join(chars)) + "]") if chars else None
    if pattern is None and not trim:
        return
    for row in rows:
        for i, value in enumerate(row):
            if isinstance(value, str):
                if pattern is not None:
                    value = pattern.sub("", value)
                if trim:
                    value = value.strip()
                row[i] = value


def build_column_map(cfg, src_columns, dest_columns, logger, warn=True):
    """Return (indices_to_keep, destination_column_names) for the INSERT."""
    normalize = cfg.get("cleaning", {}).get("normalize_column_names", True)
    style = cfg.get("cleaning", {}).get("column_name_style", "original")
    lookup = {_match_key(c): str(c).strip() for c in dest_columns}
    keep, names, dropped = [], [], []
    for i, col in enumerate(src_columns):
        clean = normalize_column_name(col, style) if normalize else str(col).strip()
        match = lookup.get(_match_key(clean))
        if match is None:
            dropped.append(col)
        else:
            keep.append(i)
            names.append(match)
    if dropped and warn:
        logger.warning("Ignoring %s source column(s) not in destination: %s", len(dropped), dropped)
    if not names:
        raise ValueError("No source columns match the destination table")
    dups = {n for n in names if names.count(n) > 1}
    if dups:
        raise ValueError(f"Several source columns map to the same destination column: {sorted(dups)}")
    return keep, names


# ---------------------------------------------------------------------------
# Logging / connections / DB helpers
# ---------------------------------------------------------------------------
def setup_logging(cfg: dict[str, Any]) -> logging.Logger:
    """Console + daily rotating file logging."""
    folder = cfg["logging"].get("log_folder", "logs")
    if not os.path.isabs(folder):
        folder = os.path.join(BASE_DIR, folder)
    os.makedirs(folder, exist_ok=True)
    logger = logging.getLogger("incremental_sync")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    logger.propagate = False
    fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s")
    fh = TimedRotatingFileHandler(
        os.path.join(folder, "incremental_sync.log"), when="midnight",
        backupCount=int(cfg["logging"].get("keep_days", 30)), encoding="utf-8")
    fh.setFormatter(fmt)
    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    logger.addHandler(fh)
    logger.addHandler(ch)
    return logger


def connection_string(section: dict[str, Any]) -> str:
    """ODBC connection string (Windows or SQL auth)."""
    parts = [f"DRIVER={{{section['driver']}}}", f"SERVER={section['server']}",
             f"DATABASE={section['database']}"]
    if section.get("auth_type", "windows").lower() == "sql":
        pwd = os.getenv(section.get("password_env", ""), section.get("password", ""))
        parts.extend([f"UID={section['username']}", f"PWD={pwd}"])
    else:
        parts.append("Trusted_Connection=yes")
    parts.append(f"Encrypt={'yes' if section.get('encrypt', False) else 'no'}")
    parts.append("TrustServerCertificate="
                 f"{'yes' if section.get('trust_server_certificate', True) else 'no'}")
    return ";".join(parts)


def connect(section: dict[str, Any]) -> pyodbc.Connection:
    """Open a transactional pyodbc connection."""
    timeout = int(section.get("connection_timeout_seconds", 30))
    return pyodbc.connect(connection_string(section), autocommit=False, timeout=timeout)


def close_quietly(conn) -> None:
    """Close a connection without masking an earlier error."""
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass


def scalar(conn, statement: str, params=None) -> Any:
    """Run a one-value query and close the cursor."""
    cur = conn.cursor()
    try:
        cur.execute(statement, params) if params else cur.execute(statement)
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        cur.close()


def table_exists(conn, schema: str, table: str) -> bool:
    """True if schema.table exists."""
    cur = conn.cursor()
    try:
        cur.execute("SELECT 1 FROM INFORMATION_SCHEMA.TABLES "
                    "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?", (schema, table))
        return cur.fetchone() is not None
    finally:
        cur.close()


def get_table_columns(conn, schema: str, table: str) -> list[str]:
    """Live column names in table order."""
    cur = conn.cursor()
    try:
        cur.execute("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
                    "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
                    (schema, table))
        return [r[0] for r in cur.fetchall()]
    finally:
        cur.close()


def acquire_applock(conn, name: str, timeout_ms: int = 60000) -> None:
    """Take a transaction-scoped exclusive app lock on the destination."""
    cur = conn.cursor()
    try:
        cur.execute("SET NOCOUNT ON; DECLARE @r int; "
                    "EXEC @r = sys.sp_getapplock @Resource=?, @LockMode='Exclusive', "
                    "@LockOwner='Transaction', @LockTimeout=?; SELECT @r;", (name, timeout_ms))
        result = cur.fetchone()[0]
    finally:
        cur.close()
    if result is None or int(result) < 0:
        raise RuntimeError(f"Could not get application lock '{name}' (code {result})")


# ---------------------------------------------------------------------------
# Single-instance lock file
# ---------------------------------------------------------------------------
LOCK_STALE_SECONDS = 6 * 60 * 60


def _pid_is_running(pid: int) -> bool:
    """Is this PID alive?"""
    if sys.platform.startswith("win"):
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _clear_lock_if_stale() -> None:
    """Delete an orphaned lock file."""
    try:
        age = time.time() - os.path.getmtime(LOCK_PATH)
        pid = None
        with open(LOCK_PATH, "r", encoding="utf-8") as fh:
            m = re.search(r"PID=(\d+)", fh.read())
            if m:
                pid = int(m.group(1))
    except (FileNotFoundError, ValueError):
        return
    if not (pid is not None and _pid_is_running(pid)) or age > LOCK_STALE_SECONDS:
        try:
            os.remove(LOCK_PATH)
        except FileNotFoundError:
            pass


@contextmanager
def single_instance_lock():
    """Prevent two copies running from the same folder."""
    _clear_lock_if_stale()
    try:
        handle = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise RuntimeError(f"Another sync appears to be running. If not, delete: {LOCK_PATH}") from exc
    try:
        os.write(handle, f"PID={os.getpid()} START={datetime.now().isoformat()}".encode("utf-8"))
        yield
    finally:
        os.close(handle)
        try:
            os.remove(LOCK_PATH)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Destination auto-create
# ---------------------------------------------------------------------------
def _column_type_sql(row: dict[str, Any]) -> str:
    """SQL type text for one source column."""
    t = str(row["type_name"]).lower()
    ml, prec, scale = row["max_length"], row["precision"], row["scale"]
    if t in {"nchar", "nvarchar"}:
        return f"{t}(max)" if ml == -1 else f"{t}({int(ml) // 2})"
    if t in {"char", "varchar", "binary", "varbinary"}:
        return f"{t}(max)" if ml == -1 else f"{t}({int(ml)})"
    if t in {"decimal", "numeric"}:
        return f"{t}({int(prec)},{int(scale)})"
    if t in {"datetime2", "time", "datetimeoffset"}:
        return f"{t}({int(scale)})"
    return t


def get_source_schema(cfg: dict[str, Any], source_conn) -> list[dict[str, Any]]:
    """Read source column definitions."""
    full_name = f"{cfg['source'].get('schema', 'dbo')}.{cfg['source']['table']}"
    query = """
        SELECT c.name AS col_name, t.name AS type_name, c.max_length AS max_length,
               c.precision AS [precision], c.scale AS scale, c.is_nullable AS is_nullable,
               c.is_identity AS is_identity,
               CAST(ic.seed_value AS bigint) AS seed_value,
               CAST(ic.increment_value AS bigint) AS increment_value
        FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE c.object_id = OBJECT_ID(?)
        ORDER BY c.column_id
    """
    cur = source_conn.cursor()
    try:
        cur.execute(query, (full_name,))
        names = [d[0] for d in cur.description]
        rows = [dict(zip(names, r)) for r in cur.fetchall()]
    finally:
        cur.close()
    if not rows:
        raise ValueError(f"Could not read schema for source table {full_name}")
    return rows


def ensure_destination_table(cfg, source_conn, dest_conn, logger) -> bool:
    """Create the destination (clean column names) only if it is missing."""
    dest = cfg["destination"]
    schema, table = dest.get("schema", "dbo"), dest["table"]
    if table_exists(dest_conn, schema, table):
        return False
    if not dest.get("auto_create", True):
        raise ValueError(f"Destination table {schema}.{table} missing and auto_create is false")
    style = column_style_from_config(cfg)
    normalize = cfg.get("cleaning", {}).get("normalize_column_names", True)
    keep_identity = bool(cfg["incremental"].get("preserve_identity", False))
    defs, names = [], []
    for row in get_source_schema(cfg, source_conn):
        clean = normalize_column_name(row["col_name"], style) if normalize else row["col_name"]
        names.append(clean)
        ident = ""
        if row["is_identity"] and keep_identity:
            ident = f" IDENTITY({int(row['seed_value'] or 1)},{int(row['increment_value'] or 1)})"
        defs.append(f"  {quote_id(clean)} {_column_type_sql(row)}{ident} "
                    f"{'NULL' if row['is_nullable'] else 'NOT NULL'}")
    if len({n.casefold() for n in names}) != len(names):
        raise ValueError("Cleaned column names collide")
    ddl = f"CREATE TABLE {full_table(dest)} (\n" + ",\n".join(defs) + "\n);"
    logger.info("Creating destination table:\n" + ddl)
    cur = dest_conn.cursor()
    try:
        cur.execute(ddl)
        dest_conn.commit()
    finally:
        cur.close()
    return True


# ---------------------------------------------------------------------------
# Validation + metrics
# ---------------------------------------------------------------------------
def active_keys(cfg) -> list[str]:
    """Config keys that must exist as columns for the chosen mode."""
    return ["id_column"] if cfg["incremental"]["mode"] == "id" else ["date_column"]


def validate_tables(cfg, source_conn, dest_conn) -> None:
    """Require both tables and the mode's key column(s) on both sides."""
    inc = cfg["incremental"]
    for label, section, conn in (("source", cfg["source"], source_conn),
                                 ("destination", cfg["destination"], dest_conn)):
        schema, table = section.get("schema", "dbo"), section["table"]
        if not table_exists(conn, schema, table):
            raise ValueError(f"{label.title()} table not found: {schema}.{table}")
        cols = get_table_columns(conn, schema, table)
        needed = list(active_keys(cfg))
        if inc["mode"] == "date":
            needed_names = [inc["date_column"]] + list(match_columns(cfg))
        else:
            needed_names = [inc[k] for k in needed]
        for name in needed_names:
            if resolve_column_name(cols, name) is None:
                raise ValueError(f"{name!r} not found in {label} table. Columns: {cols}")


def match_columns(cfg) -> list[str]:
    """Columns used to match rows during date-mode catch-up."""
    inc = cfg["incremental"]
    cols = inc.get("match_columns")
    if cols:
        return list(cols)
    out = [inc["id_column"]] if str(inc.get("id_column", "")).strip() else []
    return out + [inc["date_column"]]


def real_col(conn, section, configured_name) -> str:
    """Actual spelling of a configured column in a given table."""
    cols = get_table_columns(conn, section.get("schema", "dbo"), section["table"])
    return resolve_column_name(cols, configured_name)


def day_counts(conn, table: str, col: str, since: datetime, until: datetime, nolock: bool) -> dict:
    """Row counts by calendar date in [since, until)."""
    cur = conn.cursor()
    try:
        cur.execute(
            f"SELECT CAST({col} AS date), COUNT_BIG(1) FROM {table}"
            f"{' WITH (NOLOCK)' if nolock else ''} "
            f"WHERE {col} >= ? AND {col} < ? GROUP BY CAST({col} AS date)", (since, until))
        return {_day(r[0]): int(r[1]) for r in cur.fetchall()}
    finally:
        cur.close()


def get_metrics(cfg, src, dst) -> dict[str, Any]:
    """Counts and max values for reporting; extra fields depend on mode."""
    inc = cfg["incremental"]
    st, dt = full_table(cfg["source"]), full_table(cfg["destination"])
    m: dict[str, Any] = {
        "mode": inc["mode"],
        "source_count": int(scalar(src, f"SELECT COUNT_BIG(1) FROM {st} WITH (NOLOCK)") or 0),
        "destination_count": int(scalar(dst, f"SELECT COUNT_BIG(1) FROM {dt}") or 0),
    }
    if inc["mode"] == "id":
        sid = quote_id(real_col(src, cfg["source"], inc["id_column"]))
        did = quote_id(real_col(dst, cfg["destination"], inc["id_column"]))
        m["source_max_id"] = scalar(src, f"SELECT MAX({sid}) FROM {st} WITH (NOLOCK)")
        m["destination_max_id"] = scalar(dst, f"SELECT MAX({did}) FROM {dt}")
        last = m["destination_max_id"]
        if last is None:
            m["pending_rows"] = m["source_count"]
        else:
            m["pending_rows"] = int(scalar(
                src, f"SELECT COUNT_BIG(1) FROM {st} WITH (NOLOCK) WHERE {sid} > ?", (last,)) or 0)
    else:
        sd = quote_id(real_col(src, cfg["source"], inc["date_column"]))
        dd = quote_id(real_col(dst, cfg["destination"], inc["date_column"]))
        m["source_max_date"] = scalar(src, f"SELECT MAX({sd}) FROM {st} WITH (NOLOCK)")
        m["destination_max_date"] = scalar(dst, f"SELECT MAX({dd}) FROM {dt}")
        m["source_null_date_count"] = int(scalar(
            src, f"SELECT COUNT_BIG(1) FROM {st} WITH (NOLOCK) WHERE {sd} IS NULL") or 0)
        dmax = m["destination_max_date"]
        start = _day(dmax) + timedelta(days=1) if dmax else datetime(1900, 1, 1)
        m["pending_rows"] = int(scalar(
            src, f"SELECT COUNT_BIG(1) FROM {st} WITH (NOLOCK) WHERE {sd} >= ? AND {sd} < ?",
            (start, _today())) or 0)
    return m


# ---------------------------------------------------------------------------
# Insert helper (shared by both modes)
# ---------------------------------------------------------------------------
def insert_rows(cfg, dst, names: list[str], rows: list[list[Any]]) -> None:
    """INSERT rows into the destination inside the caller's transaction."""
    if not rows:
        return
    table = full_table(cfg["destination"])
    cols = ", ".join(quote_id(n) for n in names)
    marks = ", ".join("?" for _ in names)
    ident = bool(cfg["incremental"].get("preserve_identity", False))
    cur = dst.cursor()
    try:
        cur.fast_executemany = bool(cfg.get("performance", {}).get("fast_executemany", True))
        if ident:
            cur.execute(f"SET IDENTITY_INSERT {table} ON")
        cur.executemany(f"INSERT INTO {table} ({cols}) VALUES ({marks})", rows)
        if ident:
            cur.execute(f"SET IDENTITY_INSERT {table} OFF")
    finally:
        cur.close()


def prepare_chunk(cfg, raw_rows, src_columns, dest_columns, logger, warn=False):
    """Clean values, map columns to destination names; return (names, rows)."""
    rows = [list(r) for r in raw_rows]
    clean_values(cfg, rows)
    keep, names = build_column_map(cfg, src_columns, dest_columns, logger, warn=warn)
    return names, [[r[i] for i in keep] for r in rows]


# ---------------------------------------------------------------------------
# MODE 1: MAX(ID)
# ---------------------------------------------------------------------------
def sync_by_id(cfg, src, dst, logger) -> dict[str, int]:
    """Copy rows with ID > destination MAX(ID), in ordered batches."""
    inc = cfg["incremental"]
    batch = int(cfg.get("performance", {}).get("batch_size", 5000))
    lock_name = inc.get("applock_name", f"sync_{cfg['destination']['table']}")
    st, dt = full_table(cfg["source"]), full_table(cfg["destination"])
    sid = quote_id(real_col(src, cfg["source"], inc["id_column"]))
    did = quote_id(real_col(dst, cfg["destination"], inc["id_column"]))
    dest_cols = get_table_columns(dst, cfg["destination"].get("schema", "dbo"), cfg["destination"]["table"])

    total, batches, first = 0, 0, True
    while True:
        acquire_applock(dst, lock_name)                       # released on commit/rollback
        last = scalar(dst, f"SELECT MAX({did}) FROM {dt}")    # re-read INSIDE the lock
        cur = src.cursor()
        try:
            if last is None:
                cur.execute(f"SELECT TOP ({batch}) * FROM {st} WITH (NOLOCK) ORDER BY {sid}")
            else:
                cur.execute(f"SELECT TOP ({batch}) * FROM {st} WITH (NOLOCK) "
                            f"WHERE {sid} > ? ORDER BY {sid}", (last,))
            src_columns = [d[0] for d in cur.description]
            raw = cur.fetchall()
        finally:
            cur.close()
            src.rollback()
        if not raw:
            dst.rollback()
            break
        names, rows = prepare_chunk(cfg, raw, src_columns, dest_cols, logger, warn=first)
        first = False
        try:
            insert_rows(cfg, dst, names, rows)
            dst.commit()
        except Exception:
            dst.rollback()
            raise
        total += len(rows)
        batches += 1
        logger.info("ID mode | batch %s inserted %s rows (total %s)", batches, len(rows), total)
    return {"inserted": total, "phase1_inserted": total, "phase2_inserted": 0}


# ---------------------------------------------------------------------------
# MODE 2: MAX(date) + catch-up
# ---------------------------------------------------------------------------
def _load_day(cfg, src, dst, logger, day: datetime, dest_cols, lock_name, only_missing: bool) -> int:
    """Insert one day's rows (all of them, or only the ones missing in destination)."""
    inc = cfg["incremental"]
    batch = int(cfg.get("performance", {}).get("batch_size", 5000))
    st, dt = full_table(cfg["source"]), full_table(cfg["destination"])
    sd = quote_id(real_col(src, cfg["source"], inc["date_column"]))
    nxt = day + timedelta(days=1)

    acquire_applock(dst, lock_name)
    inserted = 0
    try:
        existing: Counter = Counter()
        key_pos: list[int] = []
        key_names: list[str] = []
        if only_missing:
            key_names = [resolve_column_name(dest_cols, c) for c in match_columns(cfg)]
            ddate = quote_id(resolve_column_name(dest_cols, inc["date_column"]))
            cur = dst.cursor()
            try:
                cur.execute(f"SELECT {', '.join(quote_id(k) for k in key_names)} FROM {dt} "
                            f"WHERE {ddate} >= ? AND {ddate} < ?", (day, nxt))
                for r in cur.fetchall():
                    existing[tuple(_key_value(v) for v in r)] += 1
            finally:
                cur.close()
        else:
            # Phase 1 safety: never load a day the destination already has rows for.
            ddate = quote_id(resolve_column_name(dest_cols, inc["date_column"]))
            if int(scalar(dst, f"SELECT COUNT_BIG(1) FROM {dt} WHERE {ddate} >= ? AND {ddate} < ?",
                          (day, nxt)) or 0) > 0:
                dst.rollback()
                logger.warning("Date %s already has rows in destination; left to catch-up", day.date())
                return 0

        cur = src.cursor()
        try:
            cur.execute(f"SELECT * FROM {st} WITH (NOLOCK) WHERE {sd} >= ? AND {sd} < ?", (day, nxt))
            src_columns = [d[0] for d in cur.description]
            while True:
                raw = cur.fetchmany(batch)
                if not raw:
                    break
                names, rows = prepare_chunk(cfg, raw, src_columns, dest_cols, logger)
                if only_missing:
                    if not key_pos:
                        key_pos = [names.index(k) for k in key_names]
                    fresh = []
                    for r in rows:
                        key = tuple(_key_value(r[p]) for p in key_pos)
                        if existing[key] > 0:
                            existing[key] -= 1          # already in destination
                        else:
                            fresh.append(r)
                    rows = fresh
                insert_rows(cfg, dst, names, rows)
                inserted += len(rows)
        finally:
            cur.close()
            src.rollback()
        dst.commit()
    except Exception:
        dst.rollback()
        raise
    return inserted


def sync_by_date(cfg, src, dst, logger, catchup_days: int) -> dict[str, int]:
    """Phase 1: new complete days. Phase 2: repair recent under-counted days."""
    inc = cfg["incremental"]
    lock_name = inc.get("applock_name", f"sync_{cfg['destination']['table']}")
    st, dt = full_table(cfg["source"]), full_table(cfg["destination"])
    sd = quote_id(real_col(src, cfg["source"], inc["date_column"]))
    dd = quote_id(real_col(dst, cfg["destination"], inc["date_column"]))
    dest_cols = get_table_columns(dst, cfg["destination"].get("schema", "dbo"), cfg["destination"]["table"])
    today = _today()

    # ---- Phase 1 ----------------------------------------------------------
    dmax = scalar(dst, f"SELECT MAX({dd}) FROM {dt}")
    dst.rollback()
    if dmax is None:
        smin = scalar(src, f"SELECT MIN({sd}) FROM {st} WITH (NOLOCK)")
        src.rollback()
        start = _day(smin) if smin else today
    else:
        start = _day(dmax) + timedelta(days=1)
    p1 = 0
    if start < today:
        days = sorted(day_counts(src, st, sd, start, today, nolock=True))
        src.rollback()
        for day in days:
            n = _load_day(cfg, src, dst, logger, day, dest_cols, lock_name, only_missing=False)
            p1 += n
            logger.info("Date mode P1 | %s inserted %s rows", day.date(), n)
    logger.info("Phase 1 done | inserted=%s (today %s skipped)", p1, today.date())

    # ---- Phase 2 ----------------------------------------------------------
    p2 = 0
    if catchup_days > 0:
        since = today - timedelta(days=catchup_days)
        sc = day_counts(src, st, sd, since, today, nolock=True)
        src.rollback()
        dc = day_counts(dst, dt, dd, since, today, nolock=False)
        dst.rollback()
        gaps = sorted(d for d, n in sc.items() if n > dc.get(d, 0))
        logger.info("Phase 2 | %s day(s) with missing rows in last %s days", len(gaps), catchup_days)
        for day in gaps:
            n = _load_day(cfg, src, dst, logger, day, dest_cols, lock_name, only_missing=True)
            p2 += n
            logger.info("Date mode P2 | %s source=%s dest_before=%s inserted=%s",
                        day.date(), sc[day], dc.get(day, 0), n)
    return {"inserted": p1 + p2, "phase1_inserted": p1, "phase2_inserted": p2}


# ---------------------------------------------------------------------------
# Email
# ---------------------------------------------------------------------------
def send_email(cfg, subject: str, body: str, logger) -> None:
    """Send a plain-text email if email.enabled is true."""
    e = cfg["email"]
    if not e.get("enabled", False):
        logger.info("Email disabled in config")
        return
    to = e["to"] if isinstance(e["to"], list) else [x.strip() for x in str(e["to"]).split(",")]
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = f"{e.get('subject_prefix', '[Sync]')} {subject}"
    msg["From"] = e.get("from", e.get("username", "sync@localhost"))
    msg["To"] = ", ".join(to)
    try:
        with smtplib.SMTP(e["smtp_server"], int(e.get("smtp_port", 25)), timeout=30) as s:
            if e.get("use_tls", False):
                s.starttls()
            if e.get("username"):
                pwd = os.getenv(e.get("password_env", ""), e.get("password", ""))
                s.login(e["username"], pwd)
            s.sendmail(msg["From"], to, msg.as_string())
        logger.info("Email sent to %s", to)
    except Exception as exc:                      # never fail the sync because of email
        logger.error("Email failed: %s", exc)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def format_metrics(m: dict[str, Any]) -> str:
    """Readable key: value lines."""
    return "\n".join(f"  {k}: {v}" for k, v in m.items())


def open_both(cfg):
    """Open source and destination connections."""
    src = connect(cfg["source"])
    try:
        dst = connect(cfg["destination"])
    except Exception:
        close_quietly(src)
        raise
    return src, dst


def cmd_report(cfg, logger, create_missing: bool) -> dict[str, Any]:
    """--test / --check: connect, validate, print metrics (no data insert)."""
    src, dst = open_both(cfg)
    try:
        logger.info("Source:      %s", describe_target(cfg["source"]))
        logger.info("Destination: %s", describe_target(cfg["destination"]))
        if create_missing:
            ensure_destination_table(cfg, src, dst, logger)
        validate_tables(cfg, src, dst)
        m = get_metrics(cfg, src, dst)
        logger.info("Metrics:\n%s", format_metrics(m))
        return m
    finally:
        close_quietly(src)
        close_quietly(dst)


def cmd_once(cfg, logger, catchup_days: int) -> dict[str, Any]:
    """--once: run the sync for the configured mode."""
    started = datetime.now()
    src, dst = open_both(cfg)
    try:
        ensure_destination_table(cfg, src, dst, logger)
        validate_tables(cfg, src, dst)
        before = get_metrics(cfg, src, dst)
        src.rollback()
        dst.rollback()
        logger.info("Mode=%s | before:\n%s", cfg["incremental"]["mode"], format_metrics(before))
        if cfg["incremental"]["mode"] == "id":
            result = sync_by_id(cfg, src, dst, logger)
        else:
            result = sync_by_date(cfg, src, dst, logger, catchup_days)
        after = get_metrics(cfg, src, dst)
        result["seconds"] = round((datetime.now() - started).total_seconds(), 1)
        logger.info("Finished | %s\nafter:\n%s", result, format_metrics(after))
        body = (f"Host: {socket.gethostname()}\nMode: {cfg['incremental']['mode']}\n"
                f"Source: {describe_target(cfg['source'])}\n"
                f"Destination: {describe_target(cfg['destination'])}\n\n"
                f"Result: {result}\n\nAfter:\n{format_metrics(after)}\n")
        send_email(cfg, f"OK - inserted {result['inserted']} rows", body, logger)
        return result
    finally:
        close_quietly(src)
        close_quietly(dst)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="SQL Server incremental sync (id or date mode)")
    ap.add_argument("--test", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--create-dest", action="store_true")
    ap.add_argument("--email-test", action="store_true")
    ap.add_argument("--mode", choices=["id", "date"], help="override incremental.mode")
    ap.add_argument("--catchup-days", type=int, help="override incremental.catchup_days")
    args = ap.parse_args()

    cfg = load_config(args.mode)
    logger = setup_logging(cfg)
    catchup = args.catchup_days if args.catchup_days is not None \
        else int(cfg["incremental"].get("catchup_days", 30))
    try:
        if args.email_test:
            send_email(cfg, "Test email", f"Test from {socket.gethostname()}", logger)
        elif args.create_dest:
            src, dst = open_both(cfg)
            try:
                made = ensure_destination_table(cfg, src, dst, logger)
                logger.info("Destination %s", "created" if made else "already exists")
            finally:
                close_quietly(src)
                close_quietly(dst)
        elif args.test:
            cmd_report(cfg, logger, create_missing=False)
        elif args.check:
            cmd_report(cfg, logger, create_missing=False)
        elif args.once:
            with single_instance_lock():
                cmd_once(cfg, logger, catchup)
        else:
            ap.print_help()
        return 0
    except Exception as exc:
        logger.exception("Sync failed: %s", exc)
        try:
            send_email(cfg, "FAILED", f"Host: {socket.gethostname()}\nError: {exc}", logger)
        except Exception:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# pyright: reportMissingImports=false, reportMissingModuleSource=false
"""Safe local Attic cache repack/migration helper.

Remote deployment, systemd service management, and secret provisioning are owned
outside this tool. This CLI only reads old Attic metadata/chunks, consumes or
creates raw NAR spool files, uploads through Attic HTTP API, and verifies the new
cache before marking checkpoint entries complete.
"""

from __future__ import annotations

import argparse
import concurrent.futures
from collections import deque
import contextlib
import gzip
import hashlib
import itertools
import io
import json
import lzma
import os
import pathlib
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from typing import Any, BinaryIO, Iterator


DEFAULT_OLD_DB = "file:/var/lib/atticd/server.db?mode=ro"
DEFAULT_STATE_DIR = "/var/lib/attic-repack"
DEFAULT_OLD_URL = "http://127.0.0.1:8081"
DEFAULT_NEW_URL = "http://127.0.0.1:8082"
DEFAULT_HOST = "cache.hectic-lab.com"
DEFAULT_CACHE = "hectic"
DEFAULT_OLD_BUCKET = "cache-hectic-lab"
DEFAULT_OLD_REGION = "hel1"
DEFAULT_OLD_ENDPOINT = "https://hel1.your-objectstorage.com"
IMMUTABLE_FIELDS = ("StorePath", "NarHash", "NarSize", "References", "Deriver", "System", "CA", "Sig")
TOKEN_ENV = "ATTIC_MIGRATION_TOKEN"
CHUNK = 1024 * 1024


class RepackError(RuntimeError):
    """Expected operational failure with sanitized message."""


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def now() -> float:
    return time.time()


def require_private(path: pathlib.Path, directory: bool) -> None:
    mode = 0o700 if directory else 0o600
    if directory:
        path.mkdir(parents=True, exist_ok=True, mode=mode)
    else:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.touch(mode=mode, exist_ok=True)
    os.chmod(path, mode)


@contextlib.contextmanager
def private_umask() -> Iterator[None]:
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    require_private(path.parent, True)
    with private_umask():
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def atomic_json(path: pathlib.Path, value: Any) -> None:
    atomic_write(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode())


def load_json(path: pathlib.Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def sha256_file(path: pathlib.Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            data = handle.read(CHUNK)
            if not data:
                break
            h.update(data)
            size += len(data)
    return h.hexdigest(), size


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def nar_hash_hex(nar_hash: str) -> str:
    if not nar_hash.startswith("sha256:"):
        raise RepackError("bad nar_hash scheme")
    value = nar_hash.split(":", 1)[1]
    if len(value) != 64 or any(c not in "0123456789abcdef" for c in value.lower()):
        raise RepackError("bad nar_hash hex")
    return value.lower()


def store_hash(store_path: str) -> str:
    name = pathlib.PurePosixPath(store_path).name
    if "-" not in name:
        raise RepackError(f"bad store path: {store_path}")
    return name.split("-", 1)[0]


def json_list(value: Any) -> list[str]:
    if value in (None, ""):
        return []
    if isinstance(value, list):
        return [str(v) for v in value]
    return [str(v) for v in json.loads(value)]


def retention_from_db(value: Any) -> Any:
    if value in (None, "", "Global", "global"):
        return "Global"
    if isinstance(value, int):
        return {"Period": value}
    with contextlib.suppress(Exception):
        loaded = json.loads(value)
        if loaded in (None, "Global"):
            return "Global"
        if isinstance(loaded, int):
            return {"Period": loaded}
        return loaded
    return {"Period": int(value)}


def upload_metadata(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "cache": record["cache"],
        "store_path_hash": record["store_path_hash"],
        "store_path": record["store_path"],
        "references": sorted(record.get("references") or []),
        "system": record.get("system"),
        "deriver": record.get("deriver"),
        "sigs": sorted(record.get("sigs") or []),
        "ca": record.get("ca"),
        "nar_hash": record["nar_hash"],
        "nar_size": int(record["nar_size"]),
    }


def metadata_fingerprint(record: dict[str, Any]) -> str:
    return sha256_bytes(json.dumps(upload_metadata(record), sort_keys=True, separators=(",", ":")).encode())


def parse_narinfo(data: bytes | str) -> dict[str, Any]:
    text = data.decode() if isinstance(data, bytes) else data
    result: dict[str, Any] = {"Sig": []}
    refs: list[str] | None = None
    for line in text.splitlines():
        if not line or ": " not in line:
            continue
        key, value = line.split(": ", 1)
        if key == "References":
            refs = [v for v in value.split() if v]
        elif key == "Sig":
            result.setdefault("Sig", []).append(value)
        else:
            result[key] = value
    result["References"] = sorted(refs or [])
    result["Sig"] = sorted(result.get("Sig", []))
    return result


def expected_narinfo(record: dict[str, Any]) -> dict[str, Any]:
    meta = upload_metadata(record)
    expect = {
        "StorePath": meta["store_path"],
        "NarHash": meta["nar_hash"],
        "NarSize": str(meta["nar_size"]),
        "References": sorted(meta["references"]),
        "Sig": sorted(meta["sigs"]),
    }
    optional = (("Deriver", meta.get("deriver")), ("System", meta.get("system")), ("CA", meta.get("ca")))
    for key, value in optional:
        if value not in (None, ""):
            expect[key] = str(value)
    return expect


def normalize_narinfo_for_compare(narinfo: dict[str, Any]) -> dict[str, Any]:
    out = dict(narinfo)
    refs = out.get("References") or []
    out["References"] = sorted(store_basename(v) for v in refs)
    if out.get("Deriver"):
        out["Deriver"] = store_basename(str(out["Deriver"]))
    out["Sig"] = sorted(out.get("Sig") or [])
    return out


def store_basename(value: str) -> str:
    if value.startswith("/nix/store/"):
        return pathlib.PurePosixPath(value).name
    return value


def compare_narinfo(expected: dict[str, Any], narinfo: dict[str, Any], fields: tuple[str, ...] = IMMUTABLE_FIELDS) -> list[str]:
    expect = normalize_narinfo_for_compare(expected)
    got_info = normalize_narinfo_for_compare(narinfo)
    diffs: list[str] = []
    for key in fields:
        if key not in expect and key not in got_info:
            continue
        value = expect.get(key, [] if key in ("References", "Sig") else None)
        got = got_info.get(key, [] if key in ("References", "Sig") else None)
        if isinstance(value, list):
            got = sorted(got or [])
        if got != value:
            diffs.append(key)
    return sorted(set(diffs))


def sanitized_error(exc: BaseException) -> str:
    if isinstance(exc, RepackError):
        msg = str(exc)
        allowed = []
        for ch in msg[:220]:
            allowed.append(ch if ch.isalnum() or ch in " ._:/,-" else "_")
        return "RepackError: " + "".join(allowed)
    return exc.__class__.__name__


def safe_headers(host: str | None = None, token: str | None = None) -> dict[str, str]:
    headers: dict[str, str] = {}
    if host:
        headers["Host"] = host
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def assert_secret_url_safe(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http":
        return
    host = parsed.hostname or ""
    if host not in ("127.0.0.1", "::1", "localhost"):
        raise RepackError("refusing authenticated HTTP to non-loopback host")


def join_url(base: str, path: str) -> str:
    return base.rstrip("/") + "/" + path.lstrip("/")


def requests_module() -> Any:
    import requests

    return requests


def zstd_module() -> Any:
    import zstandard

    return zstandard



class TokenProvider:
    def __init__(self, atticadm: str | None, server_config: str | None, cache: str) -> None:
        self.atticadm = atticadm
        self.server_config = server_config
        self.cache = cache
        self._token = os.environ.get(TOKEN_ENV)
        self._expires = now() + 60 * 50 if self._token else 0.0
        self._lock = threading.Lock()

    def get(self) -> str:
        with self._lock:
            if self._token and now() < self._expires - 300:
                return self._token
            if not self.atticadm or not self.server_config:
                raise RepackError(f"{TOKEN_ENV} or --atticadm/--server-config required")
            cmd = [
                self.atticadm,
                "--config",
                self.server_config,
                "make-token",
                "--sub",
                "attic-repack",
                "--validity",
                "2h",
                "--pull",
                self.cache,
                "--push",
                self.cache,
                "--create-cache",
                self.cache,
                "--configure-cache",
                self.cache,
                "--configure-cache-retention",
                self.cache,
            ]
            env = {k: v for k, v in os.environ.items() if k != TOKEN_ENV}
            proc = subprocess.run(cmd, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            token = proc.stdout.strip().splitlines()[-1]
            if not token:
                raise RepackError("atticadm returned empty token")
            self._token = token
            self._expires = now() + 60 * 110
            return token


class AtticClient:
    def __init__(self, base_url: str, cache: str, host: str | None, token_provider: TokenProvider | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.cache = cache
        self.host = host
        self.token_provider = token_provider
        self._local = threading.local()

    def session(self) -> Any:
        sess = getattr(self._local, "session", None)
        if sess is None:
            sess = requests_module().Session()
            self._local.session = sess
        return sess

    def api_headers(self) -> dict[str, str]:
        token = self.token_provider.get() if self.token_provider else None
        if token:
            assert_secret_url_safe(self.base_url)
        return safe_headers(self.host, token)

    def public_headers(self) -> dict[str, str]:
        return safe_headers(self.host, None)

    def _request(self, method: str, url: str, *, auth: bool, **kwargs: Any) -> Any:
        headers = kwargs.pop("headers", {}) or {}
        headers = {**(self.api_headers() if auth else self.public_headers()), **headers}
        allow_redirects = False if auth else kwargs.pop("allow_redirects", True)
        try:
            resp = self.session().request(method, url, headers=headers, allow_redirects=allow_redirects, **kwargs)
            if auth and 300 <= resp.status_code < 400:
                raise RepackError(f"HTTP redirect refused {method} {urllib.parse.urlsplit(url).path}")
            if resp.status_code >= 400:
                raise RepackError(f"HTTP {resp.status_code} {method} {urllib.parse.urlsplit(url).path}")
            return resp
        except Exception as exc:
            if isinstance(exc, RepackError):
                raise
            raise RepackError(exc.__class__.__name__) from exc

    def _public_stream(self, url: str) -> Any:
        sess = self.session()
        headers = self.public_headers()
        current = url
        for _ in range(5):
            resp = sess.request("GET", current, headers=headers, allow_redirects=False, stream=True, timeout=(10, 600))
            if 300 <= resp.status_code < 400:
                loc = resp.headers.get("Location")
                with contextlib.suppress(Exception):
                    resp.close()
                if not loc:
                    raise RepackError("public redirect missing location")
                next_url = urllib.parse.urljoin(current, loc)
                if urllib.parse.urlsplit(next_url).netloc != urllib.parse.urlsplit(current).netloc:
                    headers = {}
                current = next_url
                continue
            if resp.status_code >= 400:
                raise RepackError(f"HTTP {resp.status_code} GET {urllib.parse.urlsplit(current).path}")
            return resp
        raise RepackError("too many public redirects")

    def get_cache_config(self) -> dict[str, Any] | None:
        url = join_url(self.base_url, f"_api/v1/cache-config/{self.cache}")
        try:
            return self._request("GET", url, auth=True, timeout=(10, 60)).json()
        except RepackError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise

    def narinfo_url(self, store_path_hash: str) -> str:
        return join_url(self.base_url, f"{self.cache}/{store_path_hash}.narinfo")

    def create_cache(self, config: dict[str, Any]) -> None:
        url = join_url(self.base_url, f"_api/v1/cache-config/{self.cache}")
        self._request("POST", url, auth=True, json=config, timeout=(10, 60))

    def patch_retention(self, retention: Any) -> None:
        if retention is None:
            return
        url = join_url(self.base_url, f"_api/v1/cache-config/{self.cache}")
        self._request("PATCH", url, auth=True, json={"retention_period": retention}, timeout=(10, 60))

    def get_narinfo(self, store_path_hash: str) -> dict[str, Any] | None:
        url = self.narinfo_url(store_path_hash)
        try:
            resp = self._public_stream(url)
            try:
                return parse_narinfo(resp.content)
            finally:
                with contextlib.suppress(Exception):
                    resp.close()
        except RepackError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise

    def upload(self, record: dict[str, Any], nar_path: pathlib.Path) -> None:
        meta = upload_metadata(record)
        prefix = json.dumps(meta, sort_keys=True, separators=(",", ":")).encode()
        nar_size = nar_path.stat().st_size
        headers = {"X-Attic-Nar-Info-Preamble-Size": str(len(prefix)), "Content-Length": str(len(prefix) + nar_size)}
        url = join_url(self.base_url, "_api/v1/upload-path")

        for attempt in range(3):
            with PrefixFileBody(prefix, nar_path) as body:
                try:
                    self._request("PUT", url, auth=True, data=body, headers=headers, timeout=(10, 600))
                    return
                except RepackError:
                    if attempt == 2:
                        raise
                    time.sleep(0.5 * (2**attempt))

    def verify_payload(self, narinfo: dict[str, Any], expected_hash: str, expected_size: int, narinfo_url: str) -> None:
        raw_url = narinfo.get("URL")
        if not raw_url:
            raise RepackError("new narinfo missing URL")
        url = urllib.parse.urljoin(narinfo_url, raw_url)
        resp = self._public_stream(url)
        compression = (narinfo.get("Compression") or pathlib.PurePosixPath(raw_url).suffix.lstrip(".")).lower()
        h = hashlib.sha256()
        size = 0
        source = resp.raw
        if compression in ("zstd", "zst"):
            reader = zstd_module().ZstdDecompressor().stream_reader(source, read_across_frames=True)
        elif compression in ("", "none"):
            reader = source
        elif compression == "gzip" or compression == "gz":
            reader = gzip.GzipFile(fileobj=source)
        elif compression == "xz":
            reader = lzma.LZMAFile(source)
        else:
            raise RepackError(f"unsupported new nar compression {compression}")
        try:
            with contextlib.closing(reader):
                while True:
                    data = reader.read(CHUNK)
                    if not data:
                        break
                    h.update(data)
                    size += len(data)
        finally:
            with contextlib.suppress(Exception):
                resp.close()
        if h.hexdigest() != expected_hash or size != expected_size:
            raise RepackError("new NAR payload hash/size mismatch")


class PrefixFileBody:
    def __init__(self, prefix: bytes, path: pathlib.Path) -> None:
        self.prefix = prefix
        self.path = path
        self.file: BinaryIO | None = None
        self.pos = 0
        self.size = len(prefix) + path.stat().st_size

    def __enter__(self) -> "PrefixFileBody":
        self.file = self.path.open("rb")
        return self

    def __exit__(self, *_args: object) -> None:
        if self.file:
            self.file.close()

    def __len__(self) -> int:
        return self.size

    def tell(self) -> int:
        return self.pos

    def read(self, n: int = -1) -> bytes:
        if self.file is None:
            raise RepackError("upload body not open")
        if self.pos >= self.size:
            return b""
        want = self.size - self.pos if n is None or n < 0 else n
        parts: list[bytes] = []
        if self.pos < len(self.prefix) and want > 0:
            chunk = self.prefix[self.pos : min(len(self.prefix), self.pos + want)]
            parts.append(chunk)
            self.pos += len(chunk)
            want -= len(chunk)
        if want > 0:
            data = self.file.read(want)
            parts.append(data)
            self.pos += len(data)
        return b"".join(parts)


class InventoryDB:
    def __init__(self, uri: str, cache: str) -> None:
        self.uri = readonly_sqlite_uri(uri)
        self.cache = cache

    def connect(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.uri, uri=True)
        con.row_factory = sqlite3.Row
        return con

    def cache_row(self) -> dict[str, Any]:
        with self.connect() as con:
            row = con.execute(
                "select name,keypair,is_public,store_dir,priority,upstream_cache_key_names,retention_period "
                "from cache where name=? and deleted_at is null",
                (self.cache,),
            ).fetchone()
        if row is None:
            raise RepackError(f"cache not found in old DB: {self.cache}")
        return dict(row)

    def records(self, paths: set[str] | None = None, limit: int | None = None) -> list[dict[str, Any]]:
        sql = (
            'select c.name as cache,o.nar_id,o.store_path_hash,o.store_path,o."references",o.system,o.deriver,o.sigs,o.ca,'
            "n.nar_hash,n.nar_size,n.state as nar_state "
            "from object o join cache c on c.id=o.cache_id join nar n on n.id=o.nar_id "
            "where c.name=? and c.deleted_at is null and (n.state='V' or n.state='valid') "
            "order by o.store_path"
        )
        args: list[Any] = [self.cache]
        with self.connect() as con:
            rows = con.execute(sql, args).fetchall()
        out: list[dict[str, Any]] = []
        for row in rows:
            record = dict(row)
            record["references"] = json_list(record.get("references"))
            record["sigs"] = json_list(record.get("sigs"))
            record["nar_size"] = int(record["nar_size"])
            record["nar_hash"] = record["nar_hash"] if str(record["nar_hash"]).startswith("sha256:") else f"sha256:{record['nar_hash']}"
            nar_hash_hex(record["nar_hash"])
            if paths and record["store_path"] not in paths:
                continue
            out.append(record)
            if limit and len(out) >= limit:
                break
        return out

    def chunk_rows(self, nar_id: int) -> list[dict[str, Any]]:
        sql = (
            "select cr.seq,ch.chunk_hash,ch.chunk_size,ch.file_hash,ch.file_size,ch.compression,ch.remote_file,ch.state "
            "from chunkref cr join chunk ch on ch.id=cr.chunk_id where cr.nar_id=? order by cr.seq"
        )
        with self.connect() as con:
            return [dict(r) for r in con.execute(sql, (nar_id,)).fetchall()]


def readonly_sqlite_uri(value: str) -> str:
    if value == ":memory:":
        return "file::memory:?mode=ro"
    if value.startswith("file:"):
        parsed = urllib.parse.urlsplit(value)
        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        modes = qs.get("mode")
        if modes and modes != ["ro"]:
            raise RepackError("old DB URI must use mode=ro")
        qs["mode"] = ["ro"]
        query = urllib.parse.urlencode(qs, doseq=True)
        return urllib.parse.urlunsplit(parsed._replace(query=query))
    path = pathlib.Path(value)
    if not path.exists():
        raise RepackError("old DB path missing")
    return "file:" + urllib.parse.quote(str(path.resolve())) + "?mode=ro"


class State:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.raw = root / "raw"
        self.chunks = root / "chunks"
        self.checkpoints = root / "checkpoints"
        for path in (root, self.raw, self.chunks, self.checkpoints):
            require_private(path, True)

    def raw_path(self, nar_hash: str) -> pathlib.Path:
        return self.raw / f"{nar_hash}.nar"

    def checkpoint_path(self, store_path_hash: str) -> pathlib.Path:
        return self.checkpoints / f"{store_path_hash}.json"

    def get_checkpoint(self, record: dict[str, Any]) -> dict[str, Any]:
        return load_json(self.checkpoint_path(record["store_path_hash"]), {})

    def set_checkpoint(self, record: dict[str, Any], status: str, tries: int, error: str | None = None) -> None:
        value = {
            "store_path": record["store_path"],
            "store_path_hash": record["store_path_hash"],
            "nar_hash": record["nar_hash"],
            "metadata_fingerprint": metadata_fingerprint(record),
            "status": status,
            "tries": tries,
            "updated_at": int(now()),
        }
        if error:
            value["error"] = sanitized_error(RepackError(error))
        atomic_json(self.checkpoint_path(record["store_path_hash"]), value)


class NarLocks:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._locks: dict[str, threading.Lock] = {}

    @contextlib.contextmanager
    def hold(self, key: str) -> Iterator[None]:
        with self._lock:
            lock = self._locks.setdefault(key, threading.Lock())
        lock.acquire()
        try:
            yield
        finally:
            lock.release()


class OldS3Assembler:
    def __init__(self, db: InventoryDB, state: State, endpoint: str, bucket: str, region: str) -> None:
        self.db = db
        self.state = state
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self._local = threading.local()

    def client(self) -> Any:
        client = getattr(self._local, "client", None)
        if client is None:
            import boto3
            from botocore.config import Config

            cfg = Config(retries={"mode": "standard", "max_attempts": 3}, max_pool_connections=8, connect_timeout=10, read_timeout=60)
            client = boto3.session.Session().client("s3", endpoint_url=self.endpoint, region_name=self.region, config=cfg)
            self._local.client = client
        return client

    def assemble(self, record: dict[str, Any], out_path: pathlib.Path) -> None:
        rows = self.db.chunk_rows(int(record["nar_id"]))
        if not rows:
            raise RepackError("old S3 chunkrefs missing")
        seqs = [int(r["seq"]) for r in rows]
        if seqs != list(range(seqs[0], seqs[0] + len(seqs))):
            raise RepackError("old S3 chunk sequence has gaps")
        expected_hash = nar_hash_hex(record["nar_hash"])
        expected_size = int(record["nar_size"])
        h = hashlib.sha256()
        size = 0
        tmp = out_path.with_suffix(".tmp")
        def read_chunk(row: dict[str, Any]) -> bytes:
            data = self._compressed_chunk(row)
            plain = decompress_chunk(data, str(row.get("compression") or "none"))
            verify_hash_size(plain, row.get("chunk_hash"), row.get("chunk_size"), "chunk")
            return plain

        with private_umask(), tmp.open("wb") as dst, concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            remaining = iter(rows)
            pending = deque(pool.submit(read_chunk, row) for row in itertools.islice(remaining, 4))
            try:
                while pending:
                    plain = pending.popleft().result()
                    dst.write(plain)
                    h.update(plain)
                    size += len(plain)
                    row = next(remaining, None)
                    if row is not None:
                        pending.append(pool.submit(read_chunk, row))
            finally:
                for future in pending:
                    future.cancel()
            dst.flush()
            os.fsync(dst.fileno())
        os.chmod(tmp, 0o600)
        if h.hexdigest() != expected_hash or size != expected_size:
            tmp.unlink(missing_ok=True)
            raise RepackError("assembled old NAR hash/size mismatch")
        os.replace(tmp, out_path)

    def _compressed_chunk(self, row: dict[str, Any]) -> bytes:
        remote = json.loads(row["remote_file"])
        s3 = remote.get("S3") if isinstance(remote, dict) else None
        if not s3 or s3.get("bucket") != self.bucket or s3.get("region") != self.region:
            raise RepackError("old S3 remote_file bucket/region mismatch")
        if row.get("state") not in ("V", "valid", None):
            raise RepackError("old S3 chunk state not valid")
        key = s3.get("key")
        if not key:
            raise RepackError("old S3 key missing")
        cache_key = sha256_bytes(key.encode())
        cached = self.state.chunks / f"{cache_key}.chunk"
        if cached.exists():
            data = cached.read_bytes()
            verify_hash_size(data, row.get("file_hash"), row.get("file_size"), "compressed chunk")
            return data
        last: BaseException | None = None
        for attempt in range(5):
            try:
                obj = self.client().get_object(Bucket=self.bucket, Key=key)
                body = obj["Body"]
                try:
                    data = body.read()
                finally:
                    with contextlib.suppress(Exception):
                        body.close()
                verify_hash_size(data, row.get("file_hash"), row.get("file_size"), "compressed chunk")
                atomic_write(cached, data)
                return data
            except Exception as exc:  # boto exceptions sanitized at caller
                last = exc
                time.sleep(min(8, 0.5 * (2**attempt)))
        raise RepackError("old S3 get failed")


def verify_hash_size(data: bytes, hash_value: Any, size_value: Any, label: str) -> None:
    if size_value not in (None, "") and len(data) != int(size_value):
        raise RepackError(f"{label} size mismatch")
    if hash_value in (None, ""):
        return
    text = str(hash_value)
    if text.startswith("sha256:"):
        text = text.split(":", 1)[1]
    if len(text) != 64 or any(c not in "0123456789abcdefABCDEF" for c in text):
        raise RepackError(f"{label} hash format invalid")
    if sha256_bytes(data) != text.lower():
        raise RepackError(f"{label} hash mismatch")


def decompress_chunk(data: bytes, compression: str) -> bytes:
    c = compression.lower()
    if c in ("none", "", "null"):
        return data
    if c in ("zstd", "zst"):
        reader = zstd_module().ZstdDecompressor().stream_reader(io.BytesIO(data), read_across_frames=True)
        with contextlib.closing(reader):
            return reader.read()
    if c in ("gzip", "gz"):
        return gzip.decompress(data)
    if c == "xz":
        return lzma.decompress(data)
    raise RepackError(f"unsupported old chunk compression {compression}")


class Migrator:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.db = InventoryDB(args.old_db, args.cache)
        self.state = State(pathlib.Path(args.state_dir))
        self.tokens = TokenProvider(args.atticadm, args.server_config, args.cache)
        self.old_client = AtticClient(args.old_url, args.cache, args.host, self.tokens)
        self.new_client = AtticClient(args.new_url, args.cache, args.host, self.tokens)
        self.s3 = OldS3Assembler(self.db, self.state, args.old_storage_endpoint, args.old_bucket, args.old_region)
        self.locks = NarLocks()

    def selected_records(self) -> list[dict[str, Any]]:
        paths = None
        if self.args.paths_file:
            paths = {p.strip() for p in pathlib.Path(self.args.paths_file).read_text().splitlines() if p.strip()}
        return self.db.records(paths=paths, limit=self.args.limit)

    def init_cache(self) -> None:
        row = self.db.cache_row()
        keypair = row.get("keypair")
        if not keypair:
            raise RepackError("old cache keypair missing")
        create = {
            "keypair": {"Keypair": keypair},
            "is_public": bool(row["is_public"]),
            "store_dir": row["store_dir"] or "/nix/store",
            "priority": int(row["priority"]),
            "upstream_cache_key_names": json_list(row.get("upstream_cache_key_names")),
        }
        old_cfg = self.old_client.get_cache_config() or {}
        new_cfg = self.new_client.get_cache_config()
        old_public = old_cfg.get("public_key")
        if not old_public:
            raise RepackError("old cache public_key missing")
        if new_cfg:
            mismatch = []
            if new_cfg.get("public_key") != old_public:
                mismatch.append("public_key")
            for key in ("is_public", "store_dir", "priority", "upstream_cache_key_names"):
                if key in new_cfg and new_cfg.get(key) != create[key]:
                    mismatch.append(key)
            if mismatch:
                raise RepackError("new cache exists with mismatched settings: " + ",".join(sorted(mismatch)))
            self.new_client.patch_retention(retention_from_db(row.get("retention_period")))
            print(json.dumps({"exists": True, "public_key_matches": True}, sort_keys=True))
        else:
            self.new_client.create_cache(create)
            new_cfg = self.new_client.get_cache_config()
            if not new_cfg or new_cfg.get("public_key") != old_public:
                raise RepackError("created cache public_key mismatch")
            self.new_client.patch_retention(retention_from_db(row.get("retention_period")))
            print(json.dumps({"created": True, "public_key_matches": True}, sort_keys=True))

    def inventory(self) -> None:
        records = self.selected_records()
        manifest = {
            "format": "attic-repack-inventory-v1",
            "cache": self.args.cache,
            "generated_at": int(now()),
            "spool_dir": str(self.state.raw),
            "raw_nar_filename": "{sha256hex}.nar",
            "records": [{**upload_metadata(r), "metadata_fingerprint": metadata_fingerprint(r)} for r in records],
        }
        print(json.dumps(manifest, sort_keys=True, indent=2))

    def status(self) -> None:
        records = self.selected_records()
        unique: dict[str, int] = {}
        counts = {"verified": 0, "failed": 0, "pending": 0}
        total_bytes = 0
        for r in records:
            h = nar_hash_hex(r["nar_hash"])
            unique[h] = int(r["nar_size"])
            total_bytes += int(r["nar_size"])
            cp = self.state.get_checkpoint(r)
            if cp.get("metadata_fingerprint") != metadata_fingerprint(r):
                counts["pending"] += 1
            elif cp.get("status") == "verified":
                counts["verified"] += 1
            elif cp.get("status") == "failed":
                counts["failed"] += 1
            else:
                counts["pending"] += 1
        print(json.dumps({"inventory_total": len(records), "migrated_verified": counts["verified"], "missing_failed": counts["failed"], "pending": counts["pending"], "unique_nar": len(unique), "total_bytes": total_bytes}, sort_keys=True))

    def migrate(self, verify_only: bool = False) -> int:
        records = self.selected_records()
        q: queue.Queue[tuple[str, str]] = queue.Queue()
        failures = 0

        def work(record: dict[str, Any]) -> None:
            tries = int(self.state.get_checkpoint(record).get("tries", 0)) + 1
            try:
                if verify_only:
                    if not self.verify_record(record, force_payload=True):
                        raise RepackError("new narinfo missing")
                else:
                    self.migrate_record(record)
                self.state.set_checkpoint(record, "verified", tries)
                q.put(("ok", record["store_path"]))
            except Exception as exc:
                self.state.set_checkpoint(record, "failed", tries, sanitized_error(exc))
                q.put(("failed", f"{record['store_path']} {sanitized_error(exc)}"))

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, int(self.args.workers))) as pool:
            futures = [pool.submit(work, r) for r in records]
            done = 0
            while done < len(futures):
                kind, msg = q.get()
                done += 1
                if kind == "failed":
                    failures += 1
                print(json.dumps({"done": done, "total": len(futures), "status": kind, "path": msg}, sort_keys=True), flush=True)
            for fut in futures:
                fut.result()
        return failures

    def migrate_record(self, record: dict[str, Any]) -> None:
        cp = self.state.get_checkpoint(record)
        if cp.get("status") == "verified" and cp.get("metadata_fingerprint") == metadata_fingerprint(record):
            if self.verify_record(record, force_payload=False):
                return
        nar_path = self.ensure_raw_nar(record)
        actual_hash, actual_size = sha256_file(nar_path)
        if actual_hash != nar_hash_hex(record["nar_hash"]) or actual_size != int(record["nar_size"]):
            raise RepackError("raw NAR spool hash/size mismatch")
        self.new_client.upload(record, nar_path)
        if not self.verify_record(record, force_payload=True):
            raise RepackError("new narinfo missing after upload")

    def verify_record(self, record: dict[str, Any], force_payload: bool) -> bool:
        narinfo = self.new_client.get_narinfo(record["store_path_hash"])
        if narinfo is None:
            return False
        old_narinfo = self.old_client.get_narinfo(record["store_path_hash"])
        if old_narinfo is None:
            raise RepackError("old narinfo missing")
        db_guard_fields = tuple(f for f in IMMUTABLE_FIELDS if f != "Sig")
        db_diffs = compare_narinfo(expected_narinfo(record), old_narinfo, db_guard_fields)
        if db_diffs:
            raise RepackError("old narinfo differs from DB snapshot: " + ",".join(db_diffs))
        diffs = compare_narinfo(old_narinfo, narinfo)
        if diffs:
            raise RepackError("new narinfo immutable metadata mismatch: " + ",".join(diffs))
        if force_payload:
            self.new_client.verify_payload(narinfo, nar_hash_hex(record["nar_hash"]), int(record["nar_size"]), self.new_client.narinfo_url(record["store_path_hash"]))
        return True

    def ensure_raw_nar(self, record: dict[str, Any]) -> pathlib.Path:
        h = nar_hash_hex(record["nar_hash"])
        path = self.state.raw_path(h)
        with self.locks.hold(h):
            if path.exists():
                actual_hash, actual_size = sha256_file(path)
                if actual_hash == h and actual_size == int(record["nar_size"]):
                    return path
                raise RepackError("existing raw NAR spool hash/size mismatch")
            store_path = pathlib.Path(record["store_path"])
            if store_path.exists():
                try:
                    self.dump_local_store_path(record, path)
                    return path
                except (RepackError, subprocess.CalledProcessError, OSError):
                    path.with_suffix(".tmp").unlink(missing_ok=True)
                    eprint(json.dumps({"local_source_rejected": record["store_path"], "recovery": "old S3 chunks"}))
            self.s3.assemble(record, path)
            return path

    def dump_local_store_path(self, record: dict[str, Any], out_path: pathlib.Path) -> None:
        tmp = out_path.with_suffix(".tmp")
        env = {k: v for k, v in os.environ.items() if k != TOKEN_ENV}
        env.pop("NIX_CONFIG", None)
        cmd = [self.args.nix, "nar", "pack", record["store_path"]]
        with private_umask(), tmp.open("wb") as handle:
            subprocess.run(cmd, check=True, stdout=handle, stderr=subprocess.PIPE, env=env)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        actual_hash, actual_size = sha256_file(tmp)
        if actual_hash != nar_hash_hex(record["nar_hash"]) or actual_size != int(record["nar_size"]):
            tmp.unlink(missing_ok=True)
            raise RepackError("nix dump-path NAR hash/size mismatch")
        os.replace(tmp, out_path)


def add_common(parser: argparse.ArgumentParser, inherit: bool = False) -> None:
    def add(*args: Any, **kwargs: Any) -> None:
        if inherit:
            kwargs["default"] = argparse.SUPPRESS
        parser.add_argument(*args, **kwargs)

    add("--old-db", default=DEFAULT_OLD_DB)
    add("--state-dir", default=DEFAULT_STATE_DIR)
    add("--old-url", default=DEFAULT_OLD_URL)
    add("--new-url", default=DEFAULT_NEW_URL)
    add("--host", default=DEFAULT_HOST)
    add("--cache", default=DEFAULT_CACHE)
    add("--atticadm")
    add("--server-config")
    add("--nix", default="nix")
    add("--old-storage-endpoint", default=DEFAULT_OLD_ENDPOINT)
    add("--old-bucket", default=DEFAULT_OLD_BUCKET)
    add("--old-region", default=DEFAULT_OLD_REGION)
    add("--workers", type=int, default=2)
    add("--limit", type=int)
    add("--paths-file")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Safe resumable Attic repack/migration helper")
    add_common(parser)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "inventory", "migrate", "verify", "status"):
        child = sub.add_parser(name)
        add_common(child, inherit=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        migrator = Migrator(args)
        if args.command == "init":
            migrator.init_cache()
        elif args.command == "inventory":
            migrator.inventory()
        elif args.command == "migrate":
            if migrator.migrate(False):
                return 1
        elif args.command == "verify":
            if migrator.migrate(True):
                return 1
        elif args.command == "status":
            migrator.status()
        else:
            raise RepackError("unknown command")
        return 0
    except Exception as exc:
        eprint(sanitized_error(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

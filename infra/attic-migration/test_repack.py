import argparse
import hashlib
import http.server
import io
import json
import os
import pathlib
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock

import repack


def sha(data):
    return hashlib.sha256(data).hexdigest()


class FakeResponse:
    def __init__(self, status_code=200, content=b"", json_data=None, raw=None, headers=None):
        self.status_code = status_code
        self.content = content
        self._json = json_data
        self.raw = raw or io.BytesIO(content)
        self.headers = headers or {}
        self.close_count = 0

    def json(self):
        return self._json

    def close(self):
        self.close_count += 1


class FakeSession:
    def __init__(self):
        self.calls = []
        self.routes = {}

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        key = (method, pathlib.PurePosixPath(url.split("?", 1)[0]).as_posix())
        response = self.routes.get(key) or self.routes.get((method, url))
        if callable(response):
            return response(method, url, kwargs)
        return response or FakeResponse(404)


class ThreadedHTTP:
    def __init__(self, handler):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()


class RepackTests(unittest.TestCase):
    def test_options_before_subcommand_are_preserved(self):
        parser = repack.build_parser()
        args = parser.parse_args(["--atticadm", "/safe/atticadm", "--server-config", "/safe/config", "--workers", "1", "init"])
        self.assertEqual(args.atticadm, "/safe/atticadm")
        self.assertEqual(args.server_config, "/safe/config")
        self.assertEqual(args.workers, 1)
        args = parser.parse_args(["--workers", "1", "migrate", "--workers", "2"])
        self.assertEqual(args.workers, 2)

    def test_inventory_reads_sqlite_reserved_references_column(self):
        with tempfile.TemporaryDirectory() as td:
            db = pathlib.Path(td) / "old.db"
            con = sqlite3.connect(db)
            con.executescript('''
                CREATE TABLE cache(id INTEGER, name TEXT, deleted_at TEXT);
                CREATE TABLE nar(id INTEGER, nar_hash TEXT, nar_size INTEGER, state TEXT);
                CREATE TABLE object(cache_id INTEGER, nar_id INTEGER,
                    store_path_hash TEXT, store_path TEXT, "references" TEXT,
                    system TEXT, deriver TEXT, sigs TEXT, ca TEXT);
                INSERT INTO cache VALUES(1, 'hectic', NULL);
            ''')
            con.execute("INSERT INTO nar VALUES(1, ?, 7, 'V')", ("sha256:" + "a" * 64,))
            con.execute("INSERT INTO object VALUES(1, 1, ?, ?, ?, NULL, NULL, ?, NULL)",
                        ("b" * 32, "/nix/store/" + "b" * 32 + "-test", '["dependency"]', '[]'))
            con.commit()
            con.close()
            rows = repack.InventoryDB(str(db), "hectic").records()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["references"], ["dependency"])

    def test_metadata_import_keypair_capital(self):
        with tempfile.TemporaryDirectory() as td:
            db = pathlib.Path(td) / "old.db"
            con = sqlite3.connect(db)
            con.executescript("""
            create table cache(id integer primary key,name text,keypair text,is_public integer,store_dir text,priority integer,upstream_cache_key_names text,retention_period integer,deleted_at text);
            insert into cache values(1,'hectic','priv',1,'/nix/store',30,'["up"]',3600,null);
            """)
            con.close()
            args = self.args(td, old_db=str(db))
            mig = repack.Migrator(args)
            old = mock.Mock()
            old.get_cache_config.return_value = {"public_key": "pub"}
            new = mock.Mock()
            new.get_cache_config.side_effect = [None, {"public_key": "pub"}]
            mig.old_client = old
            mig.new_client = new
            mig.init_cache()
            body = new.create_cache.call_args.args[0]
            self.assertEqual(body["keypair"], {"Keypair": "priv"})
            new.patch_retention.assert_called_with({"Period": 3600})

    def test_bad_hash_rejects_raw_spool(self):
        with tempfile.TemporaryDirectory() as td:
            args = self.args(td)
            mig = repack.Migrator(args)
            record = self.record(b"good")
            raw = mig.state.raw_path(repack.nar_hash_hex(record["nar_hash"]))
            raw.write_bytes(b"bad")
            with self.assertRaises(repack.RepackError):
                mig.ensure_raw_nar(record)

    def test_local_mismatch_recovers_original_from_old_s3(self):
        with tempfile.TemporaryDirectory() as td:
            original = b"original cached NAR"
            record = self.record(original)
            local = pathlib.Path(td) / "different-local-copy"
            local.write_bytes(b"different")
            record["store_path"] = str(local)
            mig = repack.Migrator(self.args(td))

            def recover(_record, path):
                path.write_bytes(original)

            with mock.patch.object(mig, "dump_local_store_path", side_effect=repack.RepackError("nix dump-path NAR hash/size mismatch")), \
                    mock.patch.object(mig.s3, "assemble", side_effect=recover) as assemble:
                result = mig.ensure_raw_nar(record)
            self.assertEqual(result.read_bytes(), original)
            assemble.assert_called_once()

    def test_no_compile_subprocess_commands(self):
        with tempfile.TemporaryDirectory() as td:
            args = self.args(td)
            mig = repack.Migrator(args)
            data = b"nar"
            record = self.record(data)
            store = pathlib.Path(record["store_path"])
            with mock.patch("subprocess.run") as run:
                def fake_run(cmd, check, stdout, stderr, env):
                    self.assertEqual(cmd[:3], ["nix", "nar", "pack"])
                    self.assertNotIn("build", cmd)
                    self.assertNotIn(repack.TOKEN_ENV, env)
                    stdout.write(data)
                    return mock.Mock()
                run.side_effect = fake_run
                path = mig.state.raw_path(repack.nar_hash_hex(record["nar_hash"]))
                mig.dump_local_store_path(record, path)
                self.assertEqual(path.read_bytes(), data)
                self.assertTrue(str(store).startswith("/nix/store/"))

    def test_resumable_checkpoint(self):
        with tempfile.TemporaryDirectory() as td:
            state = repack.State(pathlib.Path(td))
            record = self.record(b"abc")
            state.set_checkpoint(record, "verified", 2)
            cp = state.get_checkpoint(record)
            self.assertEqual(cp["status"], "verified")
            self.assertEqual(cp["tries"], 2)
            self.assertEqual(cp["metadata_fingerprint"], repack.metadata_fingerprint(record))

    def test_root_backend_upload_preamble(self):
        data = b"abc"
        record = self.record(data)
        with tempfile.TemporaryDirectory() as td:
            nar = pathlib.Path(td) / "x.nar"
            nar.write_bytes(data)
            client = repack.AtticClient("http://127.0.0.1:8082", "hectic", "cache.hectic-lab.com", repack.TokenProvider(None, None, "hectic"))
            assert client.token_provider is not None
            client.token_provider._token = "tok"
            client.token_provider._expires = repack.now() + 3600
            sess = FakeSession()
            client._local.session = sess
            def put(method, url, kwargs):
                self.assertTrue(url.endswith("/_api/v1/upload-path"))
                self.assertIn("X-Attic-Nar-Info-Preamble-Size", kwargs["headers"])
                self.assertEqual(len(kwargs["data"]), int(kwargs["headers"]["Content-Length"]))
                body = kwargs["data"].read()
                pre = int(kwargs["headers"]["X-Attic-Nar-Info-Preamble-Size"])
                meta = json.loads(body[:pre])
                self.assertEqual(meta["store_path"], record["store_path"])
                self.assertEqual(body[pre:], data)
                return FakeResponse(200)
            sess.routes[("PUT", "http://127.0.0.1:8082/_api/v1/upload-path")] = put
            client.upload(record, nar)

    def test_real_http_upload_has_content_length_no_chunked(self):
        try:
            repack.requests_module()
        except ModuleNotFoundError:
            self.skipTest("requests not installed outside Nix test env")
        data = b"nar-bytes"
        record = self.record(data)
        seen = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_PUT(self):
                seen["path"] = self.path
                seen["host"] = self.headers.get("Host")
                seen["te"] = self.headers.get("Transfer-Encoding")
                length = int(self.headers["Content-Length"])
                body = self.rfile.read(length)
                pre = int(self.headers["X-Attic-Nar-Info-Preamble-Size"])
                seen["meta"] = json.loads(body[:pre])
                seen["nar"] = body[pre:]
                self.send_response(200); self.end_headers()

            def log_message(self, format, *args):
                pass

        with tempfile.TemporaryDirectory() as td, ThreadedHTTP(Handler) as srv:
            nar = pathlib.Path(td) / "x.nar"
            nar.write_bytes(data)
            tp = repack.TokenProvider(None, None, "hectic")
            tp._token = "tok"; tp._expires = repack.now() + 3600
            repack.AtticClient(srv.url, "hectic", "cache.hectic-lab.com", tp).upload(record, nar)
        self.assertEqual(seen["path"], "/_api/v1/upload-path")
        self.assertEqual(seen["host"], "cache.hectic-lab.com")
        self.assertIsNone(seen["te"])
        self.assertEqual(seen["meta"]["store_path"], record["store_path"])
        self.assertEqual(seen["nar"], data)

    def test_payload_relative_url_and_redirect_strips_host(self):
        try:
            repack.requests_module()
        except ModuleNotFoundError:
            self.skipTest("requests not installed outside Nix test env")
        data = b"nar"
        seen = {}

        class S3Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen["s3_path"] = self.path
                seen["s3_host"] = self.headers.get("Host")
                seen["s3_auth"] = self.headers.get("Authorization")
                self.send_response(200); self.end_headers(); self.wfile.write(data)
            def log_message(self, format, *args):
                pass

        with ThreadedHTTP(S3Handler) as s3:
            class CacheHandler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    seen["cache_path"] = self.path
                    seen["cache_host"] = self.headers.get("Host")
                    seen["cache_auth"] = self.headers.get("Authorization")
                    self.send_response(302)
                    self.send_header("Location", s3.url + "/object")
                    self.end_headers()
                def log_message(self, format, *args):
                    pass

            with ThreadedHTTP(CacheHandler) as cache:
                client = repack.AtticClient(cache.url, "hectic", "cache.hectic-lab.com", None)
                client.verify_payload({"URL":"nar/x","Compression":"none"}, sha(data), len(data), cache.url + "/hectic/abcd.narinfo")
        self.assertEqual(seen["cache_path"], "/hectic/nar/x")
        self.assertEqual(seen["cache_host"], "cache.hectic-lab.com")
        self.assertIsNone(seen["cache_auth"])
        self.assertEqual(seen["s3_path"], "/object")
        self.assertNotEqual(seen["s3_host"], "cache.hectic-lab.com")
        self.assertIsNone(seen["s3_auth"])

    def test_payload_retry_truncated_then_full_resets_hash(self):
        data = b"complete NAR bytes"
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession(); client._local.session = sess
        responses = [FakeResponse(200, content=data[:4]), FakeResponse(200, content=data)]

        def get(_method, _url, _kwargs):
            return responses.pop(0)

        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x")] = get
        with mock.patch("time.sleep") as sleep:
            receipt = client.verify_payload({"URL": "nar/x", "Compression": "none"}, sha(data), len(data), "http://127.0.0.1:8082/hectic/abcd.narinfo", "/nix/store/abcd-name")
        self.assertEqual(receipt, {"attempts": 2, "sha256": sha(data), "bytes": len(data)})
        self.assertEqual(len(sess.calls), 2)
        self.assertEqual(sleep.call_count, 1)

    def test_payload_persistent_timeouts_fail_after_three(self):
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession(); client._local.session = sess

        def timeout(_method, _url, _kwargs):
            raise TimeoutError()

        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x")] = timeout
        with mock.patch("time.sleep") as sleep, self.assertRaises(TimeoutError):
            client.verify_payload({"URL": "nar/x", "Compression": "none"}, sha(b"x"), 1, "http://127.0.0.1:8082/hectic/abcd.narinfo")
        self.assertEqual(len(sess.calls), 3)
        self.assertEqual(sleep.call_count, 2)

    def test_payload_full_size_wrong_hash_fails_after_one(self):
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession(); client._local.session = sess
        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x")] = FakeResponse(200, content=b"bad")
        with self.assertRaises(repack.PayloadIntegrityError):
            client.verify_payload({"URL": "nar/x", "Compression": "none"}, sha(b"nar"), 3, "http://127.0.0.1:8082/hectic/abcd.narinfo")
        self.assertEqual(len(sess.calls), 1)

    def test_payload_oversize_fails_after_one(self):
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession(); client._local.session = sess
        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x")] = FakeResponse(200, content=b"toolong")
        with self.assertRaises(repack.PayloadIntegrityError):
            client.verify_payload({"URL": "nar/x", "Compression": "none"}, sha(b"too"), 3, "http://127.0.0.1:8082/hectic/abcd.narinfo")
        self.assertEqual(len(sess.calls), 1)

    def test_payload_http_403_no_retry_and_closes(self):
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession(); client._local.session = sess
        resp = FakeResponse(403)
        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x")] = resp
        with self.assertRaises(repack.RepackError):
            client.verify_payload({"URL": "nar/x", "Compression": "none"}, sha(b"x"), 1, "http://127.0.0.1:8082/hectic/abcd.narinfo")
        self.assertEqual(len(sess.calls), 1)
        self.assertEqual(resp.close_count, 1)

    def test_auth_api_redirect_refused(self):
        tp = repack.TokenProvider(None, None, "hectic")
        tp._token = "tok"; tp._expires = repack.now() + 3600
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, tp)
        sess = FakeSession(); client._local.session = sess
        sess.routes[("GET", "http://127.0.0.1:8082/_api/v1/cache-config/hectic")] = FakeResponse(302, headers={"Location":"http://evil/"})
        with self.assertRaises(repack.RepackError):
            client.get_cache_config()

    def test_concatenated_zstd_correct(self):
        try:
            zstd = repack.zstd_module()
        except ModuleNotFoundError:
            self.skipTest("zstandard not installed outside Nix test env")
        plain = b"a" * 100 + b"b" * 100
        cctx = zstd.ZstdCompressor()
        payload = cctx.compress(plain[:100]) + cctx.compress(plain[100:])
        narinfo = {"URL": "nar/x.nar.zst", "Compression": "zstd"}
        client = repack.AtticClient("http://127.0.0.1:8082", "hectic", None, None)
        sess = FakeSession()
        client._local.session = sess
        sess.routes[("GET", "http://127.0.0.1:8082/hectic/nar/x.nar.zst")] = FakeResponse(200, raw=io.BytesIO(payload))
        client.verify_payload(narinfo, sha(plain), len(plain), "http://127.0.0.1:8082/hectic/abcd.narinfo")

    def test_perchunk_retry_cache(self):
        try:
            zstd = repack.zstd_module()
        except ModuleNotFoundError:
            self.skipTest("zstandard not installed outside Nix test env")
        with tempfile.TemporaryDirectory() as td:
            db = pathlib.Path(td) / "old.db"
            plain = b"chunk"
            comp = zstd.ZstdCompressor().compress(plain)
            con = sqlite3.connect(db)
            con.executescript("""
            create table chunkref(nar_id integer,seq integer,chunk_id integer);
            create table chunk(id integer primary key,state text,chunk_hash text,chunk_size integer,file_hash text,file_size integer,compression text,remote_file text);
            """)
            con.execute("insert into chunkref values(1,0,1)")
            con.execute("insert into chunk values(1,'V',?,?,?,?,?,?)", (sha(plain), len(plain), sha(comp), len(comp), "zstd", json.dumps({"S3":{"region":"hel1","bucket":"cache-hectic-lab","key":"k"}})))
            con.commit(); con.close()
            state = repack.State(pathlib.Path(td) / "state")
            asm = repack.OldS3Assembler(repack.InventoryDB(str(db), "hectic"), state, "https://example", "cache-hectic-lab", "hel1")
            fake_client = mock.Mock()
            fake_client.get_object.side_effect = [Exception("once"), {"Body": io.BytesIO(comp)}]
            out = pathlib.Path(td) / "out.nar"
            with mock.patch.object(asm, "client", return_value=fake_client):
                asm.assemble({"nar_id": 1, "nar_hash": "sha256:" + sha(plain), "nar_size": len(plain)}, out)
            self.assertEqual(out.read_bytes(), plain)
            self.assertEqual(fake_client.get_object.call_count, 2)
            fake_client.get_object.reset_mock()
            self.assertEqual(asm._compressed_chunk(asm.db.chunk_rows(1)[0]), comp)
            fake_client.get_object.assert_not_called()

    def test_chunk_prefetch_is_bounded_and_preserves_order(self):
        with tempfile.TemporaryDirectory() as td:
            pieces = [f"chunk-{i}\n".encode() for i in range(12)]
            rows = [{"seq": i, "compression": "none", "chunk_hash": sha(data), "chunk_size": len(data)}
                    for i, data in enumerate(pieces)]
            db = mock.Mock()
            db.chunk_rows.return_value = rows
            asm = repack.OldS3Assembler(db, repack.State(pathlib.Path(td) / "state"), "https://example", "cache-hectic-lab", "hel1")
            lock = threading.Lock()
            active = 0
            peak = 0

            def fetch(row):
                nonlocal active, peak
                with lock:
                    active += 1
                    peak = max(peak, active)
                time.sleep(0.04 if row["seq"] == 0 else 0.01)
                with lock:
                    active -= 1
                return pieces[row["seq"]]

            whole = b"".join(pieces)
            out = pathlib.Path(td) / "result.nar"
            with mock.patch.object(asm, "_compressed_chunk", side_effect=fetch):
                asm.assemble({"nar_id": 1, "nar_hash": "sha256:" + sha(whole), "nar_size": len(whole)}, out)
            self.assertEqual(out.read_bytes(), whole)
            self.assertGreater(peak, 1)
            self.assertLessEqual(peak, 4)

    def test_zstd_chunk_no_content_size_concat(self):
        try:
            zstd = repack.zstd_module()
        except ModuleNotFoundError:
            self.skipTest("zstandard not installed outside Nix test env")
        cctx = zstd.ZstdCompressor(write_content_size=False)
        payload = cctx.compress(b"aa") + cctx.compress(b"bb")
        self.assertEqual(repack.decompress_chunk(payload, "zstd"), b"aabb")

    def test_mismatch_new_key_fails(self):
        with tempfile.TemporaryDirectory() as td:
            db = pathlib.Path(td) / "old.db"
            con = sqlite3.connect(db)
            con.executescript("""
            create table cache(id integer primary key,name text,keypair text,is_public integer,store_dir text,priority integer,upstream_cache_key_names text,retention_period text,deleted_at text);
            insert into cache values(1,'hectic','priv',1,'/nix/store',30,'[]',null,null);
            """)
            con.close()
            mig = repack.Migrator(self.args(td, old_db=str(db)))
            mig.old_client = mock.Mock(); mig.old_client.get_cache_config.return_value = {"public_key":"old"}
            mig.new_client = mock.Mock(); mig.new_client.get_cache_config.return_value = {"public_key":"new","is_public":True,"store_dir":"/nix/store","priority":30,"upstream_cache_key_names":[]}
            with self.assertRaises(repack.RepackError):
                mig.init_cache()

    def test_init_requires_old_public_key(self):
        with tempfile.TemporaryDirectory() as td:
            db = pathlib.Path(td) / "old.db"
            con = sqlite3.connect(db)
            con.executescript("""
            create table cache(id integer primary key,name text,keypair text,is_public integer,store_dir text,priority integer,upstream_cache_key_names text,retention_period text,deleted_at text);
            insert into cache values(1,'hectic','priv',1,'/nix/store',30,'[]',null,null);
            """)
            con.close()
            mig = repack.Migrator(self.args(td, old_db=str(db)))
            mig.old_client = mock.Mock(); mig.old_client.get_cache_config.return_value = {}
            mig.new_client = mock.Mock(); mig.new_client.get_cache_config.return_value = None
            with self.assertRaises(repack.RepackError):
                mig.init_cache()

    def test_verify_readonly_no_put(self):
        with tempfile.TemporaryDirectory() as td:
            mig = repack.Migrator(self.args(td))
            record = self.record(b"abc")
            mig.selected_records = lambda: [record]
            mig.new_client = mock.Mock()
            mig.new_client.get_narinfo.return_value = {**repack.expected_narinfo(record), "URL": "nar/x", "Compression": "none"}
            mig.new_client.verify_payload.return_value = {"attempts": 1, "sha256": sha(b"abc"), "bytes": 3}
            mig.new_client.narinfo_url.return_value = "http://127.0.0.1:8082/hectic/abcd.narinfo"
            mig.old_client = mock.Mock()
            mig.old_client.get_narinfo.return_value = {**repack.expected_narinfo(record)}
            mig.migrate(True)
            mig.new_client.upload.assert_not_called()
            mig.new_client.verify_payload.assert_called_once()

    def test_payload_receipt_only_for_forced_successful_full_read(self):
        with tempfile.TemporaryDirectory() as td:
            mig = repack.Migrator(self.args(td))
            record = self.record(b"abc")
            mig.selected_records = lambda: [record]
            narinfo = {**repack.expected_narinfo(record), "URL": "nar/x", "Compression": "none"}
            old_info = {**repack.expected_narinfo(record)}
            mig.old_client = mock.Mock(); mig.old_client.get_narinfo.return_value = old_info
            mig.new_client = mock.Mock(); mig.new_client.get_narinfo.return_value = narinfo; mig.new_client.narinfo_url.return_value = "http://127.0.0.1/hectic/abcd.narinfo"
            mig.new_client.verify_payload.return_value = {"attempts": 2, "sha256": sha(b"abc"), "bytes": 3}
            self.assertEqual(mig.migrate(True), 0)
            cp = mig.state.get_checkpoint(record)
            self.assertEqual(cp["payload_verify_attempts"], 2)
            self.assertEqual(cp["payload_sha256"], sha(b"abc"))
            self.assertEqual(cp["payload_bytes"], 3)
            self.assertTrue(cp["payload_verified_at"].endswith("Z"))
            first_verified_at = cp["payload_verified_at"]

            mig.new_client.verify_payload.reset_mock()
            self.assertEqual(mig.migrate(False), 0)
            cp = mig.state.get_checkpoint(record)
            self.assertEqual(cp["payload_verified_at"], first_verified_at)
            mig.new_client.verify_payload.assert_not_called()

            mig.new_client.get_narinfo.return_value = narinfo
            mig.new_client.verify_payload.side_effect = repack.PayloadIntegrityError("new NAR payload hash/size mismatch")
            self.assertEqual(mig.migrate(True), 1)
            cp = mig.state.get_checkpoint(record)
            self.assertEqual(cp["status"], "failed")
            self.assertNotIn("payload_verified_at", cp)
            self.assertNotIn("payload_sha256", cp)

    def test_key_redaction(self):
        secret = "eyJhbGciOiPRIVATEKEYX-Amz-Signature=abc"
        msg = repack.sanitized_error(RuntimeError("https://x/y?" + secret))
        self.assertEqual(msg, "RuntimeError")
        self.assertNotIn(secret, msg)

    def test_old_new_narinfo_sig_compare_allows_db_sigs_empty(self):
        with tempfile.TemporaryDirectory() as td:
            mig = repack.Migrator(self.args(td))
            record = self.record(b"abc")
            record["sigs"] = []
            old_info = {**repack.expected_narinfo(record), "Sig": ["hectic:sig"]}
            new_info = dict(old_info)
            mig.old_client = mock.Mock(); mig.old_client.get_narinfo.return_value = old_info
            mig.new_client = mock.Mock(); mig.new_client.get_narinfo.return_value = new_info; mig.new_client.narinfo_url.return_value = "http://127.0.0.1/hectic/abcd.narinfo"
            mig.new_client.verify_payload.return_value = None
            self.assertTrue(mig.verify_record(record, False))

    def test_migrate_record_missing_narinfo_raises(self):
        with tempfile.TemporaryDirectory() as td:
            mig = repack.Migrator(self.args(td))
            record = self.record(b"abc")
            raw = mig.state.raw_path(repack.nar_hash_hex(record["nar_hash"]))
            raw.write_bytes(b"abc")
            mig.new_client = mock.Mock(); mig.new_client.get_narinfo.return_value = None
            with self.assertRaises(repack.RepackError):
                mig.migrate_record(record)

    def test_migrate_returns_failed_count(self):
        with tempfile.TemporaryDirectory() as td:
            mig = repack.Migrator(self.args(td))
            mig.selected_records = lambda: [self.record(b"abc")]
            mig.migrate_record = mock.Mock(side_effect=repack.RepackError("new narinfo missing"))
            self.assertEqual(mig.migrate(False), 1)

    def test_readonly_old_db_rejects_rw_and_missing(self):
        with self.assertRaises(repack.RepackError):
            repack.InventoryDB("file:/tmp/x.db?mode=rwc", "hectic")
        with self.assertRaises(repack.RepackError):
            repack.InventoryDB("/tmp/definitely-missing-attic.db", "hectic")

    def test_verify_hash_size_fail_closed_unknown_hash(self):
        with self.assertRaises(repack.RepackError):
            repack.verify_hash_size(b"x", "sha1:abc", 1, "chunk")

    def args(self, td, old_db=":memory:"):
        return argparse.Namespace(old_db=old_db, state_dir=str(pathlib.Path(td) / "state"), old_url="http://127.0.0.1:8081", new_url="http://127.0.0.1:8082", host="cache.hectic-lab.com", cache="hectic", atticadm=None, server_config=None, nix="nix", old_storage_endpoint="https://hel1.your-objectstorage.com", old_bucket="cache-hectic-lab", old_region="hel1", workers=2, limit=None, paths_file=None)

    def record(self, data):
        h = sha(data)
        return {"cache":"hectic","nar_id":1,"store_path_hash":"abcd","store_path":"/nix/store/abcd-name","references":["/nix/store/ref-ref"],"system":"x86_64-linux","deriver":None,"sigs":["cache:sig"],"ca":None,"nar_hash":"sha256:" + h,"nar_size":len(data)}


if __name__ == "__main__":
    unittest.main()

import concurrent.futures
import http.client
import http.server
import json
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROXY = ROOT / "sbproxy"
UPSTREAM_PORT = 19443
PROXY_PORT = 18765
BINARY = bytes(range(256)) * 8


class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disconnect_seen = threading.Event()

    def log_message(self, *_):
        pass

    def _echo(self):
        body = json.dumps({"path": self.path, "headers": dict(self.headers.items())}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Upstream", "yes")
        self.send_header("Connection", "X-Remove")
        self.send_header("X-Remove", "secret")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self._route()

    def do_GET(self):
        self._route()

    def _route(self):
        if self.path.startswith("/echo"):
            return self._echo()
        if self.path == "/binary":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(BINARY)))
            self.end_headers()
            if self.command != "HEAD": self.wfile.write(BINARY)
            return
        if self.path == "/redirect1":
            self.send_response(302); self.send_header("Location", "/redirect2"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/redirect2":
            self.send_response(301); self.send_header("Location", "/binary"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/range":
            requested = self.headers.get("Range")
            if requested == "bytes=1000-":
                body = BINARY[1000:]
                self.send_response(206)
                self.send_header("Content-Range", f"bytes 1000-{len(BINARY)-1}/{len(BINARY)}")
                self.send_header("Accept-Ranges", "bytes")
            elif requested:
                body = b""
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(BINARY)}")
            else:
                body = BINARY
                self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD": self.wfile.write(body)
            return
        if self.path == "/chunked":
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            for chunk in (b"abc", b"defgh"):
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); return
        if self.path == "/icy":
            body = self.headers.get("Icy-MetaData", "missing").encode()
            self.send_response(200)
            for key, value in (("icy-name","Fixture"),("icy-genre","Test"),("icy-url","https://localhost/"),("icy-br","128"),("icy-metaint","16000")):
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/slow"):
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Connection", "close"); self.end_headers()
            try:
                for _ in range(400): self.wfile.write(b"x" * 4096); self.wfile.flush(); time.sleep(.005)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                self.disconnect_seen.set()
            return
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()


class ProxyIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.cert = pathlib.Path(cls.temp.name) / "cert.pem"
        cls.key = pathlib.Path(cls.temp.name) / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", str(cls.key), "-out", str(cls.cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", UPSTREAM_PORT), Fixture)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cls.cert, cls.key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True); cls.server_thread.start()
        cls.log = open(pathlib.Path(cls.temp.name) / "proxy.log", "wb")
        cls.proxy = subprocess.Popen([str(PROXY), "--listen", f"127.0.0.1:{PROXY_PORT}", "--ca-bundle", str(cls.cert)], stdout=cls.log, stderr=cls.log)
        for _ in range(50):
            try:
                c = http.client.HTTPConnection("127.0.0.1", PROXY_PORT, timeout=.2); c.request("GET", "/health"); c.getresponse().read(); c.close(); break
            except OSError: time.sleep(.05)
        else: raise RuntimeError("sbproxy did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proxy.terminate(); cls.proxy.wait(timeout=5); cls.log.close(); cls.server.shutdown(); cls.server.server_close(); cls.temp.cleanup()

    def request(self, path, method="GET", headers=None):
        c = http.client.HTTPConnection("127.0.0.1", PROXY_PORT, timeout=10)
        c.request(method, f"/https/localhost:{UPSTREAM_PORT}{path}", headers=headers or {})
        r = c.getresponse(); body = r.read(); result = (r.status, {k.lower():v for k,v in r.getheaders()}, body); c.close(); return result

    def test_health_and_loaded_library(self):
        c=http.client.HTTPConnection("127.0.0.1",PROXY_PORT);c.request("GET","/health");r=c.getresponse();body=r.read().decode();c.close()
        self.assertEqual(r.status,200); self.assertIn("libcurl:",body); self.assertIn("TLS:",body)

    def test_non_loopback_listener_is_rejected(self):
        result=subprocess.run([str(PROXY),"--listen","0.0.0.0:19999"],capture_output=True,text=True)
        self.assertEqual(result.returncode,2);self.assertIn("only accepts",result.stderr)

    def test_get_binary_and_headers(self):
        status, headers, body = self.request("/binary")
        self.assertEqual((status, body), (200, BINARY)); self.assertEqual(headers["content-type"], "application/octet-stream"); self.assertEqual(int(headers["content-length"]), len(BINARY))

    def test_head(self):
        status, headers, body = self.request("/binary", "HEAD")
        self.assertEqual(status, 200); self.assertEqual(body, b""); self.assertEqual(int(headers["content-length"]), len(BINARY))

    def test_url_and_request_headers(self):
        path="/echo/a%20b?token=a%2Fb%2Bc&x=1&x=2"
        status, headers, body=self.request(path,headers={"X-Test":"forwarded","Connection":"X-Hop","X-Hop":"remove","Icy-MetaData":"1","Host":"wrong.invalid"})
        data=json.loads(body); upstream={k.lower():v for k,v in data["headers"].items()}
        self.assertEqual(status,200);self.assertEqual(data["path"],path);self.assertEqual(upstream["x-test"],"forwarded");self.assertEqual(upstream["icy-metadata"],"1");self.assertNotIn("x-hop",upstream);self.assertEqual(upstream["host"],f"localhost:{UPSTREAM_PORT}")
        self.assertEqual(headers["x-upstream"],"yes");self.assertNotIn("x-remove",headers);self.assertNotIn("transfer-encoding",headers)

    def test_redirects_emit_only_final_response(self):
        status, headers, body=self.request("/redirect1");self.assertEqual(status,200);self.assertEqual(body,BINARY);self.assertNotIn("location",headers)

    def test_range_206_and_416(self):
        status, headers, body=self.request("/range",headers={"Range":"bytes=1000-"});self.assertEqual(status,206);self.assertEqual(body,BINARY[1000:]);self.assertEqual(headers["content-range"],f"bytes 1000-{len(BINARY)-1}/{len(BINARY)}")
        status, headers, body=self.request("/range",headers={"Range":"bytes=99999-"});self.assertEqual(status,416);self.assertEqual(headers["content-range"],f"bytes */{len(BINARY)}")

    def test_404(self): self.assertEqual(self.request("/missing")[0],404)

    def test_chunked_is_dechunked(self):
        status,headers,body=self.request("/chunked");self.assertEqual((status,body),(200,b"abcdefgh"));self.assertNotIn("transfer-encoding",headers)

    def test_icy(self):
        status,headers,body=self.request("/icy",headers={"Icy-MetaData":"1"});self.assertEqual((status,body),(200,b"1"))
        for name in ("icy-name","icy-genre","icy-url","icy-br","icy-metaint"): self.assertIn(name,headers)

    def test_untrusted_certificate_rejected(self):
        p=subprocess.Popen([str(PROXY),"--listen","127.0.0.1:18766"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            time.sleep(.15);c=http.client.HTTPConnection("127.0.0.1",18766,timeout=5);c.request("GET",f"/https/localhost:{UPSTREAM_PORT}/binary");r=c.getresponse();r.read();self.assertEqual(r.status,502);c.close()
        finally: p.terminate();p.wait(timeout=5)

    def test_client_disconnect_releases_worker(self):
        Fixture.disconnect_seen.clear();s=socket.create_connection(("127.0.0.1",PROXY_PORT));s.sendall(f"GET /https/localhost:{UPSTREAM_PORT}/slow HTTP/1.1\r\nHost: localhost\r\n\r\n".encode());s.recv(1024);s.close()
        self.assertTrue(Fixture.disconnect_seen.wait(3));self.assertEqual(self.request("/binary")[0],200)

    def test_four_concurrent_streams(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda _: self.request("/slow"),range(4)))
        self.assertTrue(all(status==200 and len(body)==400*4096 for status,_,body in results))

    def test_worker_limit_and_bounded_rss(self):
        def rss_kib():
            for line in pathlib.Path(f"/proc/{self.proxy.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"): return int(line.split()[1])
            return 0
        baseline=rss_kib(); sockets=[]
        try:
            for _ in range(8):
                s=socket.create_connection(("127.0.0.1",PROXY_PORT));s.sendall(f"GET /https/localhost:{UPSTREAM_PORT}/slow HTTP/1.1\r\nHost: localhost\r\n\r\n".encode());s.recv(256);sockets.append(s)
            time.sleep(.15)
            extra=socket.create_connection(("127.0.0.1",PROXY_PORT));extra.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n");response=extra.recv(256);extra.close()
            self.assertIn(b" 503 ",response)
            delta=rss_kib()-baseline
            print(f"eight-stream RSS delta: {delta} KiB")
            self.assertLess(delta,20*1024)
        finally:
            for s in sockets: s.close()
        time.sleep(.2);self.assertEqual(self.request("/binary")[0],200)


if __name__ == "__main__": unittest.main(verbosity=2)

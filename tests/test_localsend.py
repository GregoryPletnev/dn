"""LocalSend: the receive helper over HTTP, and device discovery over UDP
multicast against a fake peer (DN_LS_DISC_PORT keeps it off the real
LocalSend port)."""

import http.server
import json
import os
import hashlib
import select
import socket
import ssl
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request

import pytest

from conftest import ROOT, make_session

DN = os.path.join(ROOT, 'bin', 'dn')
GROUP = '224.0.0.167'
API = '/api/localsend/v2'


def free_port(kind=socket.SOCK_STREAM):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(('', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def http_json(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status, r.read()


# --- the receive helper ---------------------------------------------------

@pytest.fixture
def helper(tmp_path):
    home = tmp_path / 'home'
    home.mkdir()
    port = free_port()
    env = dict(os.environ, HOME=str(home))
    proc = subprocess.Popen([DN, '--localsend-server', str(port), 'DNTest'],
                            stdout=subprocess.PIPE, env=env)
    r, _, _ = select.select([proc.stdout], [], [], 5)
    if not r:
        proc.kill()
        raise AssertionError('the helper never reported ready')
    line = proc.stdout.readline()
    assert b'"ok"' in line, line
    yield proc, port, home
    proc.kill()
    proc.wait()


def read_event(proc, kind, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([proc.stdout], [], [], 0.2)
        if r:
            ev = json.loads(proc.stdout.readline())
            if ev.get('kind') == kind:
                return ev
    raise AssertionError('no %s event' % kind)


def test_helper_saves_upload_under_its_name(helper):
    proc, port, home = helper
    base = 'http://127.0.0.1:%d%s' % (port, API)
    data = b'hello localsend\n'
    status, body = http_json('POST', base + '/prepare-upload', {
        'info': {'alias': 'Phone', 'version': '2.1', 'deviceType': 'mobile',
                 'fingerprint': 'p1', 'port': 53317, 'protocol': 'http'},
        'files': {'f1': {'id': 'f1', 'fileName': 'photo.jpg',
                         'size': len(data), 'fileType': 'image/jpeg'}}})
    assert status == 200
    resp = json.loads(body)
    token = resp['files']['f1']
    assert isinstance(token, str) and token     # protocol v2: a token string
    sid = resp['sessionId']

    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(urllib.request.Request(
            '%s/upload?sessionId=%s&fileId=f1&token=wrong' % (base, sid),
            data=data, method='POST'), timeout=5)
    assert e.value.code == 403

    req = urllib.request.Request(
        '%s/upload?sessionId=%s&fileId=f1&token=%s' % (base, sid, token),
        data=data, method='POST')
    with urllib.request.urlopen(req, timeout=5) as r:
        assert r.status == 200
    assert (home / 'photo.jpg').read_bytes() == data


def test_helper_register_reports_peer(helper):
    proc, port, _ = helper
    status, body = http_json(
        'POST', 'http://127.0.0.1:%d%s/register' % (port, API),
        {'alias': 'MBP1', 'version': '2.1', 'deviceModel': 'macOS',
         'deviceType': 'desktop', 'fingerprint': 'mbp1', 'port': 53317,
         'protocol': 'http'})
    assert status == 200
    me = json.loads(body)
    # the helper never creates the certificate: without one it falls back
    # to a 32-digit id, with one (made by dn) it is the 64-digit SHA-256
    assert me['alias'] == 'DNTest' and len(me['fingerprint']) in (32, 64)
    ev = read_event(proc, 'peer')
    assert ev['peerAddr'] == '127.0.0.1'
    assert json.loads(ev['peerInfo'])['alias'] == 'MBP1'


# --- discovery against a fake peer ----------------------------------------

class FakePeer:
    """A LocalSend device: answers announces over multicast and takes
    uploads over plain HTTP."""

    def __init__(self, disc_port, alias='FakePhone', answer='udp',
                 tls_dir=None, fingerprint=None, client_ca=None):
        """answer: 'udp' replies to announces by multicast, 'http' by
        POST /register to the announced port (what LocalSend 2.2 does).
        tls_dir: serve HTTPS with a fresh self-signed certificate."""
        self.disc_port = disc_port
        self.alias = alias
        self.answer = answer
        self.protocol = 'http'
        self.fingerprint = 'fake-' + alias
        self.received = {}          # file name -> bytes
        self.tokens_ok = True
        self.announces = []         # DTOs seen with announce: true
        self.answers = []           # DTOs seen with announce: false
        self.registered = None      # answer='http': did POST /register work
        self.client_fp = None       # sha256 of the client certificate seen
        self.sender_fp = None       # fingerprint in prepare-upload info
        self.put_seen = False       # an upload with the wrong method
        peer = self
        names = {}

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                if self.path.startswith(API + '/upload'):
                    return self._upload()
                body = json.loads(self.rfile.read(
                    int(self.headers['Content-Length'])))
                if hasattr(self.connection, 'getpeercert'):
                    der = self.connection.getpeercert(binary_form=True)
                    if der:
                        peer.client_fp = hashlib.sha256(der).hexdigest().upper()
                peer.sender_fp = body.get('info', {}).get('fingerprint')
                files = {fid: 'tok-' + fid for fid in body['files']}
                for fid, meta in body['files'].items():
                    names[fid] = meta['fileName']
                self._reply({'sessionId': 's1', 'files': files})

            def do_PUT(self):
                # like LocalSend: there is no PUT route
                self.send_response(404)
                self.send_header('Content-Length', '0')
                self.end_headers()
                peer.put_seen = True

            def _upload(self):
                q = dict(p.split('=', 1)
                         for p in self.path.split('?', 1)[1].split('&'))
                if q.get('token') != 'tok-' + q['fileId']:
                    peer.tokens_ok = False
                n = int(self.headers.get('Content-Length', 0))
                peer.received[names[q['fileId']]] = self.rfile.read(n)
                self._reply({})

            def _reply(self, obj):
                data = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.http = http.server.HTTPServer(('0.0.0.0', 0), H)
        self.http_port = self.http.server_address[1]
        if tls_dir is not None:
            crt, key = tls_dir / 'peer.crt', tls_dir / 'peer.key'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048',
                            '-nodes', '-days', '1', '-subj', '/CN=LocalSend',
                            '-keyout', str(key), '-out', str(crt)],
                           check=True, capture_output=True)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(str(crt), str(key))
            if client_ca is not None:
                # LocalSend 2.2: mutual TLS, no client certificate = alert 116
                ctx.verify_mode = ssl.CERT_REQUIRED
                ctx.load_verify_locations(str(client_ca))
            self.http.socket = ctx.wrap_socket(self.http.socket,
                                               server_side=True)
            der = ssl.PEM_cert_to_DER_cert(crt.read_text())
            self.protocol = 'https'
            self.fingerprint = hashlib.sha256(der).hexdigest().upper()
        if fingerprint is not None:
            self.fingerprint = fingerprint      # a lying announce
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, 'SO_REUSEPORT'):
            self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        self.udp.bind(('', disc_port))
        self.udp.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                            struct.pack('4s4s', socket.inet_aton(GROUP),
                                        socket.inet_aton('0.0.0.0')))
        self.udp.settimeout(0.2)
        self.stop = False
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        threading.Thread(target=self._listen, daemon=True).start()

    def dto(self, announce):
        return {'alias': self.alias, 'version': '2.1',
                'deviceModel': 'Android', 'deviceType': 'mobile',
                'fingerprint': self.fingerprint, 'port': self.http_port,
                'protocol': self.protocol, 'download': False,
                'announce': announce}

    def send(self, announce):
        self.udp.sendto(json.dumps(self.dto(announce)).encode(),
                        (GROUP, self.disc_port))

    def _listen(self):
        while not self.stop:
            try:
                data, src = self.udp.recvfrom(9000)
            except (socket.timeout, OSError):
                continue
            msg = json.loads(data)
            if msg.get('fingerprint') == self.fingerprint:
                continue
            if msg.get('announce'):
                self.announces.append(msg)
                if self.answer == 'udp':
                    self.send(False)        # the multicast answer
                else:
                    self.register(src[0], msg)
            else:
                self.answers.append(msg)

    def register(self, ip, msg):
        """LocalSend 2.2's answer: POST our info to the announcer."""
        body = self.dto(False)
        del body['announce']
        try:
            http_json('POST', 'http://%s:%d%s/register'
                      % (ip, msg['port'], API), body)
            self.registered = True
        except OSError:
            self.registered = False

    def close(self):
        self.stop = True
        self.http.shutdown()
        self.udp.close()


@pytest.fixture
def disc_port():
    return free_port(socket.SOCK_DGRAM)


@pytest.fixture
def peer(disc_port):
    p = FakePeer(disc_port)
    # multicast loopback must work here, or the test means nothing
    p.send(False)
    time.sleep(0.3)
    yield p
    p.close()


def pick_and_send(sandbox, peer, expect):
    s = make_session(sandbox, env={'DN_LS_DISC_PORT': str(peer.disc_port)})
    try:
        s.wait_text('a.txt')
        s.click_on('a.txt')
        open_picker(s)
        s.wait_text(peer.alias, timeout=8)
        s.key('DOWN')
        s.key('ENTER')
        s.wait_text(expect, timeout=15)
    finally:
        s.close()


def test_picker_finds_peer_that_answers_by_register(sandbox, disc_port):
    # LocalSend 2.2 answers an announce only with POST /register
    peer = FakePeer(disc_port, alias='RegPhone', answer='http')
    try:
        pick_and_send(sandbox, peer, 'Sent 1 file(s).')
        assert peer.registered, 'dn did not take the /register answer'
        assert peer.received == {'a.txt': b'aaa\n'}
    finally:
        peer.close()


needs_tls = pytest.mark.skipif(
    subprocess.run(['which', 'curl'], capture_output=True).returncode or
    subprocess.run(['which', 'openssl'], capture_output=True).returncode,
    reason='curl and openssl are needed for the HTTPS path')


@needs_tls
def test_send_over_https_with_pinned_certificate(sandbox, disc_port, tmp_path):
    peer = FakePeer(disc_port, alias='TlsPhone', tls_dir=tmp_path)
    try:
        assert peer.protocol == 'https'
        pick_and_send(sandbox, peer, 'Sent 1 file(s).')
        assert peer.received == {'a.txt': b'aaa\n'}
        assert peer.tokens_ok
    finally:
        peer.close()


@needs_tls
def test_https_refuses_a_certificate_that_does_not_match(sandbox, disc_port,
                                                        tmp_path):
    peer = FakePeer(disc_port, alias='Liar', tls_dir=tmp_path,
                    fingerprint='00' * 32)
    try:
        pick_and_send(sandbox, peer, 'does not match its fingerprint')
        assert peer.received == {}
    finally:
        peer.close()


@needs_tls
def test_https_presents_client_certificate(sandbox, disc_port, tmp_path):
    # the identity exists before the peer starts, so the peer can trust it
    env = dict(os.environ, DN_CONFIG_DIR=str(sandbox / 'cfg'),
               DN_LS_DISC_PORT=str(disc_port))
    subprocess.run([DN, '--localsend-scan', '0'], env=env,
                   capture_output=True, timeout=30)
    cert = sandbox / 'cfg' / 'localsend' / 'cert.pem'
    assert cert.exists()
    peer = FakePeer(disc_port, alias='MtlsPhone', tls_dir=tmp_path,
                    client_ca=cert)
    try:
        pick_and_send(sandbox, peer, 'Sent 1 file(s).')
        assert peer.received == {'a.txt': b'aaa\n'}
        assert peer.client_fp, 'no client certificate presented'
        assert peer.sender_fp == peer.client_fp, \
            'announced fingerprint is not the client certificate hash'
    finally:
        peer.close()


def open_picker(s):
    s.wait_text('a.txt')
    s.click_on('Tools')
    s.wait_text('LocalSend')
    s.click_on('LocalSend')
    s.wait_text('send to')


def test_picker_lists_peer_and_sends(sandbox, peer):
    s = make_session(sandbox, env={'DN_LS_DISC_PORT': str(peer.disc_port)})
    try:
        s.wait_text('a.txt')
        s.click_on('a.txt')                 # the file to send
        open_picker(s)
        s.wait_text('Enter address manually')
        s.wait_text('FakePhone', timeout=8)
        assert s.row_of('HTTP') is not None
        assert peer.announces, 'dn sent no announce'
        # the SHA-256 of dn's certificate, as LocalSend devices announce
        assert len(peer.announces[0]['fingerprint']) == 64
        s.key('DOWN')                       # row 0 is the manual entry
        s.key('ENTER')
        s.wait_text('Sent 1 file(s).', timeout=10)
        assert peer.received == {'a.txt': b'aaa\n'}
        assert peer.tokens_ok, 'upload without the prepare-upload token'
    finally:
        s.close()


def test_receiving_dn_answers_announces(sandbox, peer):
    cfg = sandbox / 'cfg'
    cfg.mkdir()
    port = free_port()
    (cfg / 'options').write_text('localsend_port=%d\nlocalsend_name=DNRecv\n'
                                 % port)
    s = make_session(sandbox, env={'DN_LS_DISC_PORT': str(peer.disc_port),
                                   'HOME': str(sandbox / 'home')})
    try:
        s.wait_text('a.txt')
        # dn announces itself at startup; a peer's announce gets an answer
        deadline = time.time() + 5
        while time.time() < deadline and not peer.announces:
            time.sleep(0.1)
        assert any(a['alias'] == 'DNRecv' and a['port'] == port
                   for a in peer.announces), peer.announces
        peer.send(True)
        deadline = time.time() + 5
        while time.time() < deadline and not peer.answers:
            s.pump(0.2)
        assert any(a['alias'] == 'DNRecv' for a in peer.answers), \
            peer.answers
    finally:
        s.close()

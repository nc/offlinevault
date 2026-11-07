import hashlib
import os

import pytest

from ovpub import store
from tests.fake_worker import SECRET, Bucket, make_server


@pytest.fixture
def worker(monkeypatch):
    monkeypatch.setattr(store, "PART_SIZE", 1024)
    monkeypatch.setattr(store, "SINGLE_PUT_LIMIT", 2048)
    bucket = Bucket()
    server, origin = make_server(bucket, part_limit=4096)
    yield bucket, store.WorkerStore(origin, SECRET, retries=1, timeout=10)
    server.shutdown()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def test_worker_store_head_put_small_and_get(worker, tmp_path):
    bucket, st = worker
    assert st.head("zim/a.zim") is None
    p = tmp_path / "a.zim"
    p.write_bytes(b"hello")
    st.put_file("zim/a.zim", p, sha(b"hello"))
    info = st.head("zim/a.zim")
    assert info.size == 5 and info.sha256 == sha(b"hello")
    assert st.get("zim/a.zim") == b"hello" and st.get("zim/missing.zim") is None


def test_worker_store_multipart_assembles_parts_in_order(worker, tmp_path):
    bucket, st = worker
    data = os.urandom(1024 * 3 + 100)
    p = tmp_path / "big.zim"
    p.write_bytes(data)
    st.put_file("zim/big.zim", p, sha(data))
    assert bucket.objects["zim/big.zim"] == (data, sha(data))
    assert bucket.uploads == {}


def test_worker_store_streams_in_parts_and_declares_sha(worker):
    bucket, st = worker
    data = os.urandom(2500)
    sent = st.put_stream("zim/s.zim", (data[i:i + 700] for i in range(0, len(data), 700)), sha(data), len(data))
    assert bucket.objects["zim/s.zim"] == (data, sha(data))
    assert (sent.size, sent.sha256) == (len(data), sha(data))


def test_worker_store_streams_without_a_sha_and_returns_the_one_it_computed(worker):
    bucket, st = worker
    data = os.urandom(2500)
    sent = st.put_stream("maps/planet.pmtiles", (data[i:i + 700] for i in range(0, len(data), 700)), None, None)
    assert (sent.size, sent.sha256) == (len(data), sha(data))
    assert st.get("maps/planet.pmtiles") == data
    assert st.head("maps/planet.pmtiles").sha256 is None
    assert [o.sha256 for o in st.list("maps/")] == [None]
    with pytest.raises(store.ImmutableKeyError):
        st.put_stream("maps/planet.pmtiles", iter([data]), None, None)
    with pytest.raises(store.ImmutableKeyError):
        st.put_stream("maps/planet.pmtiles", iter([data]), sha(data), None)


def test_worker_store_aborts_multipart_on_failure(worker):
    bucket, st = worker
    chunks = iter([b"x" * 1500, RuntimeError("upstream died")])

    def gen():
        for c in chunks:
            if isinstance(c, Exception):
                raise c
            yield c

    with pytest.raises(RuntimeError):
        st.put_stream("zim/fail.zim", gen(), "0"*64, None)
    assert bucket.aborted and "zim/fail.zim" not in bucket.objects and bucket.uploads == {}


def test_worker_store_immutability_and_auth(worker, tmp_path):
    bucket, st = worker
    p = tmp_path / "a"
    p.write_bytes(b"one")
    st.put_file("zim/a.zim", p, sha(b"one"))
    p.write_bytes(b"two")
    with pytest.raises(store.ImmutableKeyError):
        st.put_file("zim/a.zim", p, sha(b"two"))
    st.put_file("manifest.json", p, sha(b"two"))
    st.put_file("manifest.json", tmp_path / "a", sha(b"two"))
    bad = store.WorkerStore(st.origin, "wrong", retries=1, timeout=10)
    with pytest.raises(store.StoreError, match="401"):
        bad.head("zim/a.zim")


def test_worker_store_list_follows_cursor_and_delete(worker, tmp_path):
    bucket, st = worker
    for i in range(5):
        p = tmp_path / f"{i}"
        p.write_bytes(bytes([i]))
        st.put_file(f"zim/{i}.zim", p, sha(bytes([i])))
    assert [o.key for o in st.list("zim/")] == [f"zim/{i}.zim" for i in range(5)]
    st.delete("zim/0.zim")
    assert st.head("zim/0.zim") is None


def test_fake_store_persists_pretends_and_records_declared_sha(tmp_path):
    st = store.FakeStore(root=tmp_path / "out", pretend={"zim/x.zim": store.ObjectInfo("zim/x.zim", 9, "f" * 64)})
    assert st.head("zim/x.zim").sha256 == "f" * 64 and st.get("zim/x.zim") is None
    st.put_stream("catalogue/c.json", iter([b"{}"]), sha(b"{}"), 2)
    assert (tmp_path / "out/catalogue/c.json").read_bytes() == b"{}"
    again = store.FakeStore(root=tmp_path / "out")
    assert again.head("catalogue/c.json").sha256 == sha(b"{}") and again.get("catalogue/c.json") == b"{}"
    st.put_stream("zim/y.zim", iter([b"abc"]), "0" * 64, 3)
    assert st.head("zim/y.zim").sha256 == "0" * 64
    sent = st.put_stream("maps/p.pmtiles", iter([b"pl", b"anet"]), None, None)
    assert (sent.size, sent.sha256) == (6, sha(b"planet")) and st.head("maps/p.pmtiles").sha256 is None
    with pytest.raises(store.ImmutableKeyError):
        st.put_stream("maps/p.pmtiles", iter([b"planet"]), sha(b"planet"), 6)
    with pytest.raises(store.ImmutableKeyError):
        st.put_stream("catalogue/c.json", iter([b"[]"]), sha(b"[]"), 2)
    st.put_stream("manifest.json", iter([b"1"]), sha(b"1"), 1)
    st.put_stream("manifest.json", iter([b"2"]), sha(b"2"), 1)


def test_printer_reads_through_and_only_narrates_writes(tmp_path):
    inner = store.FakeStore()
    inner.put_stream("zim/a.zim", iter([b"a"]), None, 1)
    lines = []
    p = store.Printer(inner, out=lines.append)
    assert p.head("zim/a.zim").size == 1
    f = tmp_path / "f"
    f.write_bytes(b"xyz")
    p.put_file("zim/b.zim", f, sha(b"xyz"))
    p.delete("zim/a.zim")
    assert inner.head("zim/a.zim") is not None and inner.head("zim/b.zim") is None
    assert lines == ["  would upload zim/b.zim (3 bytes)", "  would delete zim/a.zim"]


def test_small_known_size_stream_is_a_single_put_and_needs_a_sha(worker):
    import pytest
    from ovpub.store import StoreError, sha256_bytes
    bucket, st = worker
    data = b'{"version":"x"}'
    st.put_stream("manifests/manifest-x.json", iter([data]), sha256_bytes(data), len(data))
    info = st.head("manifests/manifest-x.json")
    assert info is not None and info.size == len(data) and info.sha256 == sha256_bytes(data)
    with pytest.raises(StoreError):
        st.put_stream("manifests/manifest-y.json", iter([data]), None, len(data))

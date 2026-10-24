"""Offline round-trip tests for rescue_publish (no network): generate a
throwaway nsec, build the kind-20267 event, verify it; tamper cases must
be rejected. The ws publish/fetch paths are device-gate territory."""
import os
import sys
import unittest

sys.path.insert(0, os.environ.get(
    "KLH_REPO", "/repo") + "/overlay/kali-config/common/includes.chroot/"
    "usr/local/lib/kali-live-headless")
import rescue_publish as R  # noqa: E402
import wg_enroll_lib as W  # noqa: E402
import host_role_init as H  # noqa: E402  (bech32 lives here)


def make_nsec():
    scalar = int.from_bytes(os.urandom(32), "big") or 1
    nsec = H.bech32_encode("nsec", H.convertbits(list(scalar.to_bytes(32, "big")), 8, 5))
    npub = H.bech32_encode("npub", H.convertbits(list(W.pubkey_xonly(scalar)), 8, 5))
    return scalar, nsec, npub


class TestRescuePublish(unittest.TestCase):
    def test_nsec_roundtrip(self):
        scalar, nsec, _ = make_nsec()
        self.assertEqual(R.nsec_to_int(nsec), scalar)

    def test_event_roundtrip(self):
        scalar, _, npub = make_nsec()
        ev = R.make_rescue_event(scalar, "https://abc.trycloudflare.com", now=1000)
        pub, url = R.verify_rescue_event(ev)
        self.assertEqual(url, "https://abc.trycloudflare.com")
        self.assertEqual(pub, W.npub_decode(npub).hex())

    def test_tampered_content_rejected(self):
        scalar, _, _ = make_nsec()
        ev = R.make_rescue_event(scalar, "https://abc.trycloudflare.com")
        ev["content"] = ev["content"].replace("abc", "evil")
        with self.assertRaises(ValueError):
            R.verify_rescue_event(ev)

    def test_wrong_key_rejected(self):
        a, _, _ = make_nsec()
        ev = R.make_rescue_event(a, "https://abc.trycloudflare.com")
        ev["pubkey"] = bytes(32).hex()  # claim a different author
        with self.assertRaises(ValueError):
            R.verify_rescue_event(ev)

    def test_non_rescue_content_rejected(self):
        scalar, _, _ = make_nsec()
        ev = R.make_rescue_event(scalar, "https://abc.trycloudflare.com")
        ev["content"] = "kali-wg-enroll v1 something"
        with self.assertRaises(ValueError):
            R.verify_rescue_event(ev)


if __name__ == "__main__":
    unittest.main()

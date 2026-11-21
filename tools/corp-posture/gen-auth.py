#!/usr/bin/env python3
"""gen-auth.py — build EFI_VARIABLE_AUTHENTICATION_2 .auth blobs for
db/KEK/PK enrollment (the format edk2's AuthService verifies, and the one
setup-mode firmware accepts unverified — both paths satisfied).

Per edk2 AuthService.c VerifyTimeBasedPayload:
  blob  = EFI_TIME(16B, pads zeroed) + WIN_CERT_UEFI_GUID{ dwLength,
           wRevision=0x0200, wCertType=0x0EF1, CertType=EFI_CERT_PKCS7,
           PKCS7 } + payload(EFI_SIGNATURE_LIST)
  signature (when verified) is over the RAW concatenation:
    VarName(UTF16LE, NO nul) + VendorGuid + Attrs(u32LE) + TimeStamp + payload

Payload EFI_SIGNATURE_LIST for X.509:
  EFI_CERT_X509_GUID + listsize(u32) + headersize=0(u32) + sigsize(u32)
  + owner GUID + cert DER.
Usage: gen-auth.py CA_DIR OUT_DIR   (writes db/KEK/PK .auth from the CA)
"""
import struct, subprocess, sys, uuid, datetime, os

ca, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

EFI_GLOBAL = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c")
EFI_SEC_DB = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f")
CERT_X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
CERT_PKCS7 = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")
OWNER = uuid.UUID("11111111-2222-3333-4444-123456789003")
ATTRS = 0x1 | 0x2 | 0x4 | 0x20  # NV | BS | RT | TIME_BASED_AUTH

def der(path):
    return open(path, "rb").read()

def guid_bytes(u):
    return u.bytes_le  # mixed-endian EFI GUID layout

def sig_list(cert_der):
    entry = guid_bytes(OWNER) + cert_der
    sigsize = len(entry)
    hdr = guid_bytes(CERT_X509) + struct.pack("<III", 0, 0, sigsize)
    # SignatureListSize filled after: header(16+12=28? struct is 16 GUID + 3*u32 = 28) + entry
    listsize = 28 + sigsize
    return guid_bytes(CERT_X509) + struct.pack("<III", listsize, 0, sigsize) + entry

def efi_time():
    n = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    # Year u16, Month..Pad1 6*u8, Nanosecond u32=0, TimeZone i16=0, Daylight u8=0, Pad2 u8=0
    # Year(H) Month Day Hour Min Sec Pad1 (6B) Nanosecond(I) Timezone(H) Daylight(B) Pad2(B)
    return struct.pack("<H6BIHBB", n.year, n.month, n.day, n.hour,
                       n.minute, n.second, 0, 0, 0, 0, 0)

def pkcs7_detached(signkey, signcert, content):
    import tempfile
    with tempfile.NamedTemporaryFile(dir=os.environ.get("TMPDIR", "."), delete=False) as f:
        f.write(content); cf = f.name
    p7 = subprocess.run(
        ["openssl", "smime", "-sign", "-binary", "-md", "sha256",
         "-signer", signcert, "-inkey", signkey, "-in", cf,
         "-outform", "DER"],
        capture_output=True, check=True).stdout
    os.unlink(cf)
    return p7

def make_auth(var, payload, signkey, signcert):
    tstamp = efi_time()
    name16 = var.encode("utf-16-le")
    vg = EFI_SEC_DB if var == "db" else EFI_GLOBAL
    to_be_signed = (name16 + guid_bytes(vg) + struct.pack("<I", ATTRS)
                    + tstamp + payload)
    p7 = pkcs7_detached(signkey, signcert, to_be_signed)
    # dwLength covers everything after the dwLength field itself
    # (revision+type+guid+pkcs7 = 2+2+16+len(p7))
    win = struct.pack("<IHH", 24 + len(p7), 0x0200, 0x0EF1) + guid_bytes(CERT_PKCS7)
    return tstamp + win + p7 + payload

root_key, root_crt = f"{ca}/root.key", f"{ca}/root.crt"
jobs = {
    "db":  sig_list(der(f"{ca}/sb.der")),
    "KEK": sig_list(der(f"{ca}/root.der")),
    "PK":  sig_list(der(f"{ca}/root.der")),
}
for var, payload in jobs.items():
    blob = make_auth(var, payload, root_key, root_crt)
    open(f"{out}/{var}.auth", "wb").write(blob)
    print(f"{out}/{var}.auth: {len(blob)} bytes")

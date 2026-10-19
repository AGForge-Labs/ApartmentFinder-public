#!/usr/bin/env python3
"""Regenerate explicitly fictional import fixtures; no owner exports are inputs."""
import base64
import io
from pathlib import Path
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests" / "ApartmentCoreTests" / "Fixtures"
HEADER = b"Barcode,Last Event,Last Event time,Last GPS location,Seq No,Address\n"
# Street and unit numbers are invented for these parser tests. Locality words
# exercise the existing OnTrac grammar and do not describe actual deliveries.
CSV = HEADER + (
    b',,,,,"1200 FICTIONAL COURTYARD WAY Apt 4102. LAS VEGAS. NV. 89113"\n'
    b',,,,,"1200 Fictional Courtyard Way Apt 4108, Las Vegas, NV 89113"\n'
)


def archive(entries, *, method=zipfile.ZIP_DEFLATED):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=method, compresslevel=9) as target:
        for name, content, extra in entries:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = method
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.extra = extra
            target.writestr(info, content, compresslevel=9)
    return bytearray(output.getvalue())


def records(data):
    end = data.rfind(b"PK\x05\x06")
    count = struct.unpack_from("<H", data, end + 10)[0]
    position = struct.unpack_from("<I", data, end + 16)[0]
    result = []
    for _ in range(count):
        assert data[position:position + 4] == b"PK\x01\x02"
        local = struct.unpack_from("<I", data, position + 42)[0]
        lengths = struct.unpack_from("<HHH", data, position + 28)
        result.append((local, position))
        position += 46 + sum(lengths)
    assert position == end
    return result


def generate():
    valid = archive([
        ("manifest_2026-01-02.csv", CSV, b""),
        ("manifest_2026-01-01.csv", HEADER, b""),
    ])
    values = {"ontrac-synthetic.csv": CSV, "ontrac-synthetic.zip": bytes(valid)}

    corrupt = bytearray(valid)
    _, central = records(corrupt)[0]
    checksum = struct.unpack_from("<I", corrupt, central + 16)[0]
    struct.pack_into("<I", corrupt, central + 16, checksum ^ 1)
    values["corrupt.zip"] = bytes(corrupt)

    encrypted = archive([("valid.csv", CSV, b""), ("locked.csv", CSV, b"")])
    local, central = records(encrypted)[1]
    struct.pack_into("<H", encrypted, local + 6, 1)
    struct.pack_into("<H", encrypted, central + 8, 1)
    values["encrypted-entry.zip"] = bytes(encrypted)
    values["traversal.zip"] = bytes(archive([("../manifest.csv", CSV, b"")]))
    values["oversized.zip"] = bytes(archive([("large.csv", HEADER + b"x" * 5_000_001, b"")]))

    maximum = (1 << 64) - 1
    extra = struct.pack("<HHQQ", 1, 16, maximum, maximum)
    metadata = archive([("valid.csv", CSV, b""), ("oversized.csv", b"x", extra)], method=zipfile.ZIP_STORED)
    local, central = records(metadata)[1]
    for offset in (local + 18, local + 22, central + 20, central + 24):
        struct.pack_into("<I", metadata, offset, 0xFFFFFFFF)
    values["overflow-metadata.zip"] = bytes(metadata)

    descriptor = archive([("bad.csv", b"x", struct.pack("<HHQ", 1, 8, maximum))])
    local, central = records(descriptor)[0]
    struct.pack_into("<H", descriptor, local + 6, 8)
    struct.pack_into("<H", descriptor, central + 8, 8)
    struct.pack_into("<I", descriptor, central + 20, 0xFFFFFFFF)
    values["overflow-descriptor.zip"] = bytes(descriptor)
    return values


if __name__ == "__main__":
    values = generate()
    for name, content in values.items():
        (FIXTURES / name).write_bytes(content)
    source = ROOT / "App" / "UITestSupport.swift"
    text = source.read_text(encoding="utf-8")
    encoded = base64.b64encode(values["ontrac-synthetic.zip"]).decode("ascii")
    text, count = re.subn(r'Data\(base64Encoded: "[A-Za-z0-9+/=]+"\)!',
                          f'Data(base64Encoded: "{encoded}")!', text)
    assert count == 1, "Expected exactly one simulator manifest fixture"
    source.write_text(text, encoding="utf-8", newline="\n")

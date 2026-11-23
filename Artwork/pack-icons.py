"""Pack macOS and Windows icon containers from the PoruBot master PNG."""
from pathlib import Path
import struct
import subprocess
import tempfile

artwork = Path(__file__).resolve().parent
source = artwork / "PoruBot-Icon.png"
mac_types = {
    b"icp4": 16, b"ic11": 32, b"icp5": 32, b"ic12": 64, b"ic07": 128,
    b"ic13": 256, b"ic08": 256, b"ic14": 512, b"ic09": 512, b"ic10": 1024,
}
windows_sizes = (16, 32, 48, 64, 128, 256)
with tempfile.TemporaryDirectory() as directory:
    images = {}
    for size in sorted(set(mac_types.values()) | set(windows_sizes)):
        path = Path(directory) / f"{size}.png"
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(source), "--out", str(path)],
            check=True, stdout=subprocess.DEVNULL,
        )
        images[size] = path.read_bytes()

icns = b"".join(
    struct.pack(">4sI", tag, len(images[size]) + 8) + images[size]
    for tag, size in mac_types.items()
)
(artwork.parent / "macOS" / "AppIcon.icns").write_bytes(
    struct.pack(">4sI", b"icns", len(icns) + 8) + icns
)
ico = struct.pack("<HHH", 0, 1, len(windows_sizes))
offset = 6 + 16 * len(windows_sizes)
for size in windows_sizes:
    ico += struct.pack(
        "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(images[size]), offset
    )
    offset += len(images[size])
ico += b"".join(images[size] for size in windows_sizes)
(artwork.parent / "Windows" / "PoruBot.ico").write_bytes(ico)

#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile
source = (Path(__file__).resolve().parent.parent / "Sources/DiskVista/DiskVista.swift").read_text()
core = source[source.index("struct DiskEntry"):source.index("func size(")]
test = r'''
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
try fm.createDirectory(at: root.appendingPathComponent("allowed"), withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("protected"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
try Data(repeating: 1, count: 16384).write(to: root.appendingPathComponent("allowed/file.bin"))
try Data(repeating: 2, count: 32768).write(to: root.appendingPathComponent("protected/secret.bin"))
try Data(repeating: 3, count: 4096).write(to: root.appendingPathComponent(".hidden"))
try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("protected"))
let result = try DiskScanner.scan(root, excluding: [root.appendingPathComponent("protected").standardizedFileURL.path]) { snapshot in
    assert(snapshot.scannedFiles > 0)
    assert(!snapshot.files.contains { $0.name == "secret.bin" })
}
assert(result.scannedFiles == 1)
assert(result.files.count == 1)
assert(result.groups.count == 1 && result.groups[0].name == "allowed")
assert(result.excluded == 1)
assert(result.total == result.files[0].bytes)
assert(result.skipped == 0)
let empty = try DiskScanner.scan(root.appendingPathComponent("allowed"), excluding: [root.appendingPathComponent("allowed/file.bin").standardizedFileURL.path])
assert(empty.total == 0)
let full = try DiskScanner.scan(root, comprehensive: true)
assert(full.scannedFiles == 3)
assert(full.files.contains { $0.name == ".hidden" })
assert(full.groups.reduce(0) { $0 + $1.bytes } == full.total)
let values = try fm.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
assert((values.volumeTotalCapacity ?? 0) > 0)
assert((values.volumeAvailableCapacity ?? -1) >= 0)
print("PASS: protected-folder exclusion, hidden files, symlinks, live snapshots, totals, empty results, disk capacity")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "check.swift"
    path.write_text("import Foundation\n" + core + test)
    subprocess.run(["swift", str(path)], check=True)

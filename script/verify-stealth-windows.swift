#!/usr/bin/env swift
//
// Stealth Mode'un gerçekten uygulandığını pencere sunucusundan okur.
//
// `NSWindow.sharingType` uygulamanın kendi içinde bir ayar; kullanıcıyı
// ilgilendiren şey macOS'un bu pencereyi nasıl gördüğü. `CGWindowListCopyWindowInfo`
// her pencere için `kCGWindowSharingState` döndürür:
//
//   0 = paylaşılmıyor (ekran görüntüsü ve kayıtlarından çıkarılır)
//   1 = yalnız okunur
//   2 = okunur/yazılır
//
// Kullanım:
//   swift script/verify-stealth-windows.swift            # uygulama çalışıyor olmalı
//   swift script/verify-stealth-windows.swift --owner Foo
//
import AppKit
import CoreGraphics

var owner = "AgenticSidebar"
var expectExcluded = true
var arguments = Array(CommandLine.arguments.dropFirst())

while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--owner":
        guard let value = arguments.first else {
            FileHandle.standardError.write(Data("--owner needs a value\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        owner = value
    case "--expected":
        guard let value = arguments.first, let number = Int(value) else {
            FileHandle.standardError.write(Data("--expected needs 0, 1 or 2\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        expectExcluded = number == 0
    default:
        FileHandle.standardError.write(Data("unknown argument: \(flag)\n".utf8))
        exit(2)
    }
}

let sharingNames: [Int: String] = [0: "excluded", 1: "read-only", 2: "read-write"]

guard
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("window list unavailable\n".utf8))
    exit(1)
}

var inspected = 0
var offenders: [String] = []

for window in windows {
    guard
        let ownerName = window[kCGWindowOwnerName as String] as? String,
        ownerName == owner
    else {
        continue
    }

    let name = window[kCGWindowName as String] as? String ?? "(unnamed layer \(window[kCGWindowLayer as String] as? Int ?? -1))"
    let sharing = window[kCGWindowSharingState as String] as? Int ?? -1
    inspected += 1

    let label = sharingNames[sharing] ?? "unknown(\(sharing))"
    print("sharing=\(sharing) (\(label))  \(name)")

    if expectExcluded && sharing != 0 {
        offenders.append(name)
    }
    if !expectExcluded && sharing == 0 {
        offenders.append(name)
    }
}

guard inspected > 0 else {
    FileHandle.standardError.write(Data("no windows found for \(owner) — is it running?\n".utf8))
    exit(1)
}

if offenders.isEmpty {
    print("PASS  \(inspected) window(s) of \(owner) match the expected sharing state")
    exit(0)
}

print("FAIL  \(offenders.count) window(s) out of \(inspected) do not match: \(offenders.joined(separator: ", "))")
exit(1)

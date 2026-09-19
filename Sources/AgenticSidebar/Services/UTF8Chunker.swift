import Foundation

/// UTF-8 sınırında bayt bölme: terminalden gelen ham baytlar çok baytlı bir
/// karakterin ortasında kesilebilir.
///
/// `longestValidPrefix` baştaki tamamlanmış yazının bayt sayısını döner.
/// Eksik kuyrukta 0 döner (daha çok bayt beklenir); `maximumIncompleteTail`
/// üstünde hâlâ 0 dönüyorsa baş bozuk demektir, çağrı tarafı düşürür.
/// Saf fonksiyondur; durum tutmaz.
enum UTF8Chunker {
    static func longestValidPrefix(in data: Data) -> Int {
        var index = data.startIndex
        var lastGood = data.startIndex
        while index < data.endIndex {
            guard let width = sequenceWidth(lead: data[index]) else {
                break
            }
            guard data.distance(from: index, to: data.endIndex) >= width else {
                break
            }
            guard isWellFormed(from: index, width: width, in: data) else {
                break
            }
            lastGood = data.index(index, offsetBy: width)
            index = lastGood
        }
        return data.distance(from: data.startIndex, to: lastGood)
    }

    // MARK: - Özel

    /// Öncü bayta göre dizi genişliği; devam baytı ya da geçersiz öncü `nil`.
    private static func sequenceWidth(lead byte: UInt8) -> Int? {
        if byte & 0x80 == 0x00 {
            return 1
        } else if byte & 0xE0 == 0xC0 {
            return 2
        } else if byte & 0xF0 == 0xE0 {
            return 3
        } else if byte & 0xF8 == 0xF0 {
            return 4
        }
        return nil
    }

    /// Devam baytları + aşırı-uzun/surrogate/sınır-dışı redleri.
    private static func isWellFormed(from index: Data.Index, width: Int, in data: Data) -> Bool {
        if width == 1 {
            return true
        }
        let lead = data[index]
        let second = data[data.index(after: index)]
        guard second & 0xC0 == 0x80 else {
            return false
        }
        for offset in 2..<width {
            let byte = data[data.index(index, offsetBy: offset)]
            guard byte & 0xC0 == 0x80 else {
                return false
            }
        }
        switch width {
        case 2:
            return lead >= 0xC2
        case 3:
            if lead == 0xE0 {
                return second >= 0xA0
            }
            if lead == 0xED {
                return second <= 0x9F
            }
            return true
        case 4:
            if lead == 0xF0 {
                return second >= 0x90
            }
            if lead == 0xF4 {
                return second <= 0x8F
            }
            return lead < 0xF4
        default:
            return false
        }
    }
}

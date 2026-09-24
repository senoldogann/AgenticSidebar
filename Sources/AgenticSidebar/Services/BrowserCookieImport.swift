import CommonCrypto
import Foundation
import SQLite3
import Security
import WebKit

/// Kullanıcının kendi tarayıcı profilinden gelen tek bir çerez.
///
/// Chrome'un `Cookies` tablosuyla Safari'nin `binarycookies` dosyasından
/// ortak payda: etki alanı, ad, değer, yol, güvenlik bayrağı ve bitiş. `HttpOnly`
/// bayrağı `HTTPCookie` ile taşınamaz; bu çerezler bayraksız yazılır, değeri
/// ve oturumu korunur.
struct PersonalBrowserCookie: Sendable, Equatable {
    let domain: String
    let name: String
    let value: String
    let path: String
    let isSecure: Bool
    let expiresAt: Date?
}

// MARK: - Chrome

/// Chrome'un v10 şifreli çerezlerini okur.
///
/// Değerler `Chrome Safe Storage` anahtar zinciri öğesinden türetilen
/// anahtarla AES-128-CBC ile şifrelidir (PBKDF2-HMAC-SHA1, `saltysalt`,
/// 1003 tur). Anahtar zinciri okuması ilk seferde sisteme onay sorar; ret
/// edilirse hata döner, sessiz geçilmez. v11/v20 (uygulamaya bağlı) değerler
/// dışarıdan çözülemez: atlanıp sayılır.
enum ChromeCookieImporter {
    enum ImportError: LocalizedError, Equatable {
        case databaseMissing(path: String)
        case databaseUnreadable(detail: String)
        case keychainMissing
        case keychainDenied
        case keychainFailed(status: OSStatus)
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .databaseMissing(let path):
                "Chrome cookie database was not found at \(path)."
            case .databaseUnreadable(let detail):
                "Chrome cookie database could not be read: \(detail)"
            case .keychainMissing:
                "The Chrome Safe Storage item was not found in the login keychain."
            case .keychainDenied:
                "Keychain access to Chrome Safe Storage was denied; Chrome cookies were not imported."
            case .keychainFailed(let status):
                "Keychain access to Chrome Safe Storage failed (status \(status))."
            case .keyDerivationFailed:
                "The Chrome cookie key could not be derived."
            }
        }
    }

    struct LoadResult: Sendable, Equatable {
        let cookies: [PersonalBrowserCookie]
        /// v11/v20 gibi çözülemeyen değer sayısı.
        let skippedEncrypted: Int
    }

    nonisolated static func defaultDatabasePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
    }

    static func loadCookies(databasePath: String) throws -> LoadResult {
        try loadCookies(databasePath: databasePath, keyPassword: keychainPassword())
    }

    static func loadCookies(databasePath: String, keyPassword: Data) throws -> LoadResult {
        let snapshot = try snapshotDatabase(at: databasePath)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        let decoder = try ChromeCookieDecoder(keyPassword: keyPassword)
        return try readCookies(from: snapshot, decoder: decoder)
    }

    private static func snapshotDatabase(at path: String) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ImportError.databaseMissing(path: path)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-sidebar-chrome-cookies-\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(atPath: path, toPath: temporary.path)
        } catch {
            throw ImportError.databaseUnreadable(detail: error.localizedDescription)
        }
        return temporary
    }

    /// Anahtar zincirinden Chrome'un çerez anahtar parolasını okur.
    static func keychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let password = item as? Data else {
                throw ImportError.keychainMissing
            }
            return password
        case errSecItemNotFound:
            throw ImportError.keychainMissing
        case errSecUserCanceled, errSecAuthFailed:
            throw ImportError.keychainDenied
        default:
            throw ImportError.keychainFailed(status: status)
        }
    }

    private static func readCookies(from snapshot: URL, decoder: ChromeCookieDecoder) throws -> LoadResult {
        var database: OpaquePointer?
        let opened = snapshot.path.withCString { path in
            sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        }
        guard opened == SQLITE_OK, let database else {
            throw ImportError.databaseUnreadable(detail: "sqlite3_open failed with code \(opened)")
        }
        defer { _ = sqlite3_close(database) }

        let query = """
            SELECT host_key, name, encrypted_value, path, expires_utc, is_secure, is_session
            FROM cookies
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw ImportError.databaseUnreadable(
                detail: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { _ = sqlite3_finalize(statement) }

        var cookies: [PersonalBrowserCookie] = []
        var skippedEncrypted = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let host = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                !host.isEmpty, !name.isEmpty
            else {
                continue
            }
            let blobLength = Int(sqlite3_column_bytes(statement, 2))
            guard
                let blob = sqlite3_column_blob(statement, 2),
                blobLength > 0
            else {
                continue
            }
            let encrypted = Data(bytes: blob, count: blobLength)
            let path =
                sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "/"
            let expires = sqlite3_column_int64(statement, 4)
            let isSecure = sqlite3_column_int(statement, 5) != 0
            let isSession = sqlite3_column_int(statement, 6) != 0

            let value: String
            do {
                value = try decoder.decrypt(encrypted)
            } catch ChromeCookieDecoder.DecodeError.unsupportedScheme {
                skippedEncrypted += 1
                continue
            } catch {
                continue
            }

            cookies.append(
                PersonalBrowserCookie(
                    domain: host,
                    name: name,
                    value: value,
                    path: path.isEmpty ? "/" : path,
                    isSecure: isSecure,
                    expiresAt: Self.expiryDate(webKitMicroseconds: expires, isSession: isSession)
                )
            )
        }
        return LoadResult(cookies: cookies, skippedEncrypted: skippedEncrypted)
    }

    /// Chrome'un WebKit dönemi (1601-01-01, mikrosaniye) → `Date`.
    static func expiryDate(webKitMicroseconds: Int64, isSession: Bool) -> Date? {
        guard !isSession, webKitMicroseconds > 0 else {
            return nil
        }
        let seconds = Double(webKitMicroseconds) / 1_000_000 - 11_644_473_600
        guard seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Chrome v10 değer çözücü: anahtar bir kez türetilir, satırlar onunla çözülür.
struct ChromeCookieDecoder: Sendable {
    enum DecodeError: Error, Equatable {
        case unsupportedScheme
        case decryptionFailed
        case invalidText
    }

    private let key: Data

    init(keyPassword: Data) throws {
        var derived = Data(count: kCCKeySizeAES128)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            keyPassword.withUnsafeBytes { passwordBytes in
                "saltysalt".withCString { salt in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress.map { $0.assumingMemoryBound(to: CChar.self) },
                        passwordBytes.count,
                        salt,
                        strlen(salt),
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.baseAddress.map { $0.assumingMemoryBound(to: UInt8.self) },
                        kCCKeySizeAES128
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ChromeCookieImporter.ImportError.keyDerivationFailed
        }
        self.key = derived
    }

    /// `v10` öneki doğrulanır, CBC çözülür, PKCS7 sökülüp metin döner.
    func decrypt(_ encrypted: Data) throws -> String {
        guard encrypted.count > 3,
            encrypted[0] == 0x76, encrypted[1] == 0x31, encrypted[2] == 0x30
        else {
            throw DecodeError.unsupportedScheme
        }
        let ciphertext = encrypted.dropFirst(3)
        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let plainCapacity = plaintext.count
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { cipherBytes in
                    plaintext.withUnsafeMutableBytes { plainBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            ciphertext.count,
                            plainBytes.baseAddress,
                            plainCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw DecodeError.decryptionFailed
        }
        plaintext.count = moved
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw DecodeError.invalidText
        }
        return text
    }
}

// MARK: - Safari

/// Safari'nin `Cookies.binarycookies` dosyasını okur. Dosya şifresizdir;
/// başka uygulamanın kapsayıcısı olduğu için erişim Tam Disk Erişimi ister,
/// okunamazsa hata döner.
enum SafariCookieImporter {
    enum ImportError: LocalizedError, Equatable {
        case fileMissing(path: String)
        case fileUnreadable(detail: String)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .fileMissing(let path):
                "Safari cookie file was not found at \(path)."
            case .fileUnreadable(let detail):
                "Safari cookie file could not be read: \(detail)"
            case .invalidFormat:
                "Safari cookie file has an unexpected format."
            }
        }
    }

    nonisolated static func defaultCookieFilePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
    }

    /// Mac dönemi (2001-01-01, saniye) → `Date`; 0 ve öncesi oturum çerezidir.
    static func expiryDate(macEpochSeconds: Double) -> Date? {
        guard macEpochSeconds > 0 else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: macEpochSeconds)
    }

    static func loadCookies(cookieFilePath: String) throws -> [PersonalBrowserCookie] {
        guard FileManager.default.isReadableFile(atPath: cookieFilePath) else {
            throw ImportError.fileMissing(path: cookieFilePath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: cookieFilePath))
        } catch {
            throw ImportError.fileUnreadable(detail: error.localizedDescription)
        }
        return try SafariCookieParser.parse(data: data)
    }
}

/// `binarycookies` ikili biçimini okuyan saf çözümleyici: dosya okumaz,
/// yalnız baytları çerezlere indirger; bu yüzden testte doğrudan beslenir.
enum SafariCookieParser {
    static func parse(data: Data) throws -> [PersonalBrowserCookie] {
        guard data.count >= 8, data[0] == 0x63, data[1] == 0x6F,
            data[2] == 0x6F, data[3] == 0x6B
        else {
            throw SafariCookieImporter.ImportError.invalidFormat
        }
        let pageCount = Int(readBigEndian32(data: data, offset: 4))
        // Sayfalar başlıktan sonra dizilir: sihir (4) + sayfa sayısı (4) +
        // sayfa boyları (4 × sayfa). Boylar başlıkta, kayıtlar ardında durur.
        var pageStarts: [Int] = []
        var pageOffset = 8 + pageCount * 4
        for index in 0..<pageCount {
            guard 8 + index * 4 + 4 <= data.count else {
                throw SafariCookieImporter.ImportError.invalidFormat
            }
            let size = Int(readBigEndian32(data: data, offset: 8 + index * 4))
            guard size >= 4, pageOffset + size <= data.count else {
                throw SafariCookieImporter.ImportError.invalidFormat
            }
            pageStarts.append(pageOffset)
            pageOffset += size
        }

        var cookies: [PersonalBrowserCookie] = []
        for pageStart in pageStarts {
            // Sayım konumu sürüme göre değişir: klasikte sayfa başında (+0),
            // yeni biçimde 4 baytlık önekin ardında (+4). Tutarlı tabloyu
            // veren ve çerez çıkaran düzen kazanır; ikisi de vermezse sayfa
            // atlanır.
            if let found = readPage(data: data, pageStart: pageStart, countOffset: pageStart),
                !found.isEmpty || pageCookieCount(data: data, countOffset: pageStart) == 0
            {
                cookies += found
            } else if let found = readPage(data: data, pageStart: pageStart, countOffset: pageStart + 4) {
                cookies += found
            }
        }
        return cookies
    }

    private static func pageCookieCount(data: Data, countOffset: Int) -> Int? {
        guard countOffset >= 0, countOffset + 4 <= data.count else {
            return nil
        }
        let count = Int(readLittleEndian32(data: data, offset: countOffset))
        guard count >= 0, count <= 100_000 else {
            return nil
        }
        return count
    }

    /// Sayfa tablosunu okur; tablo tutarsızsa `nil` döner (kayıtlar tek tek
    /// elenmez, bütün düzen reddedilir).
    private static func readPage(data: Data, pageStart: Int, countOffset: Int) -> [PersonalBrowserCookie]? {
        guard countOffset >= 0, countOffset + 4 <= data.count else {
            return nil
        }
        let cookieCount = Int(readLittleEndian32(data: data, offset: countOffset))
        guard cookieCount >= 0, cookieCount <= 100_000,
            countOffset + 4 + cookieCount * 4 <= data.count
        else {
            return nil
        }
        var offsets: [Int] = []
        for index in 0..<cookieCount {
            let recordOffset =
                pageStart + Int(readLittleEndian32(data: data, offset: countOffset + 4 + index * 4))
            guard recordOffset >= pageStart, recordOffset + 56 <= data.count else {
                return nil
            }
            offsets.append(recordOffset)
        }
        var found: [PersonalBrowserCookie] = []
        for recordOffset in offsets {
            if let cookie = readCookie(data: data, offset: recordOffset) {
                found.append(cookie)
            }
        }
        return found
    }

    private static func readCookie(data: Data, offset: Int) -> PersonalBrowserCookie? {
        guard offset + 56 <= data.count else {
            return nil
        }
        // Boyut alanı yeni biçimde güvenilmez olabilir; tutarlıysa dizelerin
        // üst sınırı olur, değilse dosya sonu kullanılır.
        let cookieSize = Int(readLittleEndian32(data: data, offset: offset))
        let limit =
            cookieSize >= 56 && offset + cookieSize <= data.count
            ? offset + cookieSize : data.count
        let flags = readLittleEndian32(data: data, offset: offset + 8)
        let urlOffset = Int(readLittleEndian32(data: data, offset: offset + 16))
        let nameOffset = Int(readLittleEndian32(data: data, offset: offset + 20))
        let pathOffset = Int(readLittleEndian32(data: data, offset: offset + 24))
        let valueOffset = Int(readLittleEndian32(data: data, offset: offset + 28))
        let expiry = readLittleEndianDouble(data: data, offset: offset + 40)

        guard
            let domain = readCString(data: data, base: offset, relative: urlOffset, limit: limit),
            let name = readCString(data: data, base: offset, relative: nameOffset, limit: limit),
            let value = readCString(data: data, base: offset, relative: valueOffset, limit: limit),
            !domain.isEmpty, !name.isEmpty
        else {
            return nil
        }
        let path = readCString(data: data, base: offset, relative: pathOffset, limit: limit) ?? "/"
        return PersonalBrowserCookie(
            domain: domain,
            name: name,
            value: value,
            path: path.isEmpty ? "/" : path,
            isSecure: flags & 0x1 != 0,
            expiresAt: SafariCookieImporter.expiryDate(macEpochSeconds: expiry)
        )
    }

    private static func readCString(data: Data, base: Int, relative: Int, limit: Int) -> String? {
        guard relative > 0 else {
            return nil
        }
        let start = base + relative
        guard start < limit else {
            return nil
        }
        var end = start
        while end < limit, data[end] != 0 {
            end += 1
        }
        guard end < limit else {
            return nil
        }
        return String(data: data[start..<end], encoding: .utf8)
    }

    private static func readBigEndian32(data: Data, offset: Int) -> UInt32 {
        let high = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
        let low = (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        return high | low
    }

    private static func readLittleEndian32(data: Data, offset: Int) -> UInt32 {
        let low = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
        let high = (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        return low | high
    }

    private static func readLittleEndianDouble(data: Data, offset: Int) -> Double {
        let low = UInt64(readLittleEndian32(data: data, offset: offset))
        let high = UInt64(readLittleEndian32(data: data, offset: offset + 4)) << 32
        return Double(bitPattern: low | high)
    }
}

// MARK: - Mağazaya yazma

/// Uygulama içi tarayıcının kalıcı deposuna kişisel profili taşıyan tek seferlik
/// aktarıcı.
///
/// `WKWebView` Safari/Chrome çerez kasasını paylaşamaz; platformun verdiği tek
/// yol çerezleri okuyup uygulamanın kendi kalıcı deposuna (`WKWebsiteDataStore.
/// default()`) yazmaktır. Girişler bir kez yazılıp kalır; sonraki açılışlarda
/// yeniden içe aktarılmaz, yerel depo yaşar.
actor BrowserProfileImporter {
    static let shared = BrowserProfileImporter()

    struct Summary: Sendable, Equatable {
        let imported: Int
        let skippedEncrypted: Int
        let chromeNote: String?
        let safariNote: String?

        var displayText: String {
            var parts: [String] = []
            if imported > 0 {
                parts.append("\(imported) cookies from your browser")
            }
            if skippedEncrypted > 0 {
                parts.append("\(skippedEncrypted) app-bound cookies skipped")
            }
            let notes = [chromeNote, safariNote].compactMap { $0 }
            if parts.isEmpty {
                return notes.first ?? "No browser cookies were found to import"
            }
            return parts.joined(separator: "; ") + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")
        }
    }

    private var cached: Summary?

    /// Uygulama ömründe bir kez çalışır; sonraki çağrılar kayıtlı özeti verir.
    func ensureImported() async -> Summary {
        if let cached {
            return cached
        }
        let summary = await Self.performImport(store: WKWebsiteDataStore.default())
        cached = summary
        return summary
    }

    private static func performImport(store: WKWebsiteDataStore) async -> Summary {
        var cookies: [PersonalBrowserCookie] = []
        var skippedEncrypted = 0
        var chromeNote: String?
        var safariNote: String?

        do {
            cookies += try SafariCookieImporter.loadCookies(
                cookieFilePath: SafariCookieImporter.defaultCookieFilePath()
            )
        } catch SafariCookieImporter.ImportError.fileMissing {
            // Safari kullanılmıyor ya da kapsayıcı okunamıyor: normal durum,
            // sessiz geçilir; Chrome zaten ana profili taşır.
        } catch {
            safariNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        do {
            let chrome = try ChromeCookieImporter.loadCookies(
                databasePath: ChromeCookieImporter.defaultDatabasePath()
            )
            cookies += chrome.cookies
            skippedEncrypted = chrome.skippedEncrypted
        } catch ChromeCookieImporter.ImportError.databaseMissing {
            // Chrome kurulu değil: normal durum, sessiz geçilir.
        } catch {
            chromeNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        var imported = 0
        let cookieStore = await Self.cookieStore(of: store)
        imported = await Self.writeCookies(cookies, into: cookieStore)

        return Summary(
            imported: imported,
            skippedEncrypted: skippedEncrypted,
            chromeNote: chromeNote,
            safariNote: safariNote
        )
    }

    /// Kalıcı deponun çerez kasasına yazar; `WKHTTPCookieStore` ana iş
    /// parçacığına bağlıdır, yazma orada koşar.
    @MainActor
    private static func cookieStore(of store: WKWebsiteDataStore) -> WKHTTPCookieStore {
        store.httpCookieStore
    }

    @MainActor
    private static func writeCookies(
        _ cookies: [PersonalBrowserCookie],
        into cookieStore: WKHTTPCookieStore
    ) async -> Int {
        var imported = 0
        let now = Date()
        for cookie in cookies {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: cookie.domain,
                .path: cookie.path,
                .name: cookie.name,
                .value: cookie.value,
                .version: "0",
            ]
            if cookie.isSecure {
                properties[.secure] = "TRUE"
            }
            if let expiresAt = cookie.expiresAt, expiresAt > now {
                properties[.expires] = expiresAt
            }
            guard let httpCookie = HTTPCookie(properties: properties) else {
                continue
            }
            await cookieStore.setCookie(httpCookie)
            imported += 1
        }
        return imported
    }
}

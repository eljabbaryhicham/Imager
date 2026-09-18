import AppKit
import Foundation

/// One-click updates from GitHub Releases.
///
/// Flow: check the latest release tag against the running version, download
/// the release's app zip, then swap bundles through a small helper script
/// (the running app cannot replace itself) and relaunch.
///
/// Trust note: releases are fetched over HTTPS from our own repository, but
/// there is no signature verification (the app is ad-hoc signed).
@MainActor
@Observable
final class AppUpdater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    var status: Status = .idle
    private var assetURL: URL?
    private var latestTag = ""

    private static let owner = "eljabbaryhicham"
    private static let repo = "Imager"

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func check() {
        guard !isBusy else { return }
        Task { await runCheck() }
    }

    func install() {
        guard !isBusy, case .available = status, let assetURL else { return }
        Task { await runInstall(assetURL: assetURL) }
    }

    // MARK: - Check

    private func runCheck() async {
        status = .checking
        do {
            let api = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
            var request = URLRequest(url: api, timeoutInterval: 20)
            request.setValue("Imager-Updater", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.network("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                throw UpdateError.network("Unexpected release data.")
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            latestTag = latest
            if Self.isNewer(latest, than: appVersion) {
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets
                    .compactMap { $0["browser_download_url"] as? String }
                    .first { $0.lowercased().hasSuffix(".zip") && URL(string: $0)?.lastPathComponent.lowercased().contains("imager") == true }
                    ?? assets.compactMap { $0["browser_download_url"] as? String }
                        .first { $0.lowercased().hasSuffix(".zip") }
                guard let zip, let url = URL(string: zip) else {
                    throw UpdateError.network("Release \(tag) has no app download.")
                }
                assetURL = url
                status = .available(version: latest)
            } else {
                status = .upToDate(latest: latest)
            }
        } catch let error as UpdateError {
            status = .failed(error.message)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let a = i < l.count ? l[i] : 0, b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Install

    private func runInstall(assetURL: URL) async {
        status = .downloading
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImagerUpdate", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tempURL, response) = try await URLSession.shared.download(from: assetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.network("Download failed.")
            }
            let zip = work.appendingPathComponent("update.zip")
            try? FileManager.default.removeItem(at: zip)
            try FileManager.default.moveItem(at: tempURL, to: zip)

            status = .installing
            let extracted = work.appendingPathComponent("extracted", isDirectory: true)
            try runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            guard let newApp = findAppBundle(under: extracted) else {
                throw UpdateError.network("Download didn't contain the app.")
            }
            try await relaunch(replacing: Bundle.main.bundleURL, with: newApp)
        } catch let error as UpdateError {
            status = .failed(error.message)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.network("Install step failed.")
        }
    }

    /// Finds Imager.app at the zip root (or one level down for legacy zips).
    private func findAppBundle(under directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("Imager.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents where item.pathExtension == "app" {
            return item
        }
        for item in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let nested = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            if let app = nested.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    /// Hands the swap to a detached script (a running app cannot replace its
    /// own bundle): wait for our exit, swap with backup + restore on failure,
    /// reopen, then quit ourselves.
    private func relaunch(replacing currentApp: URL, with newApp: URL) async throws {
        let script = """
        #!/bin/sh
        PID="\(ProcessInfo.processInfo.processIdentifier)"
        NEWAPP="\(newApp.path)"
        CURAPP="\(currentApp.path)"
        BACKUP="${CURAPP}.backup"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$BACKUP"
        mv "$CURAPP" "$BACKUP" || exit 1
        if ! mv "$NEWAPP" "$CURAPP"; then
          mv "$BACKUP" "$CURAPP"
          exit 1
        fi
        rm -rf "$BACKUP"
        open "$CURAPP"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagerUpdate")
            .appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
        NSApplication.shared.terminate(nil)
    }
}

private enum UpdateError: Error {
    case network(String)
    var message: String {
        switch self {
        case .network(let text): text
        }
    }
}

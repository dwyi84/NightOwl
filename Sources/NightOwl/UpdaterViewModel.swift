import AppKit
import Foundation

struct ReleaseInfo {
    let version: String
    let htmlURL: URL
    let assetURL: URL?
}

/// GitHub Releases based updater, ported from the LookHere template.
/// Queries the Releases API, downloads the newest `.zip` asset and swaps the
/// running app in place via a detached helper script.
@MainActor
final class UpdaterViewModel: ObservableObject {

    enum UpdateState: Equatable {
        case idle
        case checking
        case downloading
        case upToDate
        case updateAvailable
        case failed
    }

    static let repoOwner = "dwyi84"
    static let repoName = "NightOwl"
    static let currentVersion = "0.3.3"

    @Published private(set) var updateState: UpdateState = .idle
    @Published var showUpdateConfirm = false

    private var pendingUpdate: ReleaseInfo?
    var pendingUpdateVersion: String? { pendingUpdate?.version }

    private static let apiURL = URL(
        string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )!

    var buttonTitle: String {
        switch updateState {
        case .idle: "Check for Updates"
        case .checking: "Checking…"
        case .downloading: "Downloading…"
        case .updateAvailable: "Update Available"
        case .upToDate: "Up to Date"
        case .failed: "Check Again"
        }
    }

    var isBusy: Bool {
        updateState == .checking || updateState == .downloading
    }

    // MARK: Check

    func checkForUpdates() {
        updateState = .checking
        Task { [weak self] in
            guard let self else { return }
            if let release = await Self.fetchLatestRelease() {
                if Self.isNewer(release.version) {
                    pendingUpdate = release
                    updateState = .updateAvailable
                    showUpdateConfirm = true
                } else {
                    updateState = .upToDate
                    scheduleIdleReset()
                }
            } else {
                updateState = .failed
                scheduleIdleReset()
            }
        }
    }

    func cancelPrompt() {
        showUpdateConfirm = false
        pendingUpdate = nil
        updateState = .idle
    }

    // MARK: Install

    func installNow() {
        showUpdateConfirm = false
        guard let release = pendingUpdate, let assetURL = release.assetURL else {
            updateState = .failed
            scheduleIdleReset()
            return
        }
        updateState = .downloading
        Task { [weak self] in
            do {
                let zipURL = try await Self.downloadAsset(from: assetURL)
                Self.installAndRelaunch(zipURL: zipURL)
            } catch {
                guard let self else { return }
                updateState = .failed
                scheduleIdleReset()
            }
        }
    }

    private func scheduleIdleReset() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if updateState == .upToDate || updateState == .failed {
                updateState = .idle
            }
        }
    }

    // MARK: GitHub Releases plumbing

    private static func fetchLatestRelease() async -> ReleaseInfo? {
        var request = URLRequest(url: apiURL)
        request.setValue("NightOwl/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let rawTag = json?["tag_name"] as? String,
                  let html = json?["html_url"] as? String,
                  let url = URL(string: html) else {
                return nil
            }
            let assetURL = (json?["assets"] as? [[String: Any]])?
                .compactMap { $0["browser_download_url"] as? String }
                .compactMap(URL.init(string:))
                .first { $0.pathExtension == "zip" }
            // Store the version without the "v" tag prefix — the UI adds it.
            let tag = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
            return ReleaseInfo(version: tag, htmlURL: url, assetURL: assetURL)
        } catch {
            return nil
        }
    }

    private static func isNewer(_ version: String) -> Bool {
        let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return cleaned.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    private static func downloadAsset(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("NightOwl/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// Replaces the running .app with the downloaded one and relaunches.
    /// A detached helper script does the swap after this process exits.
    private static func installAndRelaunch(zipURL: URL) {
        let bundleURL = Bundle.main.bundleURL
        let appPath = bundleURL.path
        let appDir = bundleURL.deletingLastPathComponent().path
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("nightowl-update.sh")

        let script = """
        #!/bin/bash
        sleep 1
        pkill -x NightOwl 2>/dev/null || true
        sleep 0.5
        rm -rf "\(appPath)"
        ditto -x -k "\(zipURL.path)" "\(appDir)"
        chmod +x "\(appPath)/Contents/MacOS/NightOwl" 2>/dev/null || true
        open "\(appPath)"
        rm -f "\(zipURL.path)" "\(scriptPath)"
        exit 0
        """

        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

import AppKit
import Foundation

enum MusicSource: String, CaseIterable, Equatable, Sendable {
    case appleMusic
    case spotify
    case qqMusic

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .qqMusic: return "QQ音乐"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .qqMusic: return "com.tencent.QQMusicMac"
        }
    }

    fileprivate var applicationName: String {
        switch self {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        case .qqMusic: return "QQMusic"
        }
    }

    fileprivate func durationInSeconds(_ value: Double) -> Double {
        self == .spotify ? value / 1_000 : value
    }
}

struct MusicTrack: Equatable, Sendable {
    let id: String
    let source: MusicSource
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    var cacheKey: String {
        "\(source.rawValue):\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

enum MusicPlaybackState: String, Sendable {
    case notRunning
    case stopped
    case paused
    case playing
}

enum MusicRepeatMode: String, Equatable, Sendable {
    case off
    case all
    case one

    func next(for source: MusicSource) -> MusicRepeatMode {
        if source == .spotify {
            return self == .off ? .all : .off
        }
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct MusicSnapshot: Equatable, Sendable {
    let source: MusicSource
    let playbackState: MusicPlaybackState
    let track: MusicTrack?
    let position: TimeInterval
    let volume: Double
    let artworkURL: URL?
    let shuffleEnabled: Bool
    let repeatMode: MusicRepeatMode
}

@MainActor
final class MusicService: ObservableObject {
    @Published private(set) var track: MusicTrack?
    @Published private(set) var playbackState: MusicPlaybackState = .notRunning
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var volume: Double = 0.7
    @Published private(set) var artwork: NSImage?
    @Published private(set) var automationDenied = false
    @Published private(set) var playbackActivationDate = Date.distantPast
    @Published private(set) var activeSource: MusicSource = .appleMusic
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: MusicRepeatMode = .off

    private static let artworkCache = NSCache<NSString, NSImage>()
    private var pollingTimer: Timer?
    private var refreshInFlight = false
    private var snapshots: [MusicSource: MusicSnapshot] = [:]
    private var activationDates: [MusicSource: Date] = [:]
    private var automationDeniedSources: Set<MusicSource> = []
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID = UUID()
    private var loadingTrackID: String?

    init() {
        refresh()
        setupDistributedObservers()
        updatePollingTimerState()
    }

    deinit {
        pollingTimer?.invalidate()
        artworkTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupDistributedObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        MediaRemoteBridge.registerForNotifications()
        let localCenter = NotificationCenter.default
        let mrNotifications = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        for name in mrNotifications {
            localCenter.addObserver(
                forName: NSNotification.Name(name),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func updatePollingTimerState() {
        if isPlaying {
            guard pollingTimer == nil else { return }
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            pollingTimer?.tolerance = 0.25
        } else {
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
    }

    func pause() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func resume() {
        refresh()
        updatePollingTimerState()
    }

    var isPlaying: Bool { playbackState == .playing }

    func togglePlayback() {
        if activeSource == .qqMusic {
            runQQMusicCommand("click menu item 1 of menu 1 of menu bar item \"播放控制\" of menu bar 1")
            return
        }
        runCommand("playpause")
    }

    func previousTrack() {
        if activeSource == .qqMusic {
            runQQMusicCommand("click menu item 2 of menu 1 of menu bar item \"播放控制\" of menu bar 1")
            return
        }
        runCommand("previous track")
    }

    func nextTrack() {
        if activeSource == .qqMusic {
            runQQMusicCommand("click menu item 3 of menu 1 of menu bar item \"播放控制\" of menu bar 1")
            return
        }
        runCommand("next track")
    }

    func toggleShuffle() {
        let nextValue = !shuffleEnabled
        shuffleEnabled = nextValue
        switch activeSource {
        case .appleMusic:
            runCommand("set shuffle enabled to \(nextValue)")
        case .spotify:
            runCommand("set shuffling to \(nextValue)")
        case .qqMusic:
            runQQMusicCommand("click menu item 1 of menu of menu item \"播放模式\" of menu 1 of menu bar item \"播放控制\" of menu bar 1")
        }
    }

    func cycleRepeatMode() {
        let nextMode = repeatMode.next(for: activeSource)
        repeatMode = nextMode
        switch activeSource {
        case .appleMusic:
            runCommand("set song repeat to \(nextMode.rawValue)")
        case .spotify:
            runCommand("set repeating to \(nextMode == .off ? "false" : "true")")
        case .qqMusic:
            if nextMode == .one {
                runQQMusicCommand("click menu item 2 of menu of menu item \"播放模式\" of menu 1 of menu bar item \"播放控制\" of menu bar 1")
            } else {
                runQQMusicCommand("click menu item 3 of menu of menu item \"播放模式\" of menu 1 of menu bar item \"播放控制\" of menu bar 1")
            }
        }
    }

    func seek(to value: TimeInterval) {
        let safePosition = value.clamped(to: 0...(track?.duration ?? max(value, 0)))
        if activeSource == .qqMusic {
            MediaRemoteBridge.setElapsedTime(safePosition)
            refresh()
            return
        }
        runCommand("set player position to \(safePosition)")
    }

    func setVolume(_ value: Double) {
        let safeVolume = value.clamped(to: 0...1)
        volume = safeVolume
        if activeSource == .qqMusic {
            return
        }
        runCommand("set sound volume to \(Int((safeVolume * 100).rounded()))")
    }

    func open(_ source: MusicSource) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: source.bundleIdentifier
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func openMusic() {
        open(.appleMusic)
    }

    func openSpotify() {
        open(.spotify)
    }

    func openQQMusic() {
        open(.qqMusic)
    }

    private func runQQMusicCommand(_ scriptBody: String) {
        let script = """
        tell application "System Events"
            if exists process "QQMusic" then
                tell process "QQMusic"
                    try
                        \(scriptBody)
                    end try
                end tell
            end if
        end tell
        """
        Task {
            _ = await Self.executeAsync(script)
            self.refresh()
        }
    }

    func isInstalled(_ source: MusicSource) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) != nil
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let runningSources = Set(
            MusicSource.allCases.filter {
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: $0.bundleIdentifier
                ).isEmpty
            }
        )

        Task {
            let results = await Self.fetchMetadata(runningSources: runningSources)
            self.refreshInFlight = false
            self.apply(results)
        }
    }

    nonisolated private static func fetchMetadata(
        runningSources: Set<MusicSource>
    ) async -> [MusicSource: Result<String, AppleScriptFailure>] {
        var results: [MusicSource: Result<String, AppleScriptFailure>] = [:]
        for source in MusicSource.allCases {
            if !runningSources.contains(source) {
                results[source] = .success(MusicPlaybackState.notRunning.rawValue)
                continue
            }
            switch source {
            case .appleMusic, .spotify:
                results[source] = execute(metadataScript(for: source))
            case .qqMusic:
                results[source] = await fetchQQMusicMetadata()
            }
        }
        return results
    }

    nonisolated static func formattedTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated static func parseMetadata(_ output: String, source: MusicSource) -> MusicSnapshot? {
        if let state = MusicPlaybackState(rawValue: output) {
            return MusicSnapshot(
                source: source,
                playbackState: state,
                track: nil,
                position: 0,
                volume: 0.7,
                artworkURL: nil,
                shuffleEnabled: false,
                repeatMode: .off
            )
        }

        let values = output.components(separatedBy: "\u{001F}")
        guard values.count >= 9,
              let state = MusicPlaybackState(rawValue: values[0]),
              let rawDuration = parseAppleScriptNumber(values[5]),
              let currentPosition = parseAppleScriptNumber(values[6]),
              let soundVolume = parseAppleScriptNumber(values[7]) else { return nil }

        let duration = source.durationInSeconds(rawDuration)
        let rawID = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let trackID = rawID.isEmpty
            ? "\(source.rawValue):\(values[2]):\(values[3]):\(values[4])"
            : "\(source.rawValue):\(rawID)"
        let track = MusicTrack(
            id: trackID,
            source: source,
            title: values[2],
            artist: values[3],
            album: values[4],
            duration: duration
        )
        let rawArtworkURL = values[8].trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicSnapshot(
            source: source,
            playbackState: state,
            track: track,
            position: currentPosition.clamped(to: 0...max(duration, 0)),
            volume: (soundVolume / 100).clamped(to: 0...1),
            artworkURL: rawArtworkURL.isEmpty ? nil : URL(string: rawArtworkURL),
            shuffleEnabled: values.count > 9 && Self.parseAppleScriptBoolean(values[9]),
            repeatMode: values.count > 10 ? Self.parseRepeatMode(values[10]) : .off
        )
    }

    /// AppleScript formats real numbers with the user's locale. Music apps can
    /// therefore return `36,584` on systems that use a decimal comma.
    nonisolated static func parseAppleScriptNumber(_ value: String) -> Double? {
        if let number = Double(value) { return number }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    nonisolated static func parseAppleScriptBoolean(_ value: String) -> Bool {
        ["true", "yes", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    nonisolated static func parseRepeatMode(_ value: String) -> MusicRepeatMode {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "one": return .one
        case "all", "true", "yes", "1": return .all
        default: return .off
        }
    }

    private func runCommand(_ command: String) {
        let source = activeSource
        let script = "tell application \"\(source.applicationName)\" to \(command)"
        Task {
            let result = await Self.executeAsync(script)
            if case let .failure(error) = result {
                if error.code == -1743 {
                    self.automationDeniedSources.insert(source)
                    self.automationDenied = source == self.activeSource
                }
            }
            self.refresh()
        }
    }

    nonisolated private static func executeAsync(_ script: String) async -> Result<String, AppleScriptFailure> {
        execute(script)
    }

    private func apply(_ results: [MusicSource: Result<String, AppleScriptFailure>]) {
        var updatedSnapshots = snapshots

        for source in MusicSource.allCases {
            guard let result = results[source] else { continue }
            switch result {
            case let .failure(error):
                if error.code == -1743 {
                    automationDeniedSources.insert(source)
                }
                updatedSnapshots[source] = MusicSnapshot(
                    source: source,
                    playbackState: .stopped,
                    track: nil,
                    position: 0,
                    volume: snapshots[source]?.volume ?? 0.7,
                    artworkURL: nil,
                    shuffleEnabled: false,
                    repeatMode: .off
                )
            case let .success(output):
                automationDeniedSources.remove(source)
                guard let snapshot = Self.parseMetadata(output, source: source) else {
                    updatedSnapshots[source] = MusicSnapshot(
                        source: source,
                        playbackState: .stopped,
                        track: nil,
                        position: 0,
                        volume: snapshots[source]?.volume ?? 0.7,
                        artworkURL: nil,
                        shuffleEnabled: false,
                        repeatMode: .off
                    )
                    continue
                }

                let previous = snapshots[source]
                let becameActive = snapshot.playbackState == .playing && (
                    previous?.playbackState != .playing
                        || previous?.track?.id != snapshot.track?.id
                )
                if becameActive {
                    activationDates[source] = Date()
                }
                updatedSnapshots[source] = snapshot
            }
        }

        snapshots = updatedSnapshots
        let selectedSource = resolveActiveSource()
        let selectedSnapshot = snapshots[selectedSource]
        let previousTrackID = track?.id

        activeSource = selectedSource
        playbackState = selectedSnapshot?.playbackState ?? .notRunning
        track = selectedSnapshot?.track
        position = selectedSnapshot?.position ?? 0
        volume = selectedSnapshot?.volume ?? volume
        automationDenied = automationDeniedSources.contains(selectedSource)
        playbackActivationDate = activationDates[selectedSource] ?? .distantPast
        shuffleEnabled = selectedSnapshot?.shuffleEnabled ?? false
        repeatMode = selectedSnapshot?.repeatMode ?? .off
        updatePollingTimerState()

        let trackChanged = previousTrackID != track?.id
        if trackChanged {
            artworkTask?.cancel()
            artworkTask = nil
            artworkRequestID = UUID()
            loadingTrackID = nil

            if let track, let cached = Self.artworkCache.object(forKey: track.cacheKey as NSString) {
                artwork = cached
            } else {
                artwork = nil
            }
        }

        if let track {
            if trackChanged || (artwork == nil && loadingTrackID != track.id) {
                loadArtwork(for: track, remoteURL: selectedSnapshot?.artworkURL)
            }
        } else {
            artwork = nil
        }
    }

    private func resolveActiveSource() -> MusicSource {
        let playing = MusicSource.allCases.filter {
            snapshots[$0]?.playbackState == .playing
        }
        if let source = playing.max(by: {
            (activationDates[$0] ?? .distantPast) < (activationDates[$1] ?? .distantPast)
        }) {
            return source
        }

        if snapshots[activeSource]?.track != nil {
            return activeSource
        }

        let withTrack = MusicSource.allCases.filter { snapshots[$0]?.track != nil }
        if let source = withTrack.max(by: {
            (activationDates[$0] ?? .distantPast) < (activationDates[$1] ?? .distantPast)
        }) {
            return source
        }

        if automationDeniedSources.contains(.spotify) { return .spotify }
        if automationDeniedSources.contains(.appleMusic) { return .appleMusic }
        if automationDeniedSources.contains(.qqMusic) { return .qqMusic }
        return activeSource
    }

    private func loadArtwork(for track: MusicTrack, remoteURL: URL?) {
        if let cached = Self.artworkCache.object(forKey: track.cacheKey as NSString) {
            artwork = cached
            loadingTrackID = nil
            return
        }

        loadingTrackID = track.id
        let requestID = artworkRequestID
        artworkTask?.cancel()
        artworkTask = Task {
            let loadedImage: NSImage?
            switch track.source {
            case .appleMusic:
                loadedImage = await Self.fetchAppleMusicArtwork()
            case .spotify:
                loadedImage = await Self.fetchRemoteArtwork(url: remoteURL)
            case .qqMusic:
                loadedImage = await Self.fetchQQMusicArtwork()
            }

            guard !Task.isCancelled else { return }

            if let loadedImage {
                Self.artworkCache.setObject(loadedImage, forKey: track.cacheKey as NSString)
                if self.track?.id == track.id && self.artworkRequestID == requestID {
                    self.artwork = loadedImage
                    self.loadingTrackID = nil
                }
            } else {
                let fallback = await Self.searchOnlineArtwork(for: track)
                guard !Task.isCancelled else { return }
                if let fallback {
                    Self.artworkCache.setObject(fallback, forKey: track.cacheKey as NSString)
                    if self.track?.id == track.id && self.artworkRequestID == requestID {
                        self.artwork = fallback
                        self.loadingTrackID = nil
                    }
                } else if self.track?.id == track.id && self.artworkRequestID == requestID {
                    self.loadingTrackID = nil
                }
            }
        }
    }

    nonisolated private static func fetchAppleMusicArtwork() async -> NSImage? {
        let script = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let descriptor = scriptObject.executeAndReturnError(&error)
        guard descriptor.data.count > 0 else { return nil }
        return NSImage(data: descriptor.data)
    }

    nonisolated private static func fetchRemoteArtwork(url: URL?) async -> NSImage? {
        guard let url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 5_000_000 else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func searchOnlineArtwork(for track: MusicTrack) async -> NSImage? {
        guard !track.title.isEmpty, track.title != "Unknown title" else { return nil }
        var query = track.title
        if !track.artist.isEmpty && track.artist != "Unknown artist" {
            query += " \(track.artist)"
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artworkUrlString = (first["artworkUrl100"] as? String)?
                    .replacingOccurrences(of: "100x100bb", with: "600x600bb"),
                  let imageURL = URL(string: artworkUrlString) else { return nil }
            let (imgData, imgResponse) = try await URLSession.shared.data(from: imageURL)
            guard (imgResponse as? HTTPURLResponse)?.statusCode == 200,
                  imgData.count <= 5_000_000 else { return nil }
            return NSImage(data: imgData)
        } catch {
            return nil
        }
    }

    nonisolated private static func execute(_ source: String) -> Result<String, AppleScriptFailure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(AppleScriptFailure(code: -1, message: "AppleScript could not be created."))
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            return .failure(
                AppleScriptFailure(
                    code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                    message: error[NSAppleScript.errorMessage] as? String ?? "Music command failed."
                )
            )
        }
        return .success(descriptor.stringValue ?? "")
    }

    nonisolated private static func fetchQQMusicArtwork() async -> NSImage? {
        if let info = await MediaRemoteBridge.getNowPlayingInfo(),
           let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            return NSImage(data: data)
        }
        return nil
    }

    nonisolated private static func fetchQQMusicMetadata() async -> Result<String, AppleScriptFailure> {
        let appleScript = """
        tell application "System Events"
            if not (exists process "QQMusic") then return "notRunning"
            tell process "QQMusic"
                set pState to "paused"
                try
                    set mName to name of menu item 1 of menu 1 of menu bar item "播放控制" of menu bar 1
                    if mName is "暂停" then set pState to "playing"
                end try
                
                set shuffleState to "false"
                set repeatState to "off"
                try
                    set subItems to menu items of menu 1 of menu item "播放模式" of menu 1 of menu bar item "播放控制" of menu bar 1
                    repeat with itm in subItems
                        set itmName to name of itm
                        set isMarked to (value of attribute "AXMenuItemMarkChar" of itm) is "✓"
                        if isMarked then
                            if itmName is "随机播放" then
                                set shuffleState to "true"
                            else if itmName is "单曲循环" then
                                set repeatState to "one"
                            else if itmName is "顺序播放" then
                                set repeatState to "all"
                            end if
                        end if
                    end repeat
                end try
                
                set songInfo to ""
                try
                    tell window 1
                        set bar to (first UI element whose description is "播放控制栏")
                        repeat with el in UI elements of bar
                            set d to description of el as text
                            if d starts with "歌曲名：" then
                                set songInfo to d
                                exit repeat
                            end if
                        end repeat
                    end tell
                end try
                
                return pState & "|" & shuffleState & "|" & repeatState & "|" & songInfo
            end tell
        end tell
        """
        let asResult = execute(appleScript)
        var asPlayState = "paused"
        var asShuffle = "false"
        var asRepeat = "off"
        var asWindowSong = ""

        if case let .success(asOutput) = asResult {
            if asOutput == "notRunning" {
                return .success(MusicPlaybackState.notRunning.rawValue)
            }
            let parts = asOutput.components(separatedBy: "|")
            if parts.count >= 3 {
                asPlayState = parts[0]
                asShuffle = parts[1]
                asRepeat = parts[2]
                if parts.count >= 4 {
                    asWindowSong = parts[3]
                }
            }
        } else if case let .failure(error) = asResult {
            if error.code == -1743 {
                return .failure(error)
            }
        }

        let mrClient = await MediaRemoteBridge.getNowPlayingClient()
        let isQQClient = mrClient?["bundleIdentifier"] as? String == MusicSource.qqMusic.bundleIdentifier
        let mrInfo = isQQClient ? await MediaRemoteBridge.getNowPlayingInfo() : nil
        let mrIsPlaying = await MediaRemoteBridge.getIsPlaying()

        var title = mrInfo?["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        var artist = mrInfo?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = mrInfo?["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (mrInfo?["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let position = (mrInfo?["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0

        if title.isEmpty && asWindowSong.hasPrefix("歌曲名：") {
            let stripped = asWindowSong.replacingOccurrences(of: "歌曲名：", with: "")
            let segments = stripped.components(separatedBy: " - 歌手名：")
            if segments.count >= 2 {
                title = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
                artist = segments[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let state = ((isQQClient && mrIsPlaying) || asPlayState == "playing") ? "playing" : "paused"

        if title.isEmpty {
            return .success(MusicPlaybackState.stopped.rawValue)
        }

        let sep = "\u{001F}"
        let trackID = "\(title):\(artist)"
        let formatted = "\(state)\(sep)\(trackID)\(sep)\(title)\(sep)\(artist)\(sep)\(album)\(sep)\(duration)\(sep)\(position)\(sep)80\(sep)\(sep)\(asShuffle)\(sep)\(asRepeat)"
        return .success(formatted)
    }

    nonisolated private static func metadataScript(for source: MusicSource) -> String {
        switch source {
        case .appleMusic:
            return appleMusicMetadataScript
        case .spotify:
            return spotifyMetadataScript
        case .qqMusic:
            return ""
        }
    }

    nonisolated private static let appleMusicMetadataScript = """
    tell application "Music"
        set playbackState to (player state as text)
        if playbackState is "stopped" then return "stopped"
        set activeTrack to current track
        try
            set trackID to (database ID of activeTrack as text)
        on error
            set trackID to (persistent ID of activeTrack as text)
        end try
        try
            set trackTitle to (name of activeTrack as text)
        on error
            set trackTitle to "Unknown title"
        end try
        try
            set trackArtist to (artist of activeTrack as text)
        on error
            set trackArtist to "Unknown artist"
        end try
        try
            set trackAlbum to (album of activeTrack as text)
        on error
            set trackAlbum to ""
        end try
        try
            set trackDuration to (duration of activeTrack as text)
        on error
            set trackDuration to "0"
        end try
        set trackPosition to (player position as text)
        set currentVolume to (sound volume as text)
        try
            set shuffleState to (shuffle enabled as text)
        on error
            set shuffleState to "false"
        end try
        try
            set repeatState to (song repeat as text)
        on error
            set repeatState to "off"
        end try
        set separator to ASCII character 31
        return playbackState & separator & trackID & separator & trackTitle & separator & trackArtist & separator & trackAlbum & separator & trackDuration & separator & trackPosition & separator & currentVolume & separator & "" & separator & shuffleState & separator & repeatState
    end tell
    """

    nonisolated private static let spotifyMetadataScript = """
    tell application "Spotify"
        set playbackState to (player state as text)
        if playbackState is "stopped" then return "stopped"
        set activeTrack to current track
        try
            set trackID to (spotify url of activeTrack as text)
        on error
            set trackID to (name of activeTrack as text)
        end try
        try
            set trackTitle to (name of activeTrack as text)
        on error
            set trackTitle to "Unknown title"
        end try
        try
            set trackArtist to (artist of activeTrack as text)
        on error
            set trackArtist to "Unknown artist"
        end try
        try
            set trackAlbum to (album of activeTrack as text)
        on error
            set trackAlbum to ""
        end try
        try
            set trackDuration to (duration of activeTrack as text)
        on error
            set trackDuration to "0"
        end try
        try
            set artworkAddress to (artwork url of activeTrack as text)
        on error
            set artworkAddress to ""
        end try
        set trackPosition to (player position as text)
        set currentVolume to (sound volume as text)
        try
            set shuffleState to (shuffling as text)
        on error
            set shuffleState to "false"
        end try
        try
            set repeatState to (repeating as text)
        on error
            set repeatState to "false"
        end try
        set separator to ASCII character 31
        return playbackState & separator & trackID & separator & trackTitle & separator & trackArtist & separator & trackAlbum & separator & trackDuration & separator & trackPosition & separator & currentVolume & separator & artworkAddress & separator & shuffleState & separator & repeatState
    end tell
    """
}

private struct AppleScriptFailure: Error, Equatable, Sendable {
    let code: Int
    let message: String
}

final class MediaRemoteBridge: @unchecked Sendable {
    private static let bundle: CFBundle? = {
        CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        )
    }()

    private typealias RegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias GetNowPlayingClientFn = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias SetElapsedTimeFn = @convention(c) (Double) -> Void

    static func registerForNotifications(queue: DispatchQueue = .main) {
        guard let bundle else { return }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let fn = unsafeBitCast(ptr, to: RegisterForNotificationsFn.self)
            fn(queue)
        }
    }

    static func getNowPlayingClient(queue: DispatchQueue = .main) async -> [String: Any]? {
        guard let bundle else { return nil }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) else { return nil }
        let fn = unsafeBitCast(ptr, to: GetNowPlayingClientFn.self)
        return await withCheckedContinuation { continuation in
            fn(queue) { client in
                guard let client = client as? NSObject else {
                    continuation.resume(returning: nil)
                    return
                }
                var dict: [String: Any] = [:]
                if let bundleID = client.value(forKey: "bundleIdentifier") as? String {
                    dict["bundleIdentifier"] = bundleID
                }
                if let displayName = client.value(forKey: "displayName") as? String {
                    dict["displayName"] = displayName
                }
                continuation.resume(returning: dict)
            }
        }
    }

    static func getNowPlayingInfo(queue: DispatchQueue = .main) async -> [String: Any]? {
        guard let bundle else { return nil }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else { return nil }
        let fn = unsafeBitCast(ptr, to: GetNowPlayingInfoFn.self)
        return await withCheckedContinuation { continuation in
            fn(queue) { info in
                continuation.resume(returning: info as? [String: Any])
            }
        }
    }

    static func getIsPlaying(queue: DispatchQueue = .main) async -> Bool {
        guard let bundle else { return false }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) else { return false }
        let fn = unsafeBitCast(ptr, to: GetIsPlayingFn.self)
        return await withCheckedContinuation { continuation in
            fn(queue) { isPlaying in
                continuation.resume(returning: isPlaying)
            }
        }
    }

    @discardableResult
    static func sendCommand(_ command: UInt32, userInfo: AnyObject? = nil) -> Bool {
        guard let bundle else { return false }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else { return false }
        let fn = unsafeBitCast(ptr, to: SendCommandFn.self)
        return fn(command, userInfo)
    }

    static func setElapsedTime(_ position: Double) {
        guard let bundle else { return }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetElapsedTime" as CFString) {
            let fn = unsafeBitCast(ptr, to: SetElapsedTimeFn.self)
            fn(position)
        }
    }
}

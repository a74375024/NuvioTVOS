import Foundation

/// Free TV listings from outside the user's server, gathered on the Apple TV
/// itself. While the app is open, a background-priority job downloads free
/// XMLTV guides, streams through them keeping only the channels in the
/// user's lineup, merges the same channel across sources (filling gaps from
/// lower-priority ones) and caches the small result. It pauses during
/// playback and runs at most about once a day.
enum OutsideGuide {
    // MARK: Sources

    struct Shard: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let defaultOn: Bool
    }

    struct Source {
        let name: String
        let shard: String
        let url: String
        /// A locals file: bare four-letter call signs count as call signs.
        var locals = false
        /// Only used when a main source for its listings is stale or short
        /// (it fills hours the main sources don't have).
        var backup = false
        /// Also used when these shards are on.
        var alsoShards: Set<String> = []
        /// Its times are written this many minutes late (epg.pw writes China
        /// time as UTC): the starting guess until one is learned.
        var assumedShift = 0
        /// Learn its clock shift from listings other sources already have.
        var calibrate = false
        /// Channels named by network and city ("5.1 CBS San Francisco"),
        /// resolved to a station through the station directory.
        var stationNames = false

        /// File name in the cache and key of its saved state.
        var id: String {
            String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }

        func applies(to shards: Set<String>) -> Bool {
            shards.contains(shard) || !alsoShards.isDisjoint(with: shards)
        }
    }

    /// A user channel a guide channel stands for. `shift`: minutes added to
    /// its times (a West feed made from the East one: +180).
    struct Match {
        let id: String
        let how: String
        let shift: Int
    }

    /// What happened with one source in the last update, for the Guide
    /// Listings screen, the log and the channel report.
    struct SourceState: Codable, Equatable {
        var id: String
        var name: String
        var backup: Bool
        var etag: String?
        var lastModified: Date?
        var checkedAt: Date?
        var downloadedAt: Date?
        /// 200 downloaded, 304 unchanged, 0 saved copy (download failed).
        var status: Int?
        var bytes: Int64?
        var problem: String?
        var guideChannels: Int?
        var matched: Int?
        /// Half of the matched channels' listings end before this (minutes since 1970).
        var horizonMedian: Int?
        var parseSeconds: Double?
        /// Minutes subtracted from its times (backups), and how that was decided.
        var shift: Int?
        var shiftNote: String?
        var stale: Bool?
        /// A backup used in the last update, and how many channels have
        /// listings from it.
        var used: Bool?
        var extended: Int?

        /// One line for the Guide Listings screen.
        func line(now: Date = Date()) -> String {
            let day = DateFormatter()
            day.dateFormat = "EEE MMM d, h:mm a"
            var parts: [String] = [name]
            if let lastModified { parts.append("file from \(day.string(from: lastModified))") }
            if let horizonMedian {
                parts.append("listings to \(day.string(from: Date(timeIntervalSince1970: TimeInterval(horizonMedian * 60))))")
            }
            if let matched { parts.append("\(matched) channels") }
            if let shift, shift != 0 { parts.append("times corrected \(shift / 60) h") }
            if backup {
                parts.append(used == true ? "in use" + (extended.map { ", fills \($0) channels" } ?? "") : "standing by")
            } else if stale == true {
                parts.append("out of date")
            }
            if let problem { parts.append("problem: \(problem)") }
            return parts.joined(separator: " · ")
        }
    }

    static let shards: [Shard] = [
        Shard(id: "us-locals", title: "US local stations", detail: "ABC, CBS, NBC, FOX, PBS, CW and other locals, matched by call sign or by network and city", defaultOn: true),
        Shard(id: "us", title: "US national & sports", detail: "Cable networks, premium and sports channels", defaultOn: true),
        Shard(id: "fast", title: "Free streaming channels", detail: "Pluto TV, Samsung TV Plus, Plex and Roku channels", defaultOn: true),
        Shard(id: "ca", title: "Canada", detail: "Canadian networks and locals", defaultOn: false),
        Shard(id: "uk", title: "United Kingdom", detail: "UK channels", defaultOn: false)
    ]

    /// In priority order: when two sources list the same channel, the first
    /// one's listings win and later ones only fill gaps.
    static let sources: [Source] = [
        Source(name: "US locals", shard: "us-locals", url: "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz", locals: true),
        Source(name: "US national", shard: "us", url: "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz"),
        Source(name: "US sports", shard: "us", url: "https://epgshare01.online/epgshare01/epg_ripper_US_SPORTS1.xml.gz"),
        Source(name: "Pluto TV", shard: "fast", url: "https://i.mjh.nz/PlutoTV/us.xml.gz"),
        Source(name: "Samsung TV Plus", shard: "fast", url: "https://i.mjh.nz/SamsungTVPlus/us.xml.gz"),
        Source(name: "Plex", shard: "fast", url: "https://i.mjh.nz/Plex/us.xml.gz"),
        Source(name: "Roku", shard: "fast", url: "https://i.mjh.nz/Roku/all.xml.gz"),
        Source(name: "Canada", shard: "ca", url: "https://epgshare01.online/epgshare01/epg_ripper_CA2.xml.gz"),
        Source(name: "UK", shard: "uk", url: "https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz"),
        // Backups, used only while a main source is stale or short. EPGTalk
        // first (right times, several days ahead), then epg.pw (nearly every
        // US channel, one day ahead, times written 8 h late).
        Source(name: "Backup: EPGTalk US", shard: "us",
               url: "https://raw.githubusercontent.com/acidjesuz/EPGTalk/master/US_lite.xml.gz", backup: true),
        Source(name: "Backup: EPGTalk sports", shard: "us",
               url: "https://raw.githubusercontent.com/acidjesuz/EPGTalk/master/Sports_guide.xml.gz", backup: true),
        Source(name: "Backup: EPGTalk locals", shard: "us-locals",
               url: "https://raw.githubusercontent.com/acidjesuz/EPGTalk/master/US_local_guide.xml.gz",
               backup: true, stationNames: true),
        Source(name: "Backup: epg.pw US", shard: "us-locals", url: "https://epg.pw/xmltv/epg_US.xml.gz",
               backup: true, alsoShards: ["us"], assumedShift: 480, calibrate: true)
    ]

    /// Rebuild when the saved listings are older than this. The sources cover
    /// several days ahead, so a day-old build still fills the guide.
    static let refreshAge: TimeInterval = 20 * 3600
    /// How far ahead listings are kept.
    static let keepHours: TimeInterval = 48

    // MARK: Settings

    private static let enabledKey = "nuvio.tv.livetv.outsideGuide.enabled"
    private static let shardsKey = "nuvio.tv.livetv.outsideGuide.shards"

    static var isEnabled: Bool {
        get { !ScreenTour.isMockLiveTV && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var enabledShards: Set<String> {
        get {
            if let saved = UserDefaults.standard.stringArray(forKey: shardsKey) { return Set(saved) }
            return Set(shards.filter(\.defaultOn).map(\.id))
        }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: shardsKey) }
    }

    // MARK: Data

    struct RawProgram: Codable {
        let s: Int        // start, minutes since 1970
        let m: Int        // length in minutes
        let t: String     // title
        let st: String?   // subtitle / episode title
        let d: String?    // description
        let f: Int        // flags: 1 movie, 2 sports, 4 news, 8 kids, 16 live, 32 new
    }

    /// A US / Canadian broadcast station from the station directory.
    struct Station: Codable {
        let callsign: String
        let network: String
        let cityTokens: [String]
        let channelNumber: String
    }

    /// The saved result: listings for the user's channels only.
    struct Saved: Codable {
        var built: Date
        var shards: [String]
        var channelCount: Int
        var programs: [String: [RawProgram]]
        /// How each channel was matched ("US locals: WNBC-DT, by call sign WNBC").
        var notes: [String: String]?
        /// Each source's state from the last update (by `Source.id`).
        var sources: [String: SourceState]? = nil
        /// When to look again: soon while a source is stale, else a day later.
        var nextCheck: Date? = nil
        /// The channel list and shards these listings were matched for.
        var targetsKey: String? = nil
        /// Sports descriptions kept for the whole window (2): older builds
        /// kept only the next few hours', so they're rebuilt once.
        var detailVersion: Int? = nil
    }

    static let detailVersion = 2

    // MARK: Cache

    private static func folder() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("OutsideGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func savedURL(signature: String) -> URL? {
        let safe = String(signature.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(80))
        return folder()?.appendingPathComponent("listings-\(safe).json")
    }

    static func loadSaved(signature: String) -> Saved? {
        guard let url = savedURL(signature: signature), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, signature: String) {
        guard let url = savedURL(signature: signature), let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func needsRebuild(_ saved: Saved?, shards: Set<String>, channelCount: Int) -> Bool {
        guard let saved else { return true }
        if Date().timeIntervalSince(saved.built) > refreshAge { return true }
        if Set(saved.shards) != shards { return true }
        if (saved.detailVersion ?? 1) < detailVersion { return true }
        if let next = saved.nextCheck, Date() >= next { return true }
        // A much bigger lineup than last time: new channels need matching.
        return channelCount > saved.channelCount + max(25, saved.channelCount / 10)
    }

    // MARK: Building

    struct BuildResult {
        var programs: [String: [RawProgram]]
        var problems: [String]
        var notes: [String: String]
        var states: [String: SourceState]
        var nextCheck: Date
        var targetsKey: String
        /// Lines for the log.
        var log: [String]
    }

    /// Main sources older than this, or reaching less than `shortHorizon`
    /// ahead, are stale: backups fill in and the update is retried soon.
    static let staleAge: TimeInterval = 36 * 3600
    static let shortHorizon = 12 * 60
    static let staleRetry: TimeInterval = 2 * 3600

    /// Builds listings for `channels` from the enabled sources. Runs on
    /// background threads; `progress` reports a short status line.
    ///
    /// Cheap when nothing changed: each file is kept, and the server is asked
    /// to skip it when unchanged. When every main file is unchanged and the
    /// channels are the same, the saved listings are reused as they are.
    static func build(
        for channels: [LiveTVChannel],
        shards: Set<String>,
        previous: Saved?,
        progress: @escaping @Sendable (String) -> Void
    ) async -> BuildResult {
        let started = Date()
        var log: [String] = []
        let targets = await Task.detached(priority: .background) { () -> Targets in
            progress("Getting the station directory…")
            let stations = shards.contains("us-locals") || shards.contains("ca")
                ? await StationDirectory.load() : []
            return Targets(channels: channels, stations: stations)
        }.value
        // A stable hash (Hasher is seeded per launch, so it can't be saved).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in channels.map(\.id).sorted() {
            for byte in channel.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            hash = (hash ^ 0x0a) &* 0x100_0000_01b3
        }
        let targetsKey = "\(channels.count)|\(String(hash, radix: 16))|\(shards.sorted().joined(separator: ","))"

        var merged: [String: [RawProgram]] = [:]
        var notes: [String: String] = [:]
        var problems: [String] = []
        var states = previous?.sources ?? [:]
        let now = Int(Date().timeIntervalSince1970 / 60)
        let window = (low: now - 180, high: now + Int(keepHours * 60))
        let chosen = sources.filter { $0.applies(to: shards) }
        let mains = chosen.filter { !$0.backup }
        let backups = chosen.filter(\.backup)

        func state(_ source: Source) -> SourceState {
            states[source.id] ?? SourceState(id: source.id, name: source.name, backup: source.backup)
        }

        // 1. Main sources: ask for each file only if it changed.
        var files: [String: URL] = [:]
        for (index, source) in mains.enumerated() {
            if Task.isCancelled { break }
            progress("Checking listings: \(source.name) (\(index + 1) of \(mains.count))…")
            var value = state(source)
            value.checkedAt = Date()
            do {
                let fetched = try await GuideFiles.fetchCached(id: source.id, url: source.url,
                                                               etag: value.etag, lastModified: value.lastModified)
                files[source.id] = fetched.file
                value.status = fetched.status
                value.bytes = fetched.bytes
                value.problem = fetched.problem
                if fetched.changed {
                    value.etag = fetched.etag
                    value.lastModified = fetched.lastModified
                    value.downloadedAt = Date()
                }
                log.append("guide \(source.name): \(fetched.status == 304 ? "unchanged" : fetched.status == 0 ? "saved copy (\(fetched.problem ?? "?"))" : "downloaded") "
                           + "\(fetched.bytes / 1_048_576) MB" + (value.lastModified.map { ", file from \(Int(Date().timeIntervalSince($0) / 3600)) h ago" } ?? ""))
            } catch {
                value.status = nil
                value.problem = error.localizedDescription
                problems.append("\(source.name): \(error.localizedDescription)")
                log.append("guide \(source.name): failed (\(error.localizedDescription))")
            }
            states[source.id] = value
        }

        // 2. The main listings: reused when nothing changed, else read again.
        let unchanged = mains.allSatisfy { states[$0.id]?.status == 304 || states[$0.id]?.status == 0 }
        let reuse = unchanged && previous?.targetsKey == targetsKey && (previous?.detailVersion ?? 1) >= detailVersion
        if reuse, let previous {
            for (id, list) in previous.programs {
                let kept = list.filter { $0.s + $0.m > window.low }
                if !kept.isEmpty { merged[id] = kept }
            }
            notes = previous.notes ?? [:]
            log.append("guide main sources unchanged: saved listings reused (\(merged.count) channels)")
        } else {
            for (index, source) in mains.enumerated() {
                if Task.isCancelled { break }
                guard let file = files[source.id] else { continue }
                progress("Updating listings: \(source.name) (\(index + 1) of \(mains.count))…")
                do {
                    let found = try await XMLTVReader.read(source: source, file: file, targets: targets, window: window)
                    for (channelID, entry) in found.programs {
                        merged[channelID] = mergePrograms(merged[channelID] ?? [], entry.programs)
                        let note = "\(source.name): \(entry.note)"
                        notes[channelID] = notes[channelID].map { "\($0); \(note)" } ?? note
                    }
                    var value = state(source)
                    value.guideChannels = found.guideChannels
                    value.matched = found.programs.count
                    value.horizonMedian = found.horizonMedian
                    value.parseSeconds = found.seconds
                    states[source.id] = value
                    log.append("guide \(source.name): \(found.programs.count) of your channels from \(found.guideChannels), "
                               + "read in \(Int(found.seconds)) s, half end within \(found.horizonMedian.map { ($0 - now) / 60 } ?? 0) h")
                } catch {
                    problems.append("\(source.name): \(error.localizedDescription)")
                }
            }
            // Never trade listings for shorter ones: what the last update
            // had beyond a channel's new end is kept.
            if let previous {
                var kept = 0
                for (id, old) in previous.programs {
                    let newEnd = merged[id]?.map { $0.s + $0.m }.max() ?? Int.min
                    let extra = old.filter { $0.s + 5 >= newEnd && $0.s + $0.m > now && $0.s < window.high }
                    guard !extra.isEmpty else { continue }
                    merged[id] = mergePrograms(merged[id] ?? [], extra)
                    kept += 1
                }
                if kept > 0 { log.append("guide kept the last update's later listings for \(kept) channels") }
            }
        }

        // 3. Which main sources are stale: an old file, or listings that
        // end soon (or no file at all).
        // Short listings only count where a backup can help (the free
        // streaming guides are always short and refresh often).
        var staleShards = Set<String>()
        for source in mains {
            var value = state(source)
            let old = value.lastModified.map { Date().timeIntervalSince($0) > staleAge } ?? false
            let backed = backups.contains { $0.applies(to: [source.shard]) }
            let short = backed && (value.horizonMedian.map { $0 < now + shortHorizon } ?? false)
            let missing = files[source.id] == nil
            value.stale = old || short || missing
            states[source.id] = value
            if value.stale == true { staleShards.insert(source.shard) }
        }

        // 4. Backups for the stale shards, each only filling what's missing.
        for (index, source) in backups.enumerated() {
            if Task.isCancelled { break }
            var value = state(source)
            guard source.applies(to: staleShards) else {
                value.used = false
                value.extended = 0
                states[source.id] = value
                continue
            }
            progress("Filling gaps: \(source.name) (\(index + 1) of \(backups.count))…")
            value.checkedAt = Date()
            do {
                let fetched = try await GuideFiles.fetchCached(id: source.id, url: source.url, etag: value.etag,
                                                               lastModified: value.lastModified, waitForPlayback: false)
                value.status = fetched.status
                value.bytes = fetched.bytes
                value.problem = fetched.problem
                if fetched.changed {
                    value.etag = fetched.etag
                    value.lastModified = fetched.lastModified
                    value.downloadedAt = Date()
                }
                // A wider window, so times can still be moved into it.
                let shiftRoom = source.calibrate ? 16 * 60 : 0
                let found = try await XMLTVReader.read(source: source, file: fetched.file, targets: targets,
                                                       window: (low: window.low - shiftRoom, high: window.high + shiftRoom))
                var programs = found.programs.mapValues { $0.programs }
                var perChannel: [String: Int] = [:]
                if source.calibrate {
                    let learned = learnShift(reference: merged, candidate: programs)
                    let shift = learned.shift ?? value.shift ?? source.assumedShift
                    value.shift = shift
                    value.shiftNote = learned.note + (learned.shift == nil ? "; using \(shift / 60) h" : "")
                    perChannel = learned.perChannel
                    programs = programs.reduce(into: [String: [RawProgram]]()) { out, item in
                        let delta = perChannel[item.key] ?? shift
                        let moved = item.value.compactMap { program -> RawProgram? in
                            let s = program.s - delta
                            guard s + program.m > window.low, s < window.high else { return nil }
                            return RawProgram(s: s, m: program.m, t: program.t, st: program.st, d: program.d, f: program.f)
                        }
                        if !moved.isEmpty { out[item.key] = moved }
                    }
                    log.append("guide \(source.name) clock: \(value.shiftNote ?? "")")
                }
                var extended = 0
                let tag = "\(source.name):"
                for (channelID, list) in programs {
                    let before = merged[channelID]?.map { $0.s + $0.m }.max() ?? Int.min
                    let after = mergePrograms(merged[channelID] ?? [], list)
                    guard (after.map { $0.s + $0.m }.max() ?? Int.min) > before + 30 else { continue }
                    merged[channelID] = after
                    extended += 1
                    if let entry = found.programs[channelID] {
                        let delta = perChannel[channelID] ?? value.shift ?? 0
                        let note = "\(source.name): \(entry.note)" + (delta != 0 ? ", times −\(delta / 60) h" : "")
                        notes[channelID] = notes[channelID].map { "\($0); \(note)" } ?? note
                    }
                }
                value.guideChannels = found.guideChannels
                value.matched = programs.count
                let appliedShift = value.shift ?? 0
                value.horizonMedian = found.horizonMedian.map { $0 - appliedShift }
                value.parseSeconds = found.seconds
                value.used = true
                // Counted from the notes, so fills kept from the last update count too.
                value.extended = notes.values.filter { $0.contains(tag) }.count
                log.append("guide \(source.name): \(fetched.status == 304 ? "unchanged" : fetched.status == 0 ? "saved copy" : "downloaded") "
                           + "\(fetched.bytes / 1_048_576) MB, \(programs.count) of your channels, extended \(extended) now, "
                           + "fills \(value.extended ?? 0) in all, read in \(Int(found.seconds)) s")
            } catch {
                value.problem = error.localizedDescription
                value.used = false
                log.append("guide \(source.name): failed (\(error.localizedDescription))")
            }
            states[source.id] = value
        }
        // Sources no longer in use are forgotten.
        let ids = Set(chosen.map(\.id))
        states = states.filter { ids.contains($0.key) }

        let retry = !staleShards.isEmpty
        let nextCheck = Date().addingTimeInterval(retry ? staleRetry : refreshAge)
        let ahead = merged.values.filter { ($0.map { $0.s + $0.m }.max() ?? 0) > now + shortHorizon }.count
        log.append("guide update done in \(Int(Date().timeIntervalSince(started))) s: \(merged.count) channels listed, "
                   + "\(ahead) reach 12 h+ ahead" + (retry ? "; stale: \(staleShards.sorted().joined(separator: ", ")), next check in 2 h" : ""))
        return BuildResult(programs: merged, problems: problems, notes: notes, states: states,
                           nextCheck: nextCheck, targetsKey: targetsKey, log: log)
    }

    /// The whole-hour clock shift (minutes, subtracted) that lines a source's
    /// titles up with listings already merged. Only titles that occur once
    /// on both sides of a channel count (a show that repeats would match at
    /// many offsets), and each channel casts one vote. A channel with a clear
    /// vote of its own keeps it.
    static func learnShift(reference: [String: [RawProgram]], candidate: [String: [RawProgram]],
                           sample: Int = 800) -> (shift: Int?, perChannel: [String: Int], note: String) {
        func key(_ title: String) -> String {
            let lowered = title.lowercased().rxReplace("^(live|new)[: ]+", with: "")
            return String(lowered.filter { $0.isLetter || $0.isNumber }.prefix(12))
        }
        var votes: [Int: Int] = [:]
        var perChannel: [String: Int] = [:]
        var checked = 0
        for (channel, programs) in candidate {
            guard let ref = reference[channel], !ref.isEmpty else { continue }
            checked += 1
            if checked > sample { break }
            autoreleasepool {
                var refCount: [String: Int] = [:]
                var refStart: [String: Int] = [:]
                for program in ref {
                    let k = key(program.t)
                    refCount[k, default: 0] += 1
                    refStart[k] = program.s
                }
                var candCount: [String: Int] = [:]
                for program in programs { candCount[key(program.t), default: 0] += 1 }
                var local: [Int: Int] = [:]
                for program in programs {
                    let k = key(program.t)
                    guard k.count >= 4, candCount[k] == 1, refCount[k] == 1, let start = refStart[k] else { continue }
                    let gap = program.s - start
                    let hours = Int((Double(gap) / 60).rounded())
                    if abs(gap - hours * 60) <= 10, abs(hours) <= 14 { local[hours, default: 0] += 1 }
                }
                let ranked = local.sorted { $0.value > $1.value }
                guard let top = ranked.first else { return }
                let second = ranked.dropFirst().first?.value ?? 0
                if top.value >= 2, top.value > second { votes[top.key, default: 0] += 1 }
                if top.value >= 3, top.value > 2 * second { perChannel[channel] = top.key * 60 }
            }
        }
        let ranked = votes.sorted { $0.value > $1.value }
        let summary = ranked.prefix(3).map { "\($0.key) h: \($0.value)" }.joined(separator: ", ")
        guard let top = ranked.first else {
            return (nil, [:], "no overlap to check against (\(checked) channels)")
        }
        let second = ranked.dropFirst().first?.value ?? 0
        guard top.value >= 20, top.value >= 3 * max(1, second) else {
            return (nil, [:], "unclear (\(summary))")
        }
        // Channels that disagree with the overall shift only keep theirs when clear.
        return (top.key * 60, perChannel.filter { $0.value != top.key * 60 }, "learned \(top.key) h from \(top.value) channels (\(summary))")
    }

    /// Adds `extra` programs that don't overlap `base` by more than 5 minutes.
    static func mergePrograms(_ base: [RawProgram], _ extra: [RawProgram]) -> [RawProgram] {
        guard !base.isEmpty else { return extra.sorted { $0.s < $1.s } }
        var result = base
        for program in extra {
            let end = program.s + program.m
            let clashes = result.contains { other in
                min(end, other.s + other.m) - max(program.s, other.s) > 5
            }
            if !clashes { result.append(program) }
        }
        return result.sorted { $0.s < $1.s }
    }

    /// Programs for one channel inside `from...to`. `idPrefix` "pg" marks the
    /// provider's own guide (which counts as the server's, not outside).
    static func programs(_ raw: [RawProgram], channelID: String, from: Date, to: Date,
                         idPrefix: String = "og", outside: Bool = true) -> [LiveTVProgram] {
        let low = Int(from.timeIntervalSince1970 / 60)
        let high = Int(to.timeIntervalSince1970 / 60)
        return raw.compactMap { item in
            let end = item.s + item.m
            guard end > low, item.s < high else { return nil }
            var program = LiveTVProgram(
                id: "\(idPrefix)|\(channelID)|\(item.s)",
                channelID: channelID,
                title: item.t,
                episodeTitle: item.st,
                overview: item.d,
                start: Date(timeIntervalSince1970: TimeInterval(item.s * 60)),
                end: Date(timeIntervalSince1970: TimeInterval(end * 60)),
                isMovie: item.f & 1 != 0,
                isSports: item.f & 2 != 0,
                isNews: item.f & 4 != 0,
                isKids: item.f & 8 != 0,
                isLive: item.f & 16 != 0,
                isPremiere: item.f & 32 != 0,
                imageURL: nil
            )
            program.fromOutsideGuide = outside
            // Listings saved before titles were read for genres.
            return item.f & ProgramGenre.genreBits == 0 ? ProgramGenre.withTitleFlags(program) : program
        }
    }

    // MARK: Matching

    /// The user's channels as lookup keys: call signs (from the name, or from
    /// network + city via the station directory) and normalized names.
    struct Targets {
        var bySign: [String: [String]] = [:]
        var byName: [String: [String]] = [:]
        var stationsByNetwork: [String: [Station]] = [:]

        init(channels: [LiveTVChannel], stations: [Station]) {
            let stationsByNetwork = Dictionary(grouping: stations, by: \.network)
            self.stationsByNetwork = stationsByNetwork
            for channel in channels {
                let isLocal = (channel.group ?? "").lowercased().contains("local")
                var signs = OutsideGuide.callsigns(in: channel.name, strongContext: isLocal)
                // A call sign written alone in capitals ("(US) (Prime) KAGS").
                if signs.isEmpty, let sign = ChannelCatalog.bareCallsign(channel.name) { signs = [sign] }
                if signs.isEmpty, let sign = OutsideGuide.stationCallsign(for: channel.name, stations: stationsByNetwork) {
                    signs = [sign]
                }
                // The provider's XMLTV id ("KGO.us", "ESPN.us") is another key.
                if let epg = channel.epgID {
                    signs += OutsideGuide.callsigns(in: epg, strongContext: true).filter { !signs.contains($0) }
                }
                for sign in signs { bySign[sign, default: []].append(channel.id) }
                var texts = Set([channel.displayName, channel.name])
                if let epg = channel.epgID {
                    texts.insert(epg.rxReplace("\\.[a-z]{2,3}$", with: "", caseInsensitive: true))
                }
                for text in texts {
                    let key = OutsideGuide.normalize(text)
                    if key.count >= 2 { byName[key, default: []].append(channel.id) }
                }
            }
        }

        /// The user's channels a guide channel stands for. Call signs win over
        /// names, since a call sign can't be ambiguous. `stationNames`: a
        /// network-and-city name ("5.1 CBS San Francisco") is looked up in the
        /// station directory, and its channel number must agree. `deriveWest`:
        /// an East feed also stands for the user's West feed, 3 hours later.
        func matches(names: [String], xmltvID: String, locals: Bool,
                     stationNames: Bool = false, deriveWest: Bool = false) -> [Match] {
            var found: [Match] = []
            for sign in OutsideGuide.callsigns(in: (names + [xmltvID]).joined(separator: " | "), strongContext: locals) {
                found += (bySign[sign] ?? []).map { Match(id: $0, how: "by call sign \(sign)", shift: 0) }
            }
            if !found.isEmpty { return found }
            if stationNames, !stationsByNetwork.isEmpty {
                for name in names {
                    guard let sign = OutsideGuide.stationCallsign(for: name, stations: stationsByNetwork, requireNumber: true),
                          let ids = bySign[sign] else { continue }
                    return ids.map { Match(id: $0, how: "by station \(sign)", shift: 0) }
                }
            }
            for name in names {
                let key = OutsideGuide.normalize(name)
                guard key.count >= 2 else { continue }
                found += (byName[key] ?? []).map { Match(id: $0, how: "by name", shift: 0) }
                if deriveWest, !key.hasSuffix("~west") {
                    found += (byName[key + "~west"] ?? []).map { Match(id: $0, how: "by name, West feed 3 h later", shift: 180) }
                }
            }
            return found
        }
    }

    /// Network words as they show up in IPTV channel names.
    private static let networkWords: [String: String] = [
        "abc": "ABC", "cbs": "CBS", "nbc": "NBC", "fox": "FOX", "cw": "CW",
        "mynetworktv": "MYNETWORKTV", "mytv": "MYNETWORKTV", "pbs": "PBS",
        "telemundo": "TELEMUNDO", "univision": "UNIVISION", "ion": "ION"
    ]

    /// "NBC 5 Chicago" → WMAQ: a network word plus the station's city in the
    /// name (the channel number breaks ties).
    static func stationCallsign(for name: String, stations: [String: [Station]], requireNumber: Bool = false) -> String? {
        guard !stations.isEmpty else { return nil }
        let lowered = name.lowercased()
            .rxReplace("^\\s*[^:|]{1,24}[:|]\\s*", with: "")
            // "PBS12" → "pbs 12", "[Denver]" → "denver"
            .rxReplace("([a-z])(\\d)", with: "$1 $2")
        let tokens = lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        // "NBC Sports Chicago" / "CBS News Chicago" are their own channels.
        guard !tokens.contains(where: { ["sports", "news", "network", "plus"].contains($0) }),
              let network = tokens.lazy.compactMap({ networkWords[$0] }).first,
              let candidates = stations[network] else { return nil }
        let words = Set(tokens)
        let numbers = Set(tokens.filter { $0.allSatisfy(\.isNumber) })
        var best: (sign: String, score: Int)?
        for station in candidates where station.cityTokens.allSatisfy(words.contains) {
            // Strict: a name with a channel number only matches that channel.
            if requireNumber, !numbers.isEmpty, !station.channelNumber.isEmpty, !numbers.contains(station.channelNumber) { continue }
            var score = station.cityTokens.count * 10
            if !station.channelNumber.isEmpty, numbers.contains(station.channelNumber) { score += 5 }
            if best == nil || score > best!.score { best = (station.callsign, score) }
        }
        return best?.sign
    }

    private static let callPattern = try? NSRegularExpression(
        pattern: "(?<![A-Z0-9])([KW][A-Z]{2,3})(?:[- ]?(DT|TV|LD|LP|CD|CA|HD)(\\d)?)?(?![A-Z])"
    )
    private static let callStop: Set<String> = ["WWE", "WNBA", "WEST", "WILD", "KIDS", "WORK", "WIRE", "WAVE", "WARS", "WOW", "KICK", "WINE", "WORD", "WEEK"]
    private static let dropTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "50fps", "60fps", "backup", "alt", "vip", "raw", "feed", "usa", "us", "ca", "uk", "tv",
        "east", "west", "pacific"
    ]

    /// Call signs ("WNBC", "KABC-2" for a sub-channel). A bare four-letter
    /// word only counts in a locals context, in parentheses, or with a -DT
    /// style suffix, so "WILD" or "KIDS" in a network name don't.
    static func callsigns(in text: String, strongContext: Bool) -> [String] {
        guard let callPattern else { return [] }
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        var found: [String] = []
        for match in callPattern.matches(in: upper, range: range) {
            guard let signRange = Range(match.range(at: 1), in: upper),
                  let wholeRange = Range(match.range(at: 0), in: upper) else { continue }
            let sign = String(upper[signRange])
            if callStop.contains(sign) { continue }
            let hasSuffix = match.range(at: 2).location != NSNotFound
            let digit = Range(match.range(at: 3), in: upper).map { String(upper[$0]) }
            let inParens = upper[..<wholeRange.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix("(")
            guard strongContext || hasSuffix || inParens else { continue }
            let key = (digit == nil || digit == "1") ? sign : "\(sign)-\(digit!)"
            if !found.contains(key) { found.append(key) }
        }
        return found
    }

    /// Comparable form of a channel name. East is the default feed and is
    /// dropped; West / Pacific feeds keep a marker so they never match East.
    static func normalize(_ name: String) -> String {
        var s = name.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        let west = RX.test("\\b(west|pacific)\\b", s)
        s = s.rxReplace("[\\[\\(][^\\]\\)]*[\\]\\)]", with: " ")
        s = s.rxReplace("^\\s*[^:|]{1,24}[:|]\\s*", with: "")
        let tokens = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
            .map(String.init)
            .filter { !dropTokens.contains($0) }
        let key = tokens.joined()
        return west && !key.isEmpty ? key + "~west" : key
    }
}

import Foundation
import Combine
import UIKit
import AetherEngine

/// The video behind the guide's corner preview: one `AetherEngine` (the same
/// engine Multiview tiles use, so MPEG-TS and HLS both play), with sound.
/// `LiveTVStore` decides what plays here and when; this only plays a link
/// and reports when the picture is up. A fresh engine per preview, always
/// stopped before it's let go (Aether api.md, "Stop every engine").
@MainActor
final class LiveTVPreviewPlayer: ObservableObject {
    @Published private(set) var engine: AetherEngine?
    /// The picture for the current preview is on screen.
    @Published private(set) var hasPicture = false
    @Published private(set) var failed = false
    /// Something is loaded or loading (a connection may be open).
    var isActive: Bool { engine != nil }

    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func play(url: URL, headers: [String: String] = [:]) {
        stop()
        guard let engine = try? AetherEngine() else {
            failed = true
            return
        }
        engine.logTag = "livepreview"
        engine.volume = 1
        self.engine = engine
        failed = false
        hasPicture = false
        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] ready in
                guard let self, let engine, ready, self.engine === engine else { return }
                self.hasPicture = true
            }
            .store(in: &cancellables)
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] state in
                guard let self, let engine, self.engine === engine else { return }
                switch state {
                case .error:
                    // A preview never retries on its own: no extra connections.
                    self.failed = true
                default:
                    break
                }
            }
            .store(in: &cancellables)
        let lowered = url.absoluteString.lowercased()
        let isHLS = url.pathExtension.lowercased() == "m3u8" || lowered.contains(".m3u8")
        let options = LoadOptions(
            // A preview never switches the TV's picture mode.
            suppressDisplayCriteria: true,
            httpHeaders: headers,
            matchContentEnabled: false,
            panelIsInHDRMode: UIScreen.main.currentEDRHeadroom > 1.001,
            nativeRemoteHLS: isHLS,
            autoplay: true,
            sharedOutputRole: .primary
        )
        loadTask = Task { @MainActor [weak self, weak engine] in
            guard let engine else { return }
            do {
                _ = try await engine.load(url: url, options: options)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.engine === engine else { return }
                self.failed = true
            }
        }
    }

    /// Stops the engine (closing its connection) and drops it.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        engine?.stop()
        engine = nil
        hasPicture = false
        failed = false
    }
}

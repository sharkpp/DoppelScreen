import AppKit
import CoreGraphics
import FlutterMacOS
import Observation

/// ホスト UI（Flutter、apps/host_ui）とコアの境界（docs/adr/0002-host-ui-flutter.md）。
///
/// 型と通信路は Pigeon の生成物（`HostAPI.g.swift`）で、ここが担うのは写し替えだけ。
/// **跨ぐのは状態と操作に限る。** フレームも SDP も Dart には入らない。
///
/// エンジンはプロセスの寿命で 1 つだけ作り、ウィンドウを閉じても破棄しない。
/// Flutter の Dart VM はエンジンを捨ててもプロセスから抜けず、作り直すとかえって膨らむ。
@MainActor
final class HostUIBridge {
    let engine = FlutterEngine(name: "host_ui", project: nil)

    private let session: SessionController
    private let events: HostUIEvents
    /// 状態の送信を直列にする。追い越されると古い状態で描き直してしまう
    private var sending: Task<Void, Never>?
    private var permissionWatch: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    init(session: SessionController) {
        self.session = session
        engine.run(withEntrypoint: nil)
        events = HostUIEvents(binaryMessenger: engine.binaryMessenger)
        HostUIControlSetup.setUp(binaryMessenger: engine.binaryMessenger, api: self)

        session.refreshPermission()
        watchPermission()
        // 権限はシステム設定側でいつでも変わりうる。戻ってきたときに取り直す
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session.refreshPermission()
                self?.watchPermission()
            }
        }
        observe()
    }

    // MARK: - コア → UI

    /// Observation で変化を拾うたびに、状態を丸ごと送り直す。
    /// トークンの残り時間は `SessionController` が 1 秒ごとに進めるので、ここで数えなくてよい
    private func observe() {
        let state = withObservationTracking {
            HostState(session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let previous = sending
        sending = Task { [events] in
            await previous?.value
            // Dart がまだ購読していなければ失敗する。起動直後の Dart は `currentState` で取りに来る
            try? await events.stateChanged(state: state)
        }
    }

    /// 未許可の間だけ 1 秒ごとに確かめる。許可されたら画面の一覧を取る
    private func watchPermission() {
        guard permissionWatch == nil else { return }
        permissionWatch = Task { [weak self] in
            while let session = self?.session, !session.permissionGranted, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                session.refreshPermission()
            }
            self?.session.refreshDisplays()
            self?.permissionWatch = nil
        }
    }

    private func stream(_ displayID: Int64) -> DisplayStream? {
        guard let id = CGDirectDisplayID(exactly: displayID) else { return nil }
        return session.streams.first { $0.id == id }
    }
}

// MARK: - UI → コア

/// Pigeon はプラットフォームのスレッド（= メインスレッド）から呼ぶ。
/// 生成されるプロトコルが隔離を持たないため、実行時に確かめる形で MainActor に寄せる
extension HostUIBridge: @preconcurrency HostUIControl {
    func currentState() throws -> HostState { HostState(session) }

    func startServing() throws { session.startServing() }
    func stopServing() throws { session.stopServing() }
    func regenerateToken() throws { session.regenerateToken() }

    func approve(displayId: Int64) throws { stream(displayId)?.approve() }
    func reject(displayId: Int64) throws { stream(displayId)?.reject() }
    func disconnect(displayId: Int64) throws { stream(displayId)?.disconnect() }

    func requestPermission() throws { session.requestPermission() }
    func openPermissionSettings() throws { ScreenRecordingPermission.openSystemSettings() }
    func relaunch() throws { ScreenRecordingPermission.relaunch() }
}

// MARK: - 写し替え

extension HostState {
    @MainActor
    init(_ session: SessionController) {
        let (server, failure): (ServerStatus, String?) = switch session.serverState {
        case .idle: (.idle, nil)
        case .starting: (.starting, nil)
        case .running: (.running, nil)
        case .failed(let message): (.failed, message)
        }
        let permission: ScreenPermission = if session.permissionGranted {
            .granted
        } else if session.hasRequestedPermissionBefore {
            .requestedBefore
        } else {
            .notRequested
        }
        self.init(
            permission: permission,
            server: server,
            serverFailure: failure,
            token: session.pairingSnapshot.token,
            tokenRemainingSeconds: session.pairingSnapshot.remaining.components.seconds,
            tokenRegeneratedAfterFailures: session.pairingSnapshot.regeneratedAfterFailures,
            certificateError: session.certificateError,
            streams: session.streams.map { DisplayStreamState($0, endpoints: session.endpoints(for: $0.id)) }
        )
    }
}

extension DisplayStreamState {
    @MainActor
    init(_ stream: DisplayStream, endpoints: [SessionController.Endpoint]) {
        let (status, peer, failure): (StreamStatus, String?, String?) = switch stream.state {
        case .idle: (.idle, nil, nil)
        case .awaitingApproval(let address): (.awaitingApproval, address, nil)
        case .starting(let address): (.starting, address, nil)
        case .streaming(let address): (.streaming, address, nil)
        case .failed(let reason): (.failed, nil, reason)
        }
        let active: ScreenCapturer.Configuration? = if case .streaming = stream.state {
            stream.activeConfiguration
        } else {
            nil
        }
        self.init(
            displayId: Int64(stream.id),
            name: stream.display.name,
            pixelWidth: Int64(stream.display.pixelWidth),
            pixelHeight: Int64(stream.display.pixelHeight),
            status: status,
            peerAddress: peer,
            failure: failure,
            activeWidth: active.map { Int64($0.width) },
            activeHeight: active.map { Int64($0.height) },
            quality: StreamQuality(stream.quality),
            endpoints: endpoints.map {
                EndpointState(interfaceName: $0.interfaceName, url: $0.url, secureUrl: $0.secureURL)
            }
        )
    }
}

extension StreamQuality {
    init(_ preset: QualityPreset) {
        self = switch preset {
        case .sharp: .sharp
        case .balanced: .balanced
        case .smooth: .smooth
        }
    }
}

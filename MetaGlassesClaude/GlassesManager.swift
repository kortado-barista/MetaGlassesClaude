// GlassesManager.swift
// Wraps the Meta Wearables Device Access Toolkit (DAT) iOS SDK.

import Foundation
import UIKit
import AVFoundation
import VideoToolbox
import Combine
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {

    @Published var connectionState: DATConnectionState = .disconnected
    @Published var isConnected = false
    @Published var latestFrame: UIImage?
    @Published var registrationState: RegistrationState = .unavailable
    @Published var errorMessage: String?

    private var wearables: any WearablesInterface { MWDATCore.Wearables.shared }
    private var streamSession: StreamSession?
    private var listenerTokens: [any AnyListenerToken] = []
    private var isCameraStarting = false
    private let hevcDecoder = HEVCDecoder()
    private var registeredDeviceListeners: Set<String> = []

    // MARK: - Setup

    func setup() async {
        do {
            try MWDATCore.Wearables.configure()
            print("[DAT] configure() succeeded")
        } catch {
            print("[DAT] configure() threw: \(error)")
        }

        print("[DAT] setup() initial registrationState=\(wearables.registrationState.rawValue)")
        let regToken = wearables.addRegistrationStateListener { [weak self] state in
            print("[DAT] registrationState changed -> \(state.rawValue)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registrationState = state
                if state == .registered {
                    print("[DAT] registered! checking devices: \(self.wearables.devices)")
                    self.handleDevicesChanged(self.wearables.devices)
                }
            }
        }
        listenerTokens.append(regToken)

        // Observe device list changes
        let devToken = wearables.addDevicesListener { [weak self] devices in
            Task { @MainActor [weak self] in
                self?.handleDevicesChanged(devices)
            }
        }
        listenerTokens.append(devToken)

        // Handle already-paired devices at launch
        handleDevicesChanged(wearables.devices)
    }

    // MARK: - Registration

    /// Call this when the user taps "Connect" and glasses aren't registered yet.
    func startRegistration() async {
        print("[DAT] calling startRegistration()")
        do {
            try await wearables.startRegistration()
            print("[DAT] startRegistration() returned")
        } catch {
            print("[DAT] startRegistration() error: \(error)")
            errorMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    /// Forward deep-link URLs from the Meta AI app back to the SDK (for OAuth).
    func handleOpenURL(_ url: URL) async {
        print("[DAT] handleOpenURL: \(url)")
        _ = try? await wearables.handleUrl(url)
    }

    // MARK: - Connection

    func startConnecting() {
        print("[DAT] startConnecting() registrationState=\(wearables.registrationState.rawValue) devices=\(wearables.devices)")
        connectionState = .connecting

        if wearables.registrationState == .registered {
            handleDevicesChanged(wearables.devices)
        } else {
            Task { await startRegistration() }
        }
    }

    /// Uses AutoDeviceSelector to connect without going through the registration/OAuth flow.
    /// This is the path for Developer Mode testing.
    private func startCameraWithAutoSelector() async {
        print("[DAT] trying AutoDeviceSelector")
        let selector = AutoDeviceSelector(wearables: wearables)
        let config = StreamSessionConfig(videoCodec: .hvc1, resolution: .medium, frameRate: 15)
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)

        let stateToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
            print("[DAT] StreamSession state -> \(state)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .streaming:
                    self.connectionState = .connected
                    self.isConnected = true
                case .stopped, .stopping:
                    self.connectionState = .disconnected
                    self.isConnected = false
                case .waitingForDevice:
                    self.connectionState = .scanning
                default:
                    break
                }
            }
        }
        listenerTokens.append(stateToken)

        let decoder = hevcDecoder
        decoder.onDecodedFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                self?.latestFrame = image
            }
        }
        let frameToken = session.videoFramePublisher.listen { (frame: VideoFrame) in
            decoder.feed(frame.sampleBuffer)
        }
        listenerTokens.append(frameToken)

        let errorToken = session.errorPublisher.listen { [weak self] (err: StreamSessionError) in
            print("[DAT] StreamSession error: \(err)")
            Task { @MainActor [weak self] in
                self?.errorMessage = "Camera error: \(err)"
            }
        }
        listenerTokens.append(errorToken)

        streamSession = session
        await session.start()
    }

    func disconnect() {
        Task { await streamSession?.stop() }
        streamSession = nil
        isCameraStarting = false
        connectionState = .disconnected
        isConnected = false
        hevcDecoder.invalidateSession()
        registeredDeviceListeners.removeAll()
    }

    // MARK: - Camera

    private func startCamera(for deviceId: DeviceIdentifier) async {
        guard !isCameraStarting, streamSession == nil else {
            print("[DAT] startCamera skipped — already starting or active (isCameraStarting=\(isCameraStarting), streamSession=\(streamSession != nil))")
            return
        }
        isCameraStarting = true
        defer { isCameraStarting = false }
        print("[DAT] startCamera(for:) BEGIN deviceId=\(deviceId)")

        // Check camera permission first, request if not granted
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            print("[DAT] camera permission status: \(status)")
            if status != .granted {
                print("[DAT] requesting camera permission...")
                status = try await wearables.requestPermission(.camera)
                print("[DAT] camera permission after request: \(status)")
            }
            guard status == .granted else {
                print("[DAT] camera permission NOT granted, aborting")
                errorMessage = "Camera permission denied. Please grant camera access in the Meta AI app."
                return
            }
        } catch {
            print("[DAT] permission error: \(error)")
            errorMessage = "Permission error: \(error.localizedDescription)"
            return
        }

        print("[DAT] creating StreamSession with SpecificDeviceSelector + .hvc1 codec")
        let selector = SpecificDeviceSelector(device: deviceId)
        let config = StreamSessionConfig(videoCodec: .hvc1, resolution: .medium, frameRate: 15)
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)

        let stateToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
            print("[DAT] startCamera statePublisher -> \(state)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .streaming:
                    self.connectionState = .connected
                    self.isConnected = true
                case .stopped, .stopping:
                    if self.streamSession === session {
                        self.connectionState = .disconnected
                        self.isConnected = false
                        self.streamSession = nil
                    }
                default:
                    break
                }
            }
        }
        listenerTokens.append(stateToken)

        let decoder2 = hevcDecoder
        decoder2.onDecodedFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                self?.latestFrame = image
            }
        }
        let frameToken = session.videoFramePublisher.listen { (frame: VideoFrame) in
            decoder2.feed(frame.sampleBuffer)
        }
        listenerTokens.append(frameToken)

        let errorToken = session.errorPublisher.listen { [weak self] (err: StreamSessionError) in
            print("[DAT] startCamera errorPublisher: \(err)")
            Task { @MainActor [weak self] in
                self?.errorMessage = "Camera error: \(err)"
            }
        }
        listenerTokens.append(errorToken)

        streamSession = session
        print("[DAT] calling session.start()")
        await session.start()
        print("[DAT] session.start() returned")
    }

    func captureCurrentFrame() -> UIImage? {
        return latestFrame
    }

    // MARK: - Private

    private func handleDevicesChanged(_ deviceIds: [DeviceIdentifier]) {
        guard let firstId = deviceIds.first,
              let device = wearables.deviceForIdentifier(firstId) else {
            connectionState = .disconnected
            isConnected = false
            return
        }

        updateConnectionState(device.linkState, deviceId: firstId)

        let idString = "\(firstId)"
        guard !registeredDeviceListeners.contains(idString) else { return }
        registeredDeviceListeners.insert(idString)

        let token = device.addLinkStateListener { [weak self] linkState in
            Task { @MainActor [weak self] in
                self?.updateConnectionState(linkState, deviceId: firstId)
            }
        }
        listenerTokens.append(token)
    }

    private func updateConnectionState(_ linkState: LinkState, deviceId: DeviceIdentifier) {
        switch linkState {
        case .disconnected:
            connectionState = .disconnected
            isConnected = false
            Task { await streamSession?.stop() }
            streamSession = nil
            hevcDecoder.invalidateSession()
        case .connecting:
            connectionState = .connecting
            isConnected = false
        case .connected:
            connectionState = .connected
            isConnected = true
            Task { await startCamera(for: deviceId) }
        }
    }
}

// MARK: - HEVC Decoder

/// C-compatible callback required by VTDecompressionSession.
/// `refCon` points to the HEVCDecoder instance (unretained).
private func vtOutputCallback(
    refCon: UnsafeMutableRawPointer?,
    frameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    pts: CMTime,
    duration: CMTime
) {
    guard status == noErr, let imageBuffer, let refCon else { return }
    let decoder = Unmanaged<HEVCDecoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(imageBuffer)
}

/// Async (non-blocking) HEVC decoder.
/// `feed()` enqueues each sample buffer to VideoToolbox without waiting.
/// Decoded frames are delivered via `onDecodedFrame` on VT's internal thread.
final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private let ciContext = CIContext()
    private var decodeCount = 0

    /// Called on VT's callback thread for every successfully decoded frame.
    /// Throttled to ~15fps display (every other frame).
    var onDecodedFrame: ((UIImage) -> Void)?

    /// Feed an HEVC sample buffer to VideoToolbox — returns immediately.
    func feed(_ sampleBuffer: CMSampleBuffer) {
        if session == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
            var cb = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: vtOutputCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: fmt,
                decoderSpecification: nil,
                imageBufferAttributes: attrs,
                outputCallback: &cb,
                decompressionSessionOut: &session
            )
            if status != noErr {
                print("[HEVCDecoder] VTDecompressionSessionCreate failed: \(status)")
                return
            }
        }
        guard let session else { return }
        var flags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flags
        )
        // No Wait — returns immediately, callback fires on VT's thread
    }

    /// Called from `vtOutputCallback` on VT's internal thread.
    func handleDecoded(_ imageBuffer: CVImageBuffer) {
        decodeCount += 1
        // Display every other decoded frame (~15fps at 30fps input, ~7fps at 15fps input)
        guard decodeCount % 2 == 0 else { return }
        let ci = CIImage(cvPixelBuffer: imageBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)
        onDecodedFrame?(image)
    }

    /// Invalidate the VT session so it is recreated on the next frame (call on reconnect/disconnect).
    func invalidateSession() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        decodeCount = 0
    }
}

// MARK: - DATConnectionState

enum DATConnectionState {
    case disconnected
    case scanning
    case connecting
    case connected
    case error(Error)

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let err): return "Error: \(err.localizedDescription)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

import AppKit
import ScreenCaptureKit
import AVFoundation

struct RecordingOptions: Sendable {
    var systemAudio = true
    var microphone = false
    var showsCursor = true
    var framesPerSecond = 30
    /// Zero keeps the display's native pixel resolution (capped at 4K for H.264).
    var maximumHeight = 1080
}

enum RecordingError: LocalizedError {
    case microphoneDenied, noFrames, encodingFailed, invalidRegion
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 Snaplet。"
        case .noFrames: "未收到录屏画面。请检查屏幕录制权限并重新开始。"
        case .encodingFailed: "视频编码失败，请检查可用磁盘空间后重试。"
        case .invalidRegion: "录制区域无效，请重新选择。"
        }
    }
}

/// All sample sources share the host clock. Paused intervals are removed from both audio and video.
struct RecordingTimeline {
    private(set) var origin: CMTime?
    private(set) var pausedAt: CMTime?
    private(set) var removed = CMTime.zero

    mutating func start(at time: CMTime) { if origin == nil { origin = time } }
    mutating func pause(at time: CMTime) { if pausedAt == nil { pausedAt = time } }
    mutating func resume(at time: CMTime) {
        if let pausedAt { removed = removed + time - pausedAt; self.pausedAt = nil }
    }
    func position(at time: CMTime) -> CMTime? {
        guard let origin, pausedAt == nil else { return nil }
        let result = time - origin - removed
        return result >= .zero ? result : nil
    }
    func end(at time: CMTime) -> CMTime {
        guard let origin else { return .zero }
        return CMTimeMaximum(.zero, (pausedAt ?? time) - origin - removed)
    }
}

enum RecordingGeometry {
    static func size(selection: CGRect, scale: CGFloat, maximumHeight: Int) -> CGSize {
        let native = CGSize(width: selection.width * scale, height: selection.height * scale)
        let limit = maximumHeight == 0 ? 2160 : maximumHeight
        let ratio = min(1, CGFloat(limit) / native.height, 3840 / native.width)
        // H.264 needs even pixel dimensions.
        return CGSize(width: max(2, floor(native.width * ratio / 2) * 2),
                      height: max(2, floor(native.height * ratio / 2) * 2))
    }
}

@MainActor
final class RecordingService {
    private var stream: SCStream?
    private var microphone: MicrophoneCapture?
    private var sink: RecordingSink?

    func start(screen: NSScreen, rect: CGRect, options: RecordingOptions, url: URL,
               onFailure: @escaping @MainActor @Sendable (Error) -> Void) async throws {
        guard rect.width >= 2, rect.height >= 2 else { throw RecordingError.invalidRegion }
        if options.microphone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw RecordingError.microphoneDenied }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        // Exclude this application, including controls created after the filter is built.
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let size = RecordingGeometry.size(selection: rect, scale: screen.backingScaleFactor,
                                           maximumHeight: options.maximumHeight)
        let config = SCStreamConfiguration()
        config.sourceRect = CaptureGeometry.sourceRect(selection: rect, screenSize: screen.frame.size)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.framesPerSecond))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let sink = try RecordingSink(url: url, size: size, options: options, onFailure: onFailure)
        self.sink = sink
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        self.stream = stream
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if options.systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            if options.microphone {
                let session = AVCaptureSession()
                session.beginConfiguration()
                guard let device = AVCaptureDevice.default(for: .audio) else { throw RecordingError.microphoneDenied }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else { throw RecordingError.encodingFailed }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(sink, queue: sink.queue)
                session.commitConfiguration()
                microphone = MicrophoneCapture(session: session)
            }
            try await stream.startCapture()
            if let microphone {
                // AVCaptureSession.startRunning is blocking; keep it off the UI thread.
                await microphone.start()
            }
        } catch {
            try? await stream.stopCapture()
            await cancel()
            throw error
        }
    }

    func setPaused(_ paused: Bool) async { await sink?.setPaused(paused) }

    func stop() async throws -> URL {
        guard let sink else { throw RecordingError.noFrames }
        // Use the time of the user's stop, rather than the latency of stopping capture.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let stream = self.stream
        self.stream = nil
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        if let microphone { await microphone.stop() }
        self.microphone = nil
        self.sink = nil
        // Even on a capture interruption, finalize frames already received.
        let result = try await sink.finish(at: end)
        if let stopError { NSLog("Capture stopped with error; recovered recording: %@", stopError.localizedDescription) }
        return try await Self.mixAudioIfNeeded(at: result)
    }

    static func mixAudioIfNeeded(at url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1 else { return url }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.encodingFailed
        }
        let mixed = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        exporter.outputURL = mixed
        exporter.outputFileType = .mp4
        exporter.audioMix = mix
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: mixed)
            throw exporter.error ?? RecordingError.encodingFailed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: mixed)
        return url
    }

    func cancel() async {
        if let microphone { await microphone.stop() }
        microphone = nil
        await sink?.cancel()
        sink = nil
        stream = nil
    }
}

/// Mutable writer state is confined to `queue`, including stop, pause, and all capture callbacks.
final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.snaplet.recording.writer")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let url: URL
    private let fps: Int
    private var timeline = RecordingTimeline()
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = CMTime.zero
    private var acceptedTimes: [ObjectIdentifier: CMTime] = [:]
    private var finishing = false
    private var failure: Error?
    private let onFailure: @MainActor @Sendable (Error) -> Void

    init(url: URL, size: CGSize, options: RecordingOptions,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void) throws {
        self.url = url
        self.fps = options.framesPerSecond
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height) * 6,
                AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2]
        ])
        video.expectsMediaDataInRealTime = true
        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudio = options.systemAudio ? audioInput() : nil
        microphone = options.microphone ? audioInput() : nil
        super.init()
        for input in [video, systemAudio, microphone].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw RecordingError.encodingFailed }
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            append(sampleBuffer, to: video, isVideo: true)
        case .audio: if let systemAudio { append(sampleBuffer, to: systemAudio, isVideo: false) }
        default: break
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let microphone { append(sampleBuffer, to: microphone, isVideo: false) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.report(error) }
    }
    private func report(_ error: Error) {
        guard failure == nil, !finishing else { return }
        failure = error
        Task { @MainActor in onFailure(error) }
    }
    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, isVideo: Bool) {
        guard !finishing, timeline.pausedAt == nil, writer.status == .writing else {
            if writer.status == .failed { report(writer.error ?? RecordingError.encodingFailed) }
            return
        }
        let time = sample.presentationTimeStamp
        if isVideo { timeline.start(at: time) }
        guard let position = timeline.position(at: time), input.isReadyForMoreMediaData else { return }
        do {
            let key = ObjectIdentifier(input)
            if let previous = acceptedTimes[key], position <= previous { return }
            let retimed = try Self.retime(sample, offset: time - position)
            guard input.append(retimed) else { report(writer.error ?? RecordingError.encodingFailed); return }
            acceptedTimes[key] = position
            if isVideo { lastVideo = retimed; lastVideoTime = position }
        } catch { report(error) }
    }
    static func retime(_ sample: CMSampleBuffer, offset: CMTime) throws -> CMSampleBuffer {
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr else { throw RecordingError.encodingFailed }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        guard status == noErr else { throw RecordingError.encodingFailed }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset }
        }
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result)
        guard status == noErr, let result else { throw RecordingError.encodingFailed }
        return result
    }
    enum Source: Sendable { case video, systemAudio, microphone }
    /// Enqueue a retained media sample onto the same serialized path used by capture callbacks.
    func enqueue(_ sample: CMSampleBuffer, source: Source) async {
        let buffer = SendableSample(sample: sample)
        await withCheckedContinuation { continuation in
            queue.async {
                let input: AVAssetWriterInput?
                switch source {
                case .video: input = self.video
                case .systemAudio: input = self.systemAudio
                case .microphone: input = self.microphone
                }
                if let input { self.append(buffer.sample, to: input, isVideo: source == .video) }
                continuation.resume()
            }
        }
    }
    func setPaused(_ paused: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if paused { self.timeline.pause(at: now) } else { self.timeline.resume(at: now) }
                continuation.resume()
            }
        }
    }
    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishing = true
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                continuation.resume()
            }
        }
    }
    func finish(at time: CMTime) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishing = true
                guard let last = self.lastVideo, self.writer.status == .writing else {
                    let error = self.writer.error ?? self.failure ?? RecordingError.noFrames
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    continuation.resume(throwing: error)
                    return
                }
                let end = CMTimeMaximum(self.timeline.end(at: time), self.lastVideoTime + CMTime(value: 1, timescale: Int32(self.fps)))
                // ScreenCaptureKit sends no complete frames while the desktop is static.
                // Extend the final image to the user's stop time, including silent recordings.
                if self.video.isReadyForMoreMediaData, end > self.lastVideoTime,
                   let tail = try? Self.retime(last, offset: self.lastVideoTime - end) {
                    if !self.video.append(tail) { self.failure = self.writer.error ?? RecordingError.encodingFailed }
                }
                self.writer.endSession(atSourceTime: end)
                self.video.markAsFinished()
                self.systemAudio?.markAsFinished()
                self.microphone?.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume(returning: self.url) }
                    else {
                        try? FileManager.default.removeItem(at: self.url)
                        continuation.resume(throwing: self.writer.error ?? RecordingError.encodingFailed)
                    }
                }
            }
        }
    }
}

/// Session configuration finishes before this wrapper owns it. Running operations are serialized.
private final class MicrophoneCapture: @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "dev.snaplet.recording.microphone")
    init(session: AVCaptureSession) { self.session = session }
    func start() async {
        await withCheckedContinuation { continuation in
            queue.async { self.session.startRunning(); continuation.resume() }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.session.stopRunning(); continuation.resume() }
        }
    }
}

/// Retained buffers are immutable while crossing into the writer queue.
private struct SendableSample: @unchecked Sendable { let sample: CMSampleBuffer }

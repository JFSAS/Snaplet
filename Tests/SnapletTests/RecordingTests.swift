import XCTest
import AppKit
import AVFoundation
@testable import Snaplet

final class RecordingTests: XCTestCase {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48000) }

    func testPausesRemoveSameIntervalsFromAudioAndVideo() throws {
        var timeline = RecordingTimeline()
        timeline.start(at: time(100))
        XCTAssertNil(timeline.position(at: time(99)))
        XCTAssertEqual(try XCTUnwrap(timeline.position(at: time(102))).seconds, 2, accuracy: 0.001)
        timeline.pause(at: time(103))
        timeline.pause(at: time(104)) // Repeated pause does not move the boundary.
        XCTAssertNil(timeline.position(at: time(105)))
        XCTAssertEqual(timeline.end(at: time(108)).seconds, 3, accuracy: 0.001)
        timeline.resume(at: time(108))
        XCTAssertEqual(try XCTUnwrap(timeline.position(at: time(109))).seconds, 4, accuracy: 0.001)
        timeline.pause(at: time(110))
        timeline.resume(at: time(113))
        XCTAssertEqual(try XCTUnwrap(timeline.position(at: time(114))).seconds, 6, accuracy: 0.001)
    }

    func testResolutionKeepsAspectRatioAndEvenEncoderDimensions() {
        let size = RecordingGeometry.size(selection: CGRect(x: 10, y: 20, width: 1513, height: 901), scale: 2, maximumHeight: 1080)
        XCTAssertEqual(size.height, 1080)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(size.width / size.height, 1513.0 / 901, accuracy: 0.002)
        XCTAssertEqual(RecordingGeometry.size(selection: CGRect(x: 0, y: 0, width: 101, height: 51), scale: 1, maximumHeight: 1080), CGSize(width: 100, height: 50))
        let large = RecordingGeometry.size(selection: CGRect(x: 0, y: 0, width: 6000, height: 3000), scale: 2, maximumHeight: 0)
        XCTAssertLessThanOrEqual(large.width, 3840)
        XCTAssertLessThanOrEqual(large.height, 2160)
    }

    private func sample(at timestamp: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(image) * 48)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testRetimingPreservesFrameAndDuration() throws {
        let original = try sample(at: time(100))
        let result = try RecordingSink.retime(original, offset: time(97))
        XCTAssertEqual(result.presentationTimeStamp.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(result.duration.seconds, original.duration.seconds, accuracy: 0.001)
        XCTAssertTrue(result.decodeTimeStamp.isValid == false)
        XCTAssertNotNil(result.imageBuffer)
    }

    func testStaticRecordingWritesPlayableMP4ThroughStopTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("static.mp4")
        let sink = try RecordingSink(url: url, size: CGSize(width: 64, height: 48),
            options: RecordingOptions(systemAudio: true), onFailure: { _ in })
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        await sink.enqueue(try sample(at: origin), source: .video)
        _ = try await sink.finish(at: origin + time(3))
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer()?.imageBuffer)
    }

    @MainActor
    func testRecordingSelectionConfirmsRegionAndHidesScreenshotActions() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            image: try XCTUnwrap(context.makeImage()), screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            candidates: [], recording: true)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let region = CGRect(x: 50, y: 100, width: 400, height: 300)
        view.restoreSelection(region, annotations: AnnotationDocument())
        view.layoutSubtreeIfNeeded()
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(view).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(Set(buttons.compactMap { $0.accessibilityLabel() }), Set(["重新框选", "取消", "开始录制"]))
        var confirmed: CGRect?
        view.onAction = { rect, _, document in confirmed = rect; XCTAssertTrue(document.items.isEmpty) }
        try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "开始录制" }).performClick(nil)
        XCTAssertEqual(confirmed, region)
        var cancelled = false
        view.onCancel = { cancelled = true }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertTrue(cancelled)
    }

    private func audioSample(at timestamp: CMTime, frequency: Double) throws -> CMSampleBuffer {
        let frames = 4800
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        let angularStep = frequency * 2.0 * Double.pi / 48000.0
        let samples: [Float] = (0..<(frames * 2)).map { index in
            Float(sin(Double(index / 2) * angularStep) * 0.1)
        }
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Float>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        samples.withUnsafeBytes { raw in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: data,
                offsetIntoDestination: 0, dataLength: bytes), noErr)
        }
        var result: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: data, formatDescription: try XCTUnwrap(format), sampleCount: frames,
            presentationTimeStamp: timestamp, packetDescriptions: nil, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    func testSystemAndMicrophoneAudioExportAsOnePlayableMixedTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mixed.mp4")
        let sink = try RecordingSink(url: url, size: CGSize(width: 64, height: 48),
            options: RecordingOptions(systemAudio: true, microphone: true), onFailure: { _ in })
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        await sink.enqueue(try sample(at: origin), source: .video)
        for index in 0..<10 {
            let timestamp = origin + time(Double(index) / 10)
            await sink.enqueue(try audioSample(at: timestamp, frequency: 440), source: .systemAudio)
            await sink.enqueue(try audioSample(at: timestamp, frequency: 880), source: .microphone)
        }
        _ = try await sink.finish(at: origin + time(1))
        _ = try await RecordingService.mixAudioIfNeeded(at: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer()?.dataBuffer)
    }

    func testEmptyRecordingFailsAndRemovesPartialFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let sink = try RecordingSink(url: url, size: CGSize(width: 64, height: 48),
            options: RecordingOptions(systemAudio: false), onFailure: { _ in })
        do { _ = try await sink.finish(at: time(100)); XCTFail("Expected no frames error") }
        catch { XCTAssertEqual(error as? RecordingError, .noFrames) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

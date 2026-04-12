import XCTest
@testable import mslCore
@testable import MSLDesktop

final class MemoryGraphModelTests: XCTestCase {
    func testHostVMMSegmentIsLeftmost() {
        let model = MemoryGraphModel(memory: sampleMemory())

        XCTAssertEqual(model.segments.first?.kind, .hostVMM)
        XCTAssertEqual(model.segments.first?.startFraction, 0)
    }

    func testLinuxGuideStartsAfterHostVMMAndEndsAtFullWidth() {
        let model = MemoryGraphModel(memory: sampleMemory())
        let expectedStart = Double(model.hostVMMBytes) / Double(model.totalBytes)

        XCTAssertEqual(model.linuxGuide.startFraction, expectedStart, accuracy: 0.0001)
        XCTAssertEqual(model.linuxGuide.endFraction, 1, accuracy: 0.0001)
    }

    func testMacGuideEndsBeforeReturnedMemory() {
        let model = MemoryGraphModel(memory: sampleMemory())
        let expectedEnd = Double(model.macUsageBytes) / Double(model.totalBytes)

        XCTAssertEqual(model.macGuide.startFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(model.macGuide.endFraction, expectedEnd, accuracy: 0.0001)
    }

    func testHostVMMUsesHostResidentBytes() {
        let model = MemoryGraphModel(memory: sampleMemory())

        XCTAssertEqual(model.hostVMMBytes, 4608)
    }

    func testGuestUsedClampsAtZeroAfterKernelSubtraction() {
        let memory = RuntimeMemoryBreakdown(
            guestVisibleMemoryBytes: 1024,
            guestUsedBytes: 300,
            guestAvailableBytes: 724,
            kernelBufferCacheBytes: 200,
            kernelOtherBytes: 200,
            balloonTargetBytes: 1024,
            balloonMaxBytes: 1024,
            balloonReturnedTotalBytes: 0,
            hostResidentMemoryBytes: 1024
        )

        let model = MemoryGraphModel(memory: memory)
        XCTAssertEqual(model.guestUsedBytes, 0)
    }

    func testReturnedBytesUsesBalloonMaxMinusTarget() {
        let model = MemoryGraphModel(memory: sampleMemory())
        XCTAssertEqual(model.returnedBytes, 1024)
        XCTAssertEqual(model.availableMemoryBytes, 1024)
    }

    func testHostVMMFallsBackToZeroWhenResidentIsMissing() {
        let memory = RuntimeMemoryBreakdown(
            guestVisibleMemoryBytes: 2048,
            guestUsedBytes: 1024,
            guestAvailableBytes: 1024,
            kernelBufferCacheBytes: 128,
            kernelOtherBytes: 128,
            balloonTargetBytes: 2048,
            balloonMaxBytes: 3072,
            balloonReturnedTotalBytes: 0,
            hostResidentMemoryBytes: nil
        )

        let model = MemoryGraphModel(memory: memory)
        XCTAssertEqual(model.hostVMMBytes, 0)
    }

    func testReturnedBytesCanBeZero() {
        let memory = RuntimeMemoryBreakdown(
            guestVisibleMemoryBytes: 2048,
            guestUsedBytes: 1024,
            guestAvailableBytes: 1024,
            kernelBufferCacheBytes: 128,
            kernelOtherBytes: 128,
            balloonTargetBytes: 2048,
            balloonMaxBytes: 2048,
            balloonReturnedTotalBytes: 0,
            hostResidentMemoryBytes: 2560
        )

        let model = MemoryGraphModel(memory: memory)
        XCTAssertEqual(model.returnedBytes, 0)
        XCTAssertEqual(model.macGuide.endFraction, 1, accuracy: 0.0001)
    }

    func testGuideLabelsUseRequestedSummaryText() {
        let model = MemoryGraphModel(memory: sampleMemory())

        XCTAssertTrue(model.linuxGuide.label.contains("Visible Memory"))
        XCTAssertTrue(model.linuxGuide.label.contains("Available Memory"))
        XCTAssertTrue(model.macGuide.label.contains("Memory Usage in macOS"))
        XCTAssertTrue(model.macGuide.label.contains("Linux VM"))
    }

    func testVisualWidthsApplyMinimumWidthToTinyPositiveSegments() {
        let model = MemoryGraphModel(memory: sampleMemory())
        let widths = model.visualWidths(totalWidth: 200, minimumWidth: 8)

        XCTAssertGreaterThanOrEqual(widths[.hostVMM] ?? 0, 8)
    }

    func testVisualFramesReachGuestUsedRightEdgeForMacGuide() throws {
        let model = MemoryGraphModel(memory: sampleMemory())
        let frames = model.visualFrames(totalWidth: 200, minimumWidth: 8)
        let guestUsedEnd = try XCTUnwrap(frames[.guestUsed]?.end)
        let returnedStart = try XCTUnwrap(frames[.returned]?.start)
        let kernelStart = try XCTUnwrap(frames[.kernel]?.start)
        let hostVMMEnd = try XCTUnwrap(frames[.hostVMM]?.end)

        XCTAssertEqual(guestUsedEnd, returnedStart, accuracy: 0.0001)
        XCTAssertEqual(kernelStart, hostVMMEnd, accuracy: 0.0001)
    }

    private func sampleMemory() -> RuntimeMemoryBreakdown {
        RuntimeMemoryBreakdown(
            guestVisibleMemoryBytes: 4096,
            guestUsedBytes: 2048,
            guestAvailableBytes: 2048,
            kernelBufferCacheBytes: 256,
            kernelOtherBytes: 512,
            balloonTargetBytes: 4096,
            balloonMaxBytes: 5120,
            balloonReturnedTotalBytes: 1024,
            hostResidentMemoryBytes: 4608
        )
    }
}

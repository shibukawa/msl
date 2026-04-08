import XCTest
import Darwin
@testable import mslCore

final class AttachedContainerInspectShapeTests: XCTestCase {
    func testAdvertisedDockerAPIVersionSupportsExecEnv() {
        XCTAssertEqual(attachedDockerAPIVersion, "1.51")
        XCTAssertEqual(attachedDockerMinAPIVersion, "1.44")
    }

    func testInspectJSONIncludesNetworkSettingsPorts() {
        let descriptor = AttachedContainerDescriptor(
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            name: "msl-ubuntu",
            image: "msl/ubuntu",
            running: true,
            platform: "linux",
            defaultUser: "shibukawayoshiki",
            defaultHome: "/home/shibukawayoshiki",
            defaultShell: "/bin/bash"
        )

        let body = descriptor.inspectJSON(execIDs: [])
        let networkSettings = body["NetworkSettings"] as? [String: Any]
        let hostConfig = body["HostConfig"] as? [String: Any]
        let config = body["Config"] as? [String: Any]
        let state = body["State"] as? [String: Any]
        let env = config?["Env"] as? [String]
        let networks = networkSettings?["Networks"] as? [String: Any]

        XCTAssertEqual(body["Name"] as? String, "/msl-ubuntu")
        XCTAssertEqual((body["Id"] as? String)?.count, 64)
        XCTAssertNotNil(body["Created"] as? String)
        XCTAssertEqual(body["Driver"] as? String, "overlayfs")
        XCTAssertEqual(body["RestartCount"] as? Int, 0)
        XCTAssertTrue(body["ExecIDs"] is NSNull)
        XCTAssertNotNil(networkSettings)
        XCTAssertNotNil(networkSettings?["Ports"])
        XCTAssertNotNil(networkSettings?["Bridge"])
        XCTAssertNotNil(networks?["bridge"])
        XCTAssertNotNil(hostConfig?["PortBindings"])
        XCTAssertNotNil(hostConfig?["LogConfig"])
        XCTAssertEqual(hostConfig?["NetworkMode"] as? String, "bridge")
        XCTAssertEqual(config?["User"] as? String, "shibukawayoshiki")
        XCTAssertEqual(config?["WorkingDir"] as? String, "/home/shibukawayoshiki")
        XCTAssertNotNil(config?["Labels"] as? [String: Any])
        XCTAssertEqual(config?["AttachStdin"] as? Bool, false)
        XCTAssertEqual(config?["AttachStdout"] as? Bool, false)
        XCTAssertEqual(config?["AttachStderr"] as? Bool, false)
        XCTAssertEqual(config?["Tty"] as? Bool, false)
        XCTAssertEqual(config?["OpenStdin"] as? Bool, false)
        XCTAssertEqual(config?["StdinOnce"] as? Bool, false)
        XCTAssertTrue(env?.contains("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") == true)
        XCTAssertTrue(env?.contains("HOME=/home/shibukawayoshiki") == true)
        XCTAssertTrue(env?.contains("USER=shibukawayoshiki") == true)
        XCTAssertTrue(env?.contains("SHELL=/bin/bash") == true)
        XCTAssertEqual(state?["Running"] as? Bool, true)
    }

    func testContainerDescriptorUsesVmIDAsDockerVisibleName() {
        let descriptor = AttachedContainerDescriptor(
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            name: "msl-ubuntu",
            image: "msl/ubuntu",
            running: true,
            platform: "linux",
            defaultUser: "root",
            defaultHome: "/root",
            defaultShell: "/bin/sh"
        )

        XCTAssertEqual(descriptor.inspectJSON(execIDs: [])["Name"] as? String, "/msl-ubuntu")
    }

    func testContainerSummaryUsesFullDockerIDAndSlashPrefixedName() {
        let descriptor = AttachedContainerDescriptor(
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            name: "msl-ubuntu",
            image: "msl/ubuntu",
            running: true,
            platform: "linux",
            defaultUser: "root",
            defaultHome: "/root",
            defaultShell: "/bin/sh"
        )

        let body = descriptor.containerSummaryJSON()
        XCTAssertEqual((body["Id"] as? String)?.count, 64)
        XCTAssertEqual((body["Names"] as? [String])?.first, "/msl-ubuntu")
        XCTAssertEqual(body["Image"] as? String, "msl/ubuntu")
    }

    func testInspectJSONIncludesExecIDsWhenPresent() {
        let descriptor = AttachedContainerDescriptor(
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            name: "msl-ubuntu",
            image: "msl/ubuntu",
            running: true,
            platform: "linux",
            defaultUser: "root",
            defaultHome: "/root",
            defaultShell: "/bin/sh"
        )

        let body = descriptor.inspectJSON(execIDs: ["exec-b", "exec-a"])
        XCTAssertEqual(body["ExecIDs"] as? [String], ["exec-b", "exec-a"])
    }

    func testAttachedExecSessionInspectJSONMatchesDockerShape() {
        let session = AttachedExecSession(
            execID: String(repeating: "a", count: 64),
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh", "-c", "echo hi"],
            workingDir: "/root",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "root",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: 2,
            pid: 3033,
            createdAtEpochMs: 1_772_809_800_000
        )

        let body = session.inspectJSON()
        let processConfig = body["ProcessConfig"] as? [String: Any]

        XCTAssertEqual(body["ID"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(body["ContainerID"] as? String, String(repeating: "b", count: 64))
        XCTAssertEqual(body["Running"] as? Bool, false)
        XCTAssertEqual(body["ExitCode"] as? Int, 2)
        XCTAssertEqual(body["OpenStdin"] as? Bool, true)
        XCTAssertEqual(body["OpenStdout"] as? Bool, true)
        XCTAssertEqual(body["OpenStderr"] as? Bool, true)
        XCTAssertEqual(body["Pid"] as? Int, 3033)
        XCTAssertEqual(processConfig?["entrypoint"] as? String, "/bin/sh")
        XCTAssertEqual(processConfig?["user"] as? String, "root")
        XCTAssertEqual(processConfig?["tty"] as? Bool, false)
        XCTAssertEqual(processConfig?["arguments"] as? String, "-c echo hi")
    }

    func testRandomHexProducesRequestedLength() {
        let value = randomHex(length: 64)
        XCTAssertEqual(value.count, 64)
        XCTAssertNotNil(UInt64(String(value.prefix(16)), radix: 16))
    }

    func testDockerMuxFrameUsesDockerHeaderFormat() {
        let payload = Data("abc".utf8)
        let framed = dockerMuxFrame(streamID: 1, payload: payload)

        XCTAssertEqual(Array(framed.prefix(4)), [1, 0, 0, 0])
        XCTAssertEqual(Array(framed[4..<8]), [0, 0, 0, 3])
        XCTAssertEqual(Data(framed.suffix(3)), payload)
    }

    func testExecStartContentTypeMatchesTTYMode() {
        XCTAssertEqual(attachedExecStartContentType(tty: true), "application/vnd.docker.raw-stream")
        XCTAssertEqual(attachedExecStartContentType(tty: false), "application/vnd.docker.multiplexed-stream")
    }

    func testExecStartValidationRejectsDetachAndTTYMismatch() {
        XCTAssertEqual(
            attachedValidateExecStartRequest(detach: true, requestedTTY: nil, sessionTTY: false),
            "detach_not_supported"
        )
        XCTAssertEqual(
            attachedValidateExecStartRequest(detach: nil, requestedTTY: true, sessionTTY: false),
            "tty_mismatch"
        )
        XCTAssertNil(
            attachedValidateExecStartRequest(detach: nil, requestedTTY: false, sessionTTY: false)
        )
    }

    func testExecCreateValidationRejectsEmptyCommand() {
        XCTAssertEqual(attachedValidateExecCreateRequest(cmd: []), "missing_cmd")
        XCTAssertEqual(attachedValidateExecCreateRequest(cmd: ["   "]), "missing_cmd")
        XCTAssertNil(attachedValidateExecCreateRequest(cmd: nil))
        XCTAssertNil(attachedValidateExecCreateRequest(cmd: ["/bin/sh"]))
    }

    func testAttachedStreamForwardingRespectsAttachFlags() {
        XCTAssertTrue(attachedShouldPumpInput(attachStdin: true))
        XCTAssertFalse(attachedShouldPumpInput(attachStdin: false))

        XCTAssertTrue(attachedShouldForwardStream(tty: false, attachStdout: true, attachStderr: false, stream: "stdout"))
        XCTAssertFalse(attachedShouldForwardStream(tty: false, attachStdout: false, attachStderr: true, stream: "stdout"))
        XCTAssertTrue(attachedShouldForwardStream(tty: false, attachStdout: false, attachStderr: true, stream: "stderr"))
        XCTAssertFalse(attachedShouldForwardStream(tty: false, attachStdout: true, attachStderr: false, stream: "stderr"))

        XCTAssertTrue(attachedShouldForwardStream(tty: true, attachStdout: true, attachStderr: false, stream: "stdout"))
        XCTAssertTrue(attachedShouldForwardStream(tty: true, attachStdout: false, attachStderr: true, stream: "stderr"))
        XCTAssertFalse(attachedShouldForwardStream(tty: true, attachStdout: false, attachStderr: false, stream: "stdout"))
        XCTAssertFalse(attachedShouldForwardStream(tty: true, attachStdout: false, attachStderr: false, stream: "stderr"))
    }

    func testAttachedExecConnectionModeTreatsOneShotNonTTYExecAsFinite() {
        let finite = AttachedExecSession(
            execID: "finite",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "a", count: 64),
            cmd: ["/bin/bash", "-lic", "echo ok"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: false,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let persistent = AttachedExecSession(
            execID: "persistent",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )

        XCTAssertEqual(attachedExecConnectionMode(session: finite), .finiteOneShot)
        XCTAssertEqual(attachedExecConnectionMode(session: persistent), .persistent)
    }

    func testAttachedExecKindClassifiesWatchProbeAndHelperSessions() {
        let helper = AttachedExecSession(
            execID: "helper",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let watch = AttachedExecSession(
            execID: "watch",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh", "-c", "# Watch installed extensions\nsleep 1"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let probe = AttachedExecSession(
            execID: "probe",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/bash", "-lic", "echo -n MARK; cat /proc/self/environ; echo -n MARK"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let interactive = AttachedExecSession(
            execID: "interactive",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/bash"],
            workingDir: "/home/shibukawayoshiki",
            tty: true,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let install = AttachedExecSession(
            execID: "install",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh", "-c", "(dd iflag=fullblock bs=8192 count=10) | tar --no-same-owner -xz -C /home/shibukawayoshiki/.vscode-server/bin/x"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )
        let sync = AttachedExecSession(
            execID: "sync",
            instance: "ubuntu",
            vmID: "msl-ubuntu",
            containerID: String(repeating: "b", count: 64),
            cmd: ["/bin/sh", "-c", "tar c extensionsCache/ms-ceintl && code-server --server-data-dir /home/shibukawayoshiki/.vscode-server --list-extensions"],
            workingDir: "/home/shibukawayoshiki",
            tty: false,
            attachStdin: true,
            attachStdout: true,
            attachStderr: true,
            detachKeys: "",
            user: "shibukawayoshiki",
            envAdditions: [:],
            privileged: false,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAtEpochMs: 0
        )

        XCTAssertEqual(attachedExecKind(session: helper), .helperShell)
        XCTAssertEqual(attachedExecKind(session: watch), .watchInstalledExtensions)
        XCTAssertEqual(attachedExecKind(session: probe), .userEnvProbe)
        XCTAssertEqual(attachedExecKind(session: interactive), .interactive)
        XCTAssertEqual(attachedExecKind(session: install), .extensionInstall)
        XCTAssertEqual(attachedExecKind(session: sync), .extensionSync)
    }

    func testLifecycleDiagnosticEventsDistinguishWatchRestartAndActivationObservation() {
        let watchRestart = attachedLifecycleDiagnosticEvents(
            kind: .watchInstalledExtensions,
            outcome: "started",
            fields: ["cycle": "restarted"]
        ).map(\.event)
        let syncStart = attachedLifecycleDiagnosticEvents(
            kind: .extensionSync,
            outcome: "started",
            fields: [:]
        ).map(\.event)
        let installSuccess = attachedLifecycleDiagnosticEvents(
            kind: .extensionInstall,
            outcome: "succeeded",
            fields: [:]
        ).map(\.event)

        XCTAssertEqual(watchRestart, ["extension_watch_restarted", "extension_activation_observed"])
        XCTAssertEqual(syncStart, ["extension_sync_started", "extension_activation_observed"])
        XCTAssertEqual(installSuccess, ["extension_install_succeeded"])
    }

    func testCompactSummaryTargetsInteractiveWatchAndExtensionSyncKinds() {
        XCTAssertTrue(attachedShouldEmitCompactSummary(kind: .interactive))
        XCTAssertTrue(attachedShouldEmitCompactSummary(kind: .watchMachineSettings))
        XCTAssertTrue(attachedShouldEmitCompactSummary(kind: .extensionSync))
        XCTAssertFalse(attachedShouldEmitCompactSummary(kind: .helperShell))
        XCTAssertFalse(attachedShouldEmitCompactSummary(kind: .backgroundProbe))
    }

    func testAttachedNonTTYMuxFramePreservesCombinedStdoutChunk() {
        let payload = Data("aarch64\n\u{2404}0\u{2404}".utf8)
        let frame = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: payload))

        XCTAssertEqual(frame.stream, "stdout")
        XCTAssertEqual(frame.streamID, 1)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(Array(frame.framed.prefix(4)), [1, 0, 0, 0])
        XCTAssertEqual(Data(frame.framed.suffix(payload.count)), payload)
    }

    func testAttachedNonTTYMuxFramePreservesOrderedStderrChunk() {
        let payload = Data("\u{2404}".utf8)
        let frame = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stderr, data: payload))

        XCTAssertEqual(frame.stream, "stderr")
        XCTAssertEqual(frame.streamID, 2)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(Array(frame.framed.prefix(4)), [2, 0, 0, 0])
        XCTAssertEqual(Data(frame.framed.suffix(payload.count)), payload)
    }

    func testImmediateMuxWriterCoalescesShellCommandCompletionFrames() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let flags = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK), -1)

        let writer = AttachedImmediateMuxWriter()
        let stdoutStart = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}".utf8)))
        let stdoutPayload = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("/home/shibukawayoshiki/.ssh/known_hosts exists\n".utf8)))
        let stdoutExit = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}1\u{2404}".utf8)))
        let stderrEnd = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stderr, data: Data("\u{2404}".utf8)))

        XCTAssertTrue(writer.append(stream: stdoutStart.stream, payload: stdoutStart.payload, framed: stdoutStart.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stdoutPayload.stream, payload: stdoutPayload.payload, framed: stdoutPayload.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stdoutExit.stream, payload: stdoutExit.payload, framed: stdoutExit.framed, fd: fds[1]))

        var probe = [UInt8](repeating: 0, count: 256)
        let initialRead = read(fds[0], &probe, probe.count)
        XCTAssertEqual(initialRead, stdoutStart.framed.count)
        XCTAssertEqual(Data(probe.prefix(Int(initialRead))), stdoutStart.framed)

        let preFlushRead = read(fds[0], &probe, probe.count)
        XCTAssertEqual(preFlushRead, -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)

        XCTAssertTrue(writer.append(stream: stderrEnd.stream, payload: stderrEnd.payload, framed: stderrEnd.framed, fd: fds[1]))
        usleep(40_000)

        let expected = stdoutPayload.framed + stdoutExit.framed + stderrEnd.framed
        var received = Data()
        while received.count < expected.count {
            let count = read(fds[0], &probe, probe.count)
            XCTAssertGreaterThan(count, 0)
            received.append(probe, count: Int(count))
        }
        XCTAssertEqual(received, expected)
    }

    func testImmediateMuxWriterFlushesShellCommandStartSentinelImmediately() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let flags = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK), -1)

        let writer = AttachedImmediateMuxWriter()
        let stdoutStart = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}".utf8)))

        XCTAssertTrue(writer.append(stream: stdoutStart.stream, payload: stdoutStart.payload, framed: stdoutStart.framed, fd: fds[1]))

        var received = Data(count: stdoutStart.framed.count)
        let count = received.withUnsafeMutableBytes { rawBuffer in
            read(fds[0], rawBuffer.baseAddress, rawBuffer.count)
        }
        XCTAssertEqual(count, stdoutStart.framed.count)
        XCTAssertEqual(received, stdoutStart.framed)
    }

    func testImmediateMuxWriterPreservesVendorShellServerTranscriptAcrossCommands() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let flags = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK), -1)

        let writer = AttachedImmediateMuxWriter()
        let stdoutStart = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}".utf8)))
        let stderrPayload = attachedNonTTYMuxFrame(
            for: ProcOutputEvent(kind: .stderr, data: Data("/bin/sh: 11: gpgconf: not found\n\u{2404}".utf8))
        )
        let stdoutExit = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}127\u{2404}".utf8)))
        let nextStdoutStart = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}".utf8)))

        XCTAssertTrue(writer.append(stream: stdoutStart.stream, payload: stdoutStart.payload, framed: stdoutStart.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stderrPayload.stream, payload: stderrPayload.payload, framed: stderrPayload.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stdoutExit.stream, payload: stdoutExit.payload, framed: stdoutExit.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: nextStdoutStart.stream, payload: nextStdoutStart.payload, framed: nextStdoutStart.framed, fd: fds[1]))
        usleep(40_000)
        XCTAssertTrue(writer.flushPending(fd: fds[1]))

        var received = Data()
        var probe = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(fds[0], &probe, probe.count)
            if count > 0 {
                received.append(probe, count: Int(count))
                continue
            }
            XCTAssertEqual(count, -1)
            XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
            break
        }

        let demuxed = try demuxDockerFrames(received)
        XCTAssertEqual(
            demuxed.stdout,
            Data("\u{2404}\u{2404}127\u{2404}\u{2404}".utf8)
        )
        XCTAssertEqual(
            demuxed.stderr,
            Data("/bin/sh: 11: gpgconf: not found\n\u{2404}".utf8)
        )
        let parsed = try parseVendorShellCommand(stdout: demuxed.stdout, stderr: demuxed.stderr)

        XCTAssertEqual(parsed.stdout, "")
        XCTAssertEqual(parsed.stderr, "/bin/sh: 11: gpgconf: not found\n")
        XCTAssertEqual(parsed.exitCode, "127")
        XCTAssertEqual(parsed.remainingStdout, Data("\u{2404}".utf8))
        XCTAssertEqual(parsed.remainingStderr, Data())
    }

    func testImmediateMuxWriterDefersCompletionUntilLateStdoutArrives() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let flags = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(fds[0], F_SETFL, flags | O_NONBLOCK), -1)

        let writer = AttachedImmediateMuxWriter()
        let stdoutStart = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}".utf8)))
        let stdoutPayload = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("prelude\n".utf8)))
        let stdoutExit = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("\u{2404}0\u{2404}".utf8)))
        let stderrPayloadAndSentinel = attachedNonTTYMuxFrame(
            for: ProcOutputEvent(kind: .stderr, data: Data("warning\n\u{2404}".utf8))
        )
        let lateStdout = attachedNonTTYMuxFrame(for: ProcOutputEvent(kind: .stdout, data: Data("tail\n".utf8)))

        XCTAssertTrue(writer.append(stream: stdoutStart.stream, payload: stdoutStart.payload, framed: stdoutStart.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stdoutPayload.stream, payload: stdoutPayload.payload, framed: stdoutPayload.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stdoutExit.stream, payload: stdoutExit.payload, framed: stdoutExit.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: stderrPayloadAndSentinel.stream, payload: stderrPayloadAndSentinel.payload, framed: stderrPayloadAndSentinel.framed, fd: fds[1]))
        XCTAssertTrue(writer.append(stream: lateStdout.stream, payload: lateStdout.payload, framed: lateStdout.framed, fd: fds[1]))

        usleep(40_000)
        XCTAssertTrue(writer.flushPending(fd: fds[1]))

        var received = Data()
        var probe = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(fds[0], &probe, probe.count)
            if count > 0 {
                received.append(probe, count: Int(count))
                continue
            }
            XCTAssertEqual(count, -1)
            XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
            break
        }

        let demuxed = try demuxDockerFrames(received)
        XCTAssertEqual(
            demuxed.stdout,
            Data("\u{2404}prelude\ntail\n\u{2404}0\u{2404}".utf8)
        )
        XCTAssertEqual(
            demuxed.stderr,
            Data("warning\n\u{2404}".utf8)
        )
        let parsed = try parseVendorShellCommand(stdout: demuxed.stdout, stderr: demuxed.stderr)

        XCTAssertEqual(parsed.stdout, "")
        XCTAssertEqual(parsed.stderr, "warning\n")
        XCTAssertEqual(parsed.exitCode, "0")
        XCTAssertEqual(parsed.remainingStdout, Data())
        XCTAssertEqual(parsed.remainingStderr, Data())
    }
}

private func demuxDockerFrames(_ framed: Data) throws -> (stdout: Data, stderr: Data) {
    var offset = 0
    var stdout = Data()
    var stderr = Data()

    while offset < framed.count {
        XCTAssertGreaterThanOrEqual(framed.count - offset, 8)
        let header = framed[offset..<(offset + 8)]
        let streamID = header[header.startIndex]
        let lengthBytes = header.suffix(4)
        let payloadLength = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        offset += 8
        XCTAssertGreaterThanOrEqual(framed.count - offset, payloadLength)
        let payload = framed[offset..<(offset + payloadLength)]
        offset += payloadLength
        switch streamID {
        case 1:
            stdout.append(contentsOf: payload)
        case 2:
            stderr.append(contentsOf: payload)
        default:
            XCTFail("unexpected stream id \(streamID)")
        }
    }

    return (stdout, stderr)
}

private func parseVendorShellCommand(stdout: Data, stderr: Data) throws -> (
    stdout: String,
    stderr: String,
    exitCode: String,
    remainingStdout: Data,
    remainingStderr: Data
) {
    let eot = Data("\u{2404}".utf8)

    func consume(_ source: Data, counts: [Int]) throws -> ([String], Data) {
        var remainder = source
        var results: [String] = []

        for count in counts {
            var group: [String] = []
            for _ in 0..<count {
                guard let range = remainder.range(of: eot) else {
                    XCTFail("missing EOT in \(String(decoding: source, as: UTF8.self))")
                    throw NSError(domain: "AttachedContainerInspectShapeTests", code: 1)
                }
                let chunk = remainder[..<range.lowerBound]
                group.append(String(decoding: chunk, as: UTF8.self))
                remainder.removeSubrange(..<range.upperBound)
            }
            results.append(contentsOf: group)
        }

        return (results, remainder)
    }

    let (stdoutResults, remainingStdout) = try consume(stdout, counts: [1, 2])
    let (stderrResults, remainingStderr) = try consume(stderr, counts: [1])

    return (
        stdout: stdoutResults[0],
        stderr: stderrResults[0],
        exitCode: stdoutResults[2],
        remainingStdout: remainingStdout,
        remainingStderr: remainingStderr
    )
}

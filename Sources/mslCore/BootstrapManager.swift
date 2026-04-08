import Foundation

public final class BootstrapManager {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let logger: MSLLogger

    public init(paths: MSLPaths, logger: MSLLogger, fileManager: FileManager = .default) {
        self.paths = paths
        self.logger = logger
        self.fileManager = fileManager
    }

    public func ensureBootstrapped(context: BootstrapContext) throws {
        logger.log("bootstrap_started", fields: ["context": bootstrapContextName(context)])
        try ensureDir(paths.mslHome)
        try ensureDir(paths.mslHostToolsDir)
        try ensureDir(paths.appSupport)
        try ensureDir(paths.runtime)
        try ensureDir(paths.logs)
        try ensureDir(paths.imagesDir)
        try ensureDir(paths.distrosDir)

        if !fileManager.fileExists(atPath: paths.configFile.path) {
            try Data("{}\n".utf8).write(to: paths.configFile, options: .atomic)
        }

        try ensureCompressionCachePolicyCatalog()

        if context == .runtime {
            logger.log("bootstrap_completed", fields: ["context": bootstrapContextName(context)])
            return
        }

        // Legacy RAW-image bootstrap path has been retired.
        // Install/build context now stages required host tools only.
        try ensureDir(paths.bootstrapArtifactsDir)
        try ensureDir(paths.bootstrapCloudInitDir)
        try stageInitBinaryIfAvailable()
        try stageExt4HelpersIfAvailable()
        try ensureCloudInitSeed()

        logger.log("bootstrap_completed", fields: ["context": bootstrapContextName(context)])
    }

    private func bootstrapContextName(_ context: BootstrapContext) -> String {
        switch context {
        case .runtime:
            return "runtime"
        case .install:
            return "install"
        case .build:
            return "build"
        }
    }

    private func ensureCompressionCachePolicyCatalog() throws {
        let store = CompressionCachePolicyCatalogStore(paths: paths, fileManager: fileManager)
        let created = try store.ensureDefaultCatalogIfMissing()
        if created {
            logger.log("compression_cache_policy_catalog_created", fields: [
                "path": store.catalogFile.path
            ])
        }
    }

    private func ensureDir(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func ensureCloudInitSeed() throws {
        let user = resolveDefaultLinuxUser()
        let password = ProcessInfo.processInfo.environment["MSL_DEFAULT_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
        let hostname = ProcessInfo.processInfo.environment["MSL_DEFAULT_HOSTNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "msl"

        let userData = renderUserData(user: user, password: password)
        let userDataChanged = try writeIfChanged(Data(userData.utf8), to: paths.bootstrapCloudInitUserDataFile)

        let metaData = """
        instance-id: msl-default
        local-hostname: \(hostname)
        """
        let metaDataChanged = try writeIfChanged(Data((metaData + "\n").utf8), to: paths.bootstrapCloudInitMetaDataFile)
        let initBinarySeedChanged = try syncInitBinaryIntoCloudInitSeed()
        let storageProvisionSeedChanged = try syncStorageProvisionScriptIntoCloudInitSeed()

        if ProcessInfo.processInfo.environment["MSL_SKIP_SEED_IMAGE"] == "1" {
            return
        }

        let seedExists = fileManager.fileExists(atPath: paths.bootstrapCloudInitSeedISOFile.path)
        if seedExists && !userDataChanged && !metaDataChanged && !initBinarySeedChanged && !storageProvisionSeedChanged {
            return
        }

        if seedExists {
            try fileManager.removeItem(at: paths.bootstrapCloudInitSeedISOFile)
        }

        let success = try runCommand("/usr/bin/hdiutil", [
            "makehybrid",
            "-o", paths.bootstrapCloudInitSeedISOFile.path,
            paths.bootstrapCloudInitDir.path,
            "-iso",
            "-joliet",
            "-default-volume-name", "cidata"
        ])

        if !success {
            throw MSLRuntimeError("bootstrap failed: unable to generate cloud-init seed image")
        }
    }

    private func syncInitBinaryIntoCloudInitSeed() throws -> Bool {
        let seedBinary = paths.bootstrapCloudInitDir.appendingPathComponent("msl-init", isDirectory: false)
        if fileManager.fileExists(atPath: paths.mslHostInitBinaryFile.path) {
            let data = try Data(contentsOf: paths.mslHostInitBinaryFile)
            let changed = try writeIfChanged(data, to: seedBinary)
            if changed {
                _ = try runCommand("/bin/chmod", ["0755", seedBinary.path])
                logger.log("seed_init_binary_staged", fields: [
                    "src": paths.mslHostInitBinaryFile.path,
                    "dst": seedBinary.path
                ])
            }
            return changed
        }

        if fileManager.fileExists(atPath: seedBinary.path) {
            try fileManager.removeItem(at: seedBinary)
            logger.log("seed_init_binary_removed", fields: ["path": seedBinary.path])
            return true
        }
        return false
    }

    private func syncStorageProvisionScriptIntoCloudInitSeed() throws -> Bool {
        let seedScript = paths.bootstrapCloudInitDir.appendingPathComponent("msl-storage-provision.sh", isDirectory: false)
        let source = resolveStorageProvisionScriptSourcePath()
        guard let source else {
            if fileManager.fileExists(atPath: seedScript.path) {
                try fileManager.removeItem(at: seedScript)
                logger.log("seed_storage_provision_script_removed", fields: ["path": seedScript.path])
                return true
            }
            return false
        }

        let data = try Data(contentsOf: source)
        let changed = try writeIfChanged(data, to: seedScript)
        if changed {
            _ = try runCommand("/bin/chmod", ["0755", seedScript.path])
            logger.log("seed_storage_provision_script_staged", fields: [
                "src": source.path,
                "dst": seedScript.path
            ])
        }
        return changed
    }

    private func resolveStorageProvisionScriptSourcePath() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["MSL_STORAGE_PROVISION_SCRIPT_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }

        if fileManager.fileExists(atPath: paths.storageProvisionScriptFile.path) {
            return paths.storageProvisionScriptFile
        }
        return nil
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            let current = try Data(contentsOf: url)
            if current == data {
                return false
            }
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    private func resolveDefaultLinuxUser() -> String {
        let fromEnv = ProcessInfo.processInfo.environment["MSL_DEFAULT_USER"].flatMap { $0.isEmpty ? nil : $0 }
        let raw = fromEnv ?? ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return normalizedLinuxUserName(raw)
    }

    private func normalizedLinuxUserName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                return ch
            }
            return "-"
        }
        var candidate = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if candidate.isEmpty {
            candidate = "msl"
        }
        if let first = candidate.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            candidate = "u-\(candidate)"
        }
        return String(candidate.prefix(32))
    }

    private func renderUserData(user: String, password: String?) -> String {
        let terminalType = resolveGuestTerminalType()
        let hostHomeComponent = paths.home.lastPathComponent
        let guestHomeSource = "/mnt/macos/Users/\(hostHomeComponent)/msl-home"
        let authSection: String
        if let password {
            authSection = """
            chpasswd:
              list: |
                \(user):\(password)
              expire: false
            ssh_pwauth: true
            lock_passwd: false
            """
        } else {
            authSection = """
            ssh_pwauth: false
            lock_passwd: true
            """
        }

        let baseUserData = """
        #cloud-config
        output:
          all: "| tee -a /var/log/cloud-init-output.log"
        users:
          - default
          - name: \(user)
            shell: /bin/bash
            groups: [adm, sudo]
            sudo: ALL=(ALL) NOPASSWD:ALL
        \(authSection)
        write_files:
          - path: /etc/default/grub.d/99-msl-serial.cfg
            permissions: '0644'
            content: |
              # Enable kernel console output on virtio serial (hvc0)
              GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=hvc0,115200n8"
              GRUB_TERMINAL="console serial"
              GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
          - path: /etc/systemd/system/serial-getty@.service.d/autologin.conf
            permissions: '0644'
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin \(user) --keep-baud 115200,38400,9600 %I \(terminalType)
          - path: /etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf
            permissions: '0644'
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin \(user) --keep-baud 115200,38400,9600 %I \(terminalType)
          - path: /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
            permissions: '0644'
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin \(user) --keep-baud 115200,38400,9600 %I \(terminalType)
          - path: /etc/modules-load.d/vsock.conf
            permissions: '0644'
            content: |
              vsock
              vmw_vsock_virtio_transport
          - path: /etc/systemd/system/msl-init.service
            permissions: '0644'
            content: |
              [Unit]
              Description=msl init control server
              After=local-fs.target systemd-modules-load.service

              [Service]
              Type=simple
              Environment=MSL_VSOCK_PORT=1024
              Environment=MSL_INIT_LOG_FILE=/var/log/msl-init.log
              ExecStartPre=-/usr/sbin/modprobe vmw_vsock_virtio_transport
              ExecStartPre=/usr/local/sbin/msl-update-init.sh
              ExecStart=/usr/local/bin/msl-init
              Restart=always
              RestartSec=1

              [Install]
              WantedBy=multi-user.target
          - path: /usr/local/sbin/msl-update-init.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              # Update msl-init from seed ISO if a newer binary is available.
              DEST=/usr/local/bin/msl-init
              MOUNTED=
              for DEV in /dev/vdb /dev/sr0 /dev/cdrom; do
                if [ -b "$DEV" ]; then
                  mkdir -p /tmp/msl-seed
                  if mount -t iso9660 -o ro "$DEV" /tmp/msl-seed 2>/dev/null; then
                    MOUNTED=1
                    break
                  fi
                fi
              done
              if [ -n "$MOUNTED" ] && [ -f /tmp/msl-seed/msl-init ]; then
                if ! cmp -s /tmp/msl-seed/msl-init "$DEST" 2>/dev/null; then
                  cp /tmp/msl-seed/msl-init "$DEST" && chmod 0755 "$DEST"
                  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) msl-init updated from seed ISO" >> /var/log/msl-init.log
                fi
              fi
              if [ -x "$DEST" ]; then
                ln -sf "$DEST" /usr/local/bin/msl
              fi
              [ -n "$MOUNTED" ] && umount /tmp/msl-seed 2>/dev/null
              true
          - path: /usr/local/sbin/msl-runcmd-step-log.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              STEP="$1"
              TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              echo "$TS step=$STEP" >> /var/log/msl-cloud-init.log
        runcmd:
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step00-update-grub" ]
          - [ sh, -lc, "update-grub 2>/dev/null || true" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step01-setup-dirs" ]
          - [ mkdir, -p, /mnt/macos ]
          - [ mkdir, -p, /home/\(user) ]
          - [ mkdir, -p, /usr/local/bin ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step02-fstab" ]
          - [ sh, -lc, "grep -Fqx 'macos /mnt/macos virtiofs rw,nofail 0 0' /etc/fstab || echo 'macos /mnt/macos virtiofs rw,nofail 0 0' >> /etc/fstab" ]
          - [ sh, -lc, "grep -Fqx '\(guestHomeSource) /home/\(user) none bind,nofail 0 0' /etc/fstab || echo '\(guestHomeSource) /home/\(user) none bind,nofail 0 0' >> /etc/fstab" ]
          - [ sh, -lc, "mount -a || true" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step03-mount-seed-iso" ]
          - [ sh, -lc, "LOG=/var/log/msl-cloud-init.log; TS=$(date -u +%Y-%m-%dT%H:%M:%SZ); MOUNTED=no; mkdir -p /tmp/msl-seed; for DEV in /dev/vdb /dev/sr0 /dev/cdrom; do if [ -b $DEV ]; then if mount -t iso9660 -o ro $DEV /tmp/msl-seed 2>/dev/null; then MOUNTED=$DEV; break; fi; fi; done; echo ${TS} seed_iso_mount=${MOUNTED} >> ${LOG}; if [ -f /tmp/msl-seed/msl-init ]; then cp /tmp/msl-seed/msl-init /usr/local/bin/msl-init && chmod 0755 /usr/local/bin/msl-init && echo ${TS} seed_iso_copy=ok >> ${LOG}; else echo ${TS} seed_iso_copy=not_found >> ${LOG}; ls -la /tmp/msl-seed/ >> ${LOG} 2>&1; fi; if [ -x /usr/local/bin/msl-init ]; then ln -sf /usr/local/bin/msl-init /usr/local/bin/msl; ln -sf /usr/local/bin/msl-init /usr/local/bin/code; fi; umount /tmp/msl-seed 2>/dev/null; true" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step04-verify-msl-init" ]
          - [ sh, -lc, "LOG=/var/log/msl-cloud-init.log; TS=$(date -u +%Y-%m-%dT%H:%M:%SZ); if [ -x /usr/local/bin/msl-init ]; then echo ${TS} msl_init=present >> ${LOG}; else echo ${TS} msl_init=missing >> ${LOG}; fi; if [ -x /usr/local/bin/msl ]; then echo ${TS} msl_cmd=present >> ${LOG}; else echo ${TS} msl_cmd=missing >> ${LOG}; fi" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step04b-storage-provision" ]
          - [ sh, -lc, "LOG=/var/log/msl-cloud-init.log; TS=$(date -u +%Y-%m-%dT%H:%M:%SZ); if [ -f /tmp/msl-seed/msl-storage-provision.sh ]; then cp /tmp/msl-seed/msl-storage-provision.sh /usr/local/sbin/msl-storage-provision.sh && chmod 0755 /usr/local/sbin/msl-storage-provision.sh && /usr/local/sbin/msl-storage-provision.sh >> ${LOG} 2>&1 || true; echo ${TS} storage_provision=applied >> ${LOG}; else echo ${TS} storage_provision=skipped >> ${LOG}; fi" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step05-enable-services" ]
          - [ systemctl, daemon-reload ]
          - [ sh, -lc, "if [ -x /usr/local/bin/msl-init ]; then systemctl enable --now msl-init.service || true; fi" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step06-enable-serial" ]
          - [ sh, -lc, "systemctl enable --now serial-getty@hvc0.service || true" ]
          - [ sh, -lc, "/usr/local/sbin/msl-runcmd-step-log.sh step07-record-state" ]
          - [ sh, -lc, "LOG=/var/log/msl-cloud-init.log; TS=$(date -u +%Y-%m-%dT%H:%M:%SZ); ENABLED=$(systemctl is-enabled msl-init.service 2>/dev/null || echo unknown); ACTIVE=$(systemctl is-active msl-init.service 2>/dev/null || echo unknown); echo ${TS} msl_init_enabled=${ENABLED} msl_init_active=${ACTIVE} >> ${LOG}" ]
        """
        return baseUserData
    }

    private func stageInitBinaryIfAvailable() throws {
        guard let source = resolveInitBinarySourcePath() else {
            logger.log("init_binary_missing", fields: ["reason": "source_not_found"])
            return
        }
        guard isSupportedGuestInitBinary(source) else {
            logger.log("init_binary_missing", fields: [
                "reason": "invalid_guest_elf",
                "path": source.path
            ])
            return
        }
        if fileManager.fileExists(atPath: paths.mslHostInitBinaryFile.path) {
            let current = try? Data(contentsOf: paths.mslHostInitBinaryFile)
            let src = try? Data(contentsOf: source)
            if current == src {
                logger.log("init_binary_reused", fields: ["path": paths.mslHostInitBinaryFile.path])
                return
            }
        }
        if fileManager.fileExists(atPath: paths.mslHostInitBinaryFile.path) {
            try fileManager.removeItem(at: paths.mslHostInitBinaryFile)
        }
        try fileManager.copyItem(at: source, to: paths.mslHostInitBinaryFile)
        _ = try runCommand("/bin/chmod", ["0755", paths.mslHostInitBinaryFile.path])
        logger.log("init_binary_staged", fields: [
            "src": source.path,
            "dst": paths.mslHostInitBinaryFile.path
        ])
    }

    private func isSupportedGuestInitBinary(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 20 else {
            return false
        }
        // ELF magic
        guard data[0] == 0x7f, data[1] == 0x45, data[2] == 0x4c, data[3] == 0x46 else {
            return false
        }
        // 64-bit + little endian
        guard data[4] == 0x02, data[5] == 0x01 else {
            return false
        }
        // e_machine (AArch64 = 183 / 0x00b7), little endian at offset 18
        let machine = UInt16(data[18]) | (UInt16(data[19]) << 8)
        return machine == 183
    }

    private func resolveInitBinarySourcePath() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["MSL_INIT_BINARY_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }

        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        if let arg0 = CommandLine.arguments.first {
            roots.append(URL(fileURLWithPath: arg0, isDirectory: false).deletingLastPathComponent())
        }

        var candidates: [URL] = []
        for root in roots {
            var cursor = root
            for _ in 0..<8 {
                let c = cursor
                    .appendingPathComponent("Support", isDirectory: true)
                    .appendingPathComponent("msl-init", isDirectory: true)
                    .appendingPathComponent("target", isDirectory: true)
                    .appendingPathComponent("aarch64-unknown-linux-musl", isDirectory: true)
                    .appendingPathComponent("release", isDirectory: true)
                    .appendingPathComponent("msl-init", isDirectory: false)
                candidates.append(c)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func stageExt4HelpersIfAvailable() throws {
        try stageHostToolIfAvailable(
            envVar: "MSL_EXT4_MKFS_HELPER_PATH",
            binaryName: "msl-ext4-mkfs",
            supportDirName: "msl-ext4-mkfs",
            destination: paths.mslHostExt4MkfsHelperBinaryFile,
            logPrefix: "ext4_mkfs_helper"
        )
        try stageHostToolIfAvailable(
            envVar: "MSL_EXT4_HELPER_PATH",
            binaryName: "msl-ext4-image",
            supportDirName: "msl-ext4-image",
            destination: paths.mslHostExt4HelperBinaryFile,
            logPrefix: "ext4_helper"
        )
    }

    private func stageHostToolIfAvailable(
        envVar: String,
        binaryName: String,
        supportDirName: String,
        destination: URL,
        logPrefix: String
    ) throws {
        guard let source = resolveHostToolSourcePath(
            envVar: envVar,
            binaryName: binaryName,
            supportDirName: supportDirName
        ) else {
            logger.log("\(logPrefix)_missing", fields: ["reason": "source_not_found"])
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            let current = try? Data(contentsOf: destination)
            let src = try? Data(contentsOf: source)
            if current == src {
                logger.log("\(logPrefix)_reused", fields: ["path": destination.path])
                return
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        _ = try runCommand("/bin/chmod", ["0755", destination.path])
        logger.log("\(logPrefix)_staged", fields: [
            "src": source.path,
            "dst": destination.path
        ])
    }

    private func resolveHostToolSourcePath(
        envVar: String,
        binaryName: String,
        supportDirName: String
    ) -> URL? {
        if let explicit = ProcessInfo.processInfo.environment[envVar], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.fileExists(atPath: url.path), fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            return nil
        }

        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        if let arg0 = CommandLine.arguments.first {
            let binDir = URL(fileURLWithPath: arg0, isDirectory: false).deletingLastPathComponent()
            roots.append(binDir)
        }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent(binaryName, isDirectory: false))
            var cursor = root
            for _ in 0..<8 {
                let c = cursor
                    .appendingPathComponent("Support", isDirectory: true)
                    .appendingPathComponent(supportDirName, isDirectory: true)
                    .appendingPathComponent("target", isDirectory: true)
                    .appendingPathComponent("release", isDirectory: true)
                    .appendingPathComponent(binaryName, isDirectory: false)
                candidates.append(c)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path), fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func resolveGuestTerminalType() -> String {
        guard let hostTerm = ProcessInfo.processInfo.environment["TERM"], !hostTerm.isEmpty else {
            return "xterm-256color"
        }

        // Keep term value conservative so guest getty is not configured with unsafe/invalid input.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+._")
        guard hostTerm.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "xterm-256color"
        }
        guard hostTerm.count <= 64 else {
            return "xterm-256color"
        }
        return hostTerm
    }

    private func runCommand(_ executable: String, _ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

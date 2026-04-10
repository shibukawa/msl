import XCTest

final class ImagewriterScriptTests: XCTestCase {
    func testImagewriterSetupScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-setup.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertFalse(script.contains("\"$MSL_BIN\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
        XCTAssertTrue(script.contains("bootstrap_fs: ext4"))
        XCTAssertTrue(script.contains("$MSL_BIN list --all"))
        XCTAssertTrue(script.contains("[ -f \"$(instance_disk_path)\" ]"))
    }

    func testImagewriterBuildScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
        XCTAssertTrue(script.contains("IMAGE_SIZE_MB is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("IMAGE_SIZE_MB=\"${IMAGE_SIZE_MB:-65536}\""))
        XCTAssertTrue(script.contains("IMAGE_FS must be btrfs, erofs, or ext4"))
        XCTAssertTrue(script.contains("stage2_${IMAGE_FS}"))
        XCTAssertTrue(script.contains("ALLOW_SETUP_WHEN_MISSING"))
        XCTAssertTrue(script.contains("REQUIRED_IMAGEWRITER_FS"))
        XCTAssertTrue(script.contains("[ -f \"$(instance_disk_path)\" ]"))
        XCTAssertTrue(script.contains("required imagewriter instance is missing"))
        XCTAssertTrue(script.contains("verify_expected_fs_type \"$STAGE2_OUTPUT\" \"$IMAGE_FS\" \"$stage2_name\""))
        XCTAssertTrue(script.contains("verify_expected_fs_type \"$OUTPUT_RAW\" \"$IMAGE_FS\" \"final_output\""))
        XCTAssertTrue(script.contains("verify_guest_visible_fs_type \"$GUEST_FINAL_OUTPUT\" \"$IMAGE_FS\" \"final_output\""))
        XCTAssertTrue(script.contains("verify_guest_visible_fs_type \"$GUEST_IMAGEWRITER_DISK\" \"$REQUIRED_IMAGEWRITER_FS\" \"imagewriter_instance\""))
        XCTAssertTrue(script.contains("imagewriter_verified_fs context=$verify_context fs=$actual_fs path=$image_path"))
        XCTAssertTrue(script.contains("imagewriter_guest_verified_shared_output mode=$mode fs=$shared_output_fs output=$output"))
    }

    func testImagewriterGuestBuilderRequiresExplicitSize() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build-guest.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("size-mb is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("DEFAULT_SIZE_MB"))
        XCTAssertTrue(script.contains("--size-mb <n>"))
        XCTAssertTrue(script.contains("--fs-type <btrfs|erofs>"))
        XCTAssertTrue(script.contains("mkfs.erofs"))
        XCTAssertTrue(script.contains("blkid -p -s TYPE -o value"))
        XCTAssertTrue(script.contains("imagewriter_guest_verified_fs mode=$MODE fs=$actual_fs output=$OUTPUT_IMAGE"))
    }

    func testBuildImagewriterTargetUsesErofs() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)

        XCTAssertTrue(makefile.contains("two-stage ext4 -> erofs"))
        XCTAssertTrue(makefile.contains("readonly EROFS"))
        XCTAssertTrue(makefile.contains("IMAGE_FS=\"erofs\""))
    }
}

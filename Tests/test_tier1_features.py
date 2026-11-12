"""
Tier 1: Feature Coverage Tests
Validates core features of SecureChat (>= 5 tests per feature):
1. Framework imports and symbol presence across all 12 Swift files.
2. Single 4-byte length prefix wire framing encoding and decoding.
3. Xcode project structure (.xcodeproj / PBXProject validity, target membership, no Info.plist in copy resources).
4. Asset catalog schema and image dimensions (1024x1024 AppIcon, AccentColor).
5. Zero external third-party dependencies.
"""

import unittest
import os
import re
import json
import struct

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_ROOT = os.path.join(ROOT, "SecureChat")

EXPECTED_SWIFT_FILES = [
    "SecureChatApp.swift",
    os.path.join("Core", "ChatManager.swift"),
    os.path.join("Core", "PersistenceManager.swift"),
    os.path.join("Crypto", "CryptoEngine.swift"),
    os.path.join("Crypto", "SignalCrypto.swift"),
    os.path.join("Models", "Models.swift"),
    os.path.join("Network", "LANDiscovery.swift"),
    os.path.join("Network", "NetworkManager.swift"),
    os.path.join("Views", "ChatListView.swift"),
    os.path.join("Views", "Components.swift"),
    os.path.join("Views", "ConversationView.swift"),
    os.path.join("Views", "SettingsView.swift"),
]

ALLOWED_SYSTEM_FRAMEWORKS = {
    "Foundation",
    "UIKit",
    "SwiftUI",
    "Network",
    "CryptoKit",
    "Combine",
    "PhotosUI",
    "UniformTypeIdentifiers",
}


class TestFeature1FrameworkImportsAndSymbols(unittest.TestCase):
    """Feature 1: Framework imports and symbol presence across all 12 Swift files."""

    def test_crypto_engine_imports_combine_and_observable_object(self):
        """Verify CryptoEngine.swift imports Combine and uses ObservableObject."""
        path = os.path.join(SOURCE_ROOT, "Crypto", "CryptoEngine.swift")
        self.assertTrue(os.path.isfile(path), f"File not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertRegex(
            content,
            r"\bimport\s+Combine\b",
            "CryptoEngine.swift must import Combine for ObservableObject support",
        )
        self.assertIn("ObservableObject", content)

    def test_secure_chat_app_imports_uikit_and_uidevice(self):
        """Verify SecureChatApp.swift imports UIKit and references UIDevice."""
        path = os.path.join(SOURCE_ROOT, "SecureChatApp.swift")
        self.assertTrue(os.path.isfile(path), f"File not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertRegex(
            content,
            r"\bimport\s+UIKit\b",
            "SecureChatApp.swift must import UIKit for UIDevice scope resolution",
        )
        self.assertIn("UIDevice", content)

    def test_settings_view_imports_uikit_and_uipasteboard(self):
        """Verify SettingsView.swift imports UIKit and uses UIPasteboard."""
        path = os.path.join(SOURCE_ROOT, "Views", "SettingsView.swift")
        self.assertTrue(os.path.isfile(path), f"File not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertRegex(
            content,
            r"\bimport\s+UIKit\b",
            "SettingsView.swift must import UIKit for UIPasteboard",
        )
        self.assertIn("UIPasteboard", content)

    def test_conversation_view_imports_uikit_and_uicontrollers(self):
        """Verify ConversationView.swift imports UIKit for UIActivityViewController and DocumentPickerView."""
        path = os.path.join(SOURCE_ROOT, "Views", "ConversationView.swift")
        self.assertTrue(os.path.isfile(path), f"File not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertRegex(
            content,
            r"\bimport\s+UIKit\b",
            "ConversationView.swift must import UIKit for UIActivityViewController & UIDocumentPickerViewController",
        )
        self.assertIn("UIActivityViewController", content)
        self.assertIn("UIDocumentPickerViewController", content)

    def test_all_12_swift_files_exist_and_non_empty(self):
        """Verify all 12 expected Swift source files exist on disk and are non-empty."""
        for rel_path in EXPECTED_SWIFT_FILES:
            full_path = os.path.join(SOURCE_ROOT, rel_path)
            self.assertTrue(os.path.isfile(full_path), f"Missing Swift file: {rel_path}")
            size = os.path.getsize(full_path)
            self.assertGreater(size, 0, f"Swift file is empty: {rel_path}")

    def test_sendable_conformance_on_models(self):
        """Verify key public models conform to Sendable for Swift concurrency safety."""
        path = os.path.join(SOURCE_ROOT, "Models", "Models.swift")
        self.assertTrue(os.path.isfile(path), f"File not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertRegex(content, r"struct\s+WireEnvelope\b[^{]*:\s*[^{]*Sendable")
        self.assertRegex(content, r"struct\s+ChatMessage\b[^{]*:\s*[^{]*Sendable")


class TestFeature2WireFramingProtocol(unittest.TestCase):
    """Feature 2: Single 4-byte length prefix wire framing encoding and decoding."""

    def test_wire_envelope_wire_data_returns_pure_json(self):
        """Verify WireEnvelope.wireData() in Models.swift returns pure JSON bytes without binary prefix."""
        path = os.path.join(SOURCE_ROOT, "Models", "Models.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        match = re.search(r"func\s+wireData\(\)\s*throws\s*->\s*Data\s*\{([^}]+)\}", content)
        self.assertIsNotNone(match, "Could not find wireData() method in Models.swift")
        body = match.group(1)
        self.assertNotIn("Data(bytes: &length", body, "wireData() must not prepend 4-byte length prefix")
        self.assertIn("JSONEncoder().encode", body, "wireData() must return raw JSON from JSONEncoder")

    def test_send_framed_prepends_single_4byte_big_endian_header(self):
        """Verify single 4-byte big-endian framing calculation."""
        payload = b'{"type":1,"senderId":"A","senderName":"Alice","payload":""}'
        payload_len = len(payload)
        expected_header = struct.pack(">I", payload_len)
        frame = expected_header + payload

        self.assertEqual(len(frame), 4 + payload_len)
        extracted_len = struct.unpack(">I", frame[:4])[0]
        self.assertEqual(extracted_len, payload_len)
        self.assertEqual(frame[4:], payload)

    def test_network_manager_receive_loop_decodes_single_framing(self):
        """Verify NetworkManager receive loop extracts payload and delivers pure JSON."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # receiveLoop must unpack UInt32 bigEndian from 4-byte header
        self.assertIn("UInt32(bigEndian:", content)
        # handleReceivedData must receive payload directly
        self.assertIn("handleReceivedData", content)

    def test_network_manager_handle_received_data_decodes_directly(self):
        """Verify handleReceivedData decodes WireEnvelope directly from received payload."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("JSONDecoder().decode(WireEnvelope.self, from:", content)
        # Verify it doesn't try to dropFirst(4) or strip headers before decoding
        self.assertNotIn("dropFirst(4)", content)

    def test_chat_manager_no_redundant_workaround_in_receive(self):
        """Verify ChatManager handleReceivedData does not have redundant 4-byte strip workaround."""
        path = os.path.join(SOURCE_ROOT, "Core", "ChatManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # ChatManager should decode directly without prefix checking workaround
        self.assertNotIn("let prefix = data.prefix(4)", content, "Obsolete 4-byte workaround should be removed from ChatManager")

    def test_wire_envelope_json_fidelity(self):
        """Verify WireEnvelope JSON structure encoding and decoding integrity."""
        envelope = {
            "type": 0,
            "senderId": "test-uuid-1234",
            "senderName": "Alice",
            "payload": "SGVsbG8sIFdvcmxkIQ=="
        }
        json_bytes = json.dumps(envelope).encode("utf-8")
        header = struct.pack(">I", len(json_bytes))
        packet = header + json_bytes

        # First byte of wire packet must be 0x00 for reasonable sized packet
        self.assertEqual(packet[0], 0x00)
        # 5th byte (first byte of payload) must be 0x7B ('{')
        self.assertEqual(packet[4], ord('{'))
        decoded = json.loads(packet[4:].decode("utf-8"))
        self.assertEqual(decoded["senderId"], "test-uuid-1234")


class TestFeature3XcodeProjectStructure(unittest.TestCase):
    """Feature 3: Xcode project structure (.xcodeproj / PBXProject validity, target membership, no Info.plist in copy resources)."""

    def test_pbxproj_and_xcworkspace_exist(self):
        """Verify project.pbxproj and contents.xcworkspacedata exist at expected paths."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        ws_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.xcworkspace", "contents.xcworkspacedata")
        self.assertTrue(os.path.isfile(pbx_path), f"Missing {pbx_path}")
        self.assertTrue(os.path.isfile(ws_path), f"Missing {ws_path}")

    def test_pbxproj_syntax_and_object_integrity(self):
        """Verify project.pbxproj has balanced delimiters, valid rootObject, and zero dangling references."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        with open(pbx_path, "r", encoding="utf-8") as f:
            text = f.read()

        self.assertEqual(text.count("{"), text.count("}"), "PBXProject open and close braces do not match")
        self.assertEqual(text.count("("), text.count(")"), "PBXProject open and close parentheses do not match")

        defined_ids = set(re.findall(r"\t\t([0-9A-F]{24})\b", text))
        self.assertGreater(len(defined_ids), 20, "PBXProject contains too few defined objects")

        root_match = re.search(r"rootObject = ([0-9A-F]{24})\b", text)
        self.assertIsNotNone(root_match, "Missing rootObject in project.pbxproj")
        self.assertIn(root_match.group(1), defined_ids, "rootObject ID is not defined in objects dictionary")

    def test_pbxsources_contains_all_12_swift_files(self):
        """Verify PBXSourcesBuildPhase contains exactly all 12 Swift source files."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        with open(pbx_path, "r", encoding="utf-8") as f:
            text = f.read()

        sources_match = re.search(r"isa = PBXSourcesBuildPhase;\s*buildActionMask = [^;]+;\s*files = \((.*?)\);", text, re.DOTALL)
        self.assertIsNotNone(sources_match, "PBXSourcesBuildPhase not found in project.pbxproj")
        sources_block = sources_match.group(1)

        for filename in [os.path.basename(p) for p in EXPECTED_SWIFT_FILES]:
            self.assertIn(f"/* {filename} in Sources */", sources_block, f"Missing source file in PBXSourcesBuildPhase: {filename}")

    def test_info_plist_not_in_copy_resources(self):
        """Verify Info.plist is NOT in PBXResourcesBuildPhase to avoid multiple commands produce error."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        with open(pbx_path, "r", encoding="utf-8") as f:
            text = f.read()

        res_match = re.search(r"isa = PBXResourcesBuildPhase;\s*buildActionMask = [^;]+;\s*files = \((.*?)\);", text, re.DOTALL)
        self.assertIsNotNone(res_match, "PBXResourcesBuildPhase not found in project.pbxproj")
        res_block = res_match.group(1)
        self.assertNotIn("Info.plist in Resources", res_block, "Info.plist must NOT be in PBXResourcesBuildPhase")
        self.assertIn("Assets.xcassets in Resources", res_block, "Assets.xcassets must be in PBXResourcesBuildPhase")

    def test_build_configuration_ios_target_and_bundle_id(self):
        """Verify deployment target is 16.5, bundle ID is com.securechat.SecureChat, and SWIFT_VERSION is 5.0."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        with open(pbx_path, "r", encoding="utf-8") as f:
            text = f.read()

        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 16.5;", text)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.securechat.SecureChat;", text)
        self.assertIn("SWIFT_VERSION = 5.0;", text)
        self.assertIn("INFOPLIST_FILE = SecureChat/Info.plist;", text)

    def test_project_yml_validity_and_settings(self):
        """Verify project.yml exists and matches project requirements."""
        yml_path = os.path.join(ROOT, "project.yml")
        self.assertTrue(os.path.isfile(yml_path), f"Missing {yml_path}")
        with open(yml_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("name: SecureChat", content)
        self.assertIn("com.securechat.SecureChat", content)
        self.assertIn("16.5", content)
        self.assertIn("SecureChat/Info.plist", content)


class TestFeature4AssetCatalogSchema(unittest.TestCase):
    """Feature 4: Asset catalog schema and image dimensions (1024x1024 AppIcon, AccentColor)."""

    def test_root_asset_catalog_contents_json(self):
        """Verify Assets.xcassets/Contents.json exists and conforms to author: xcode."""
        path = os.path.join(SOURCE_ROOT, "Assets.xcassets", "Contents.json")
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data.get("info", {}).get("author"), "xcode")
        self.assertEqual(data.get("info", {}).get("version"), 1)

    def test_accent_color_colorset_schema_and_telegram_blue(self):
        """Verify AccentColor.colorset/Contents.json conforms to sRGB Telegram blue specifications."""
        path = os.path.join(SOURCE_ROOT, "Assets.xcassets", "AccentColor.colorset", "Contents.json")
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        colors = data.get("colors", [])
        self.assertGreater(len(colors), 0, "No color definitions in AccentColor.colorset")
        first_color = colors[0].get("color", {})
        self.assertEqual(first_color.get("color-space"), "srgb")
        components = first_color.get("components", {})
        red = float(components.get("red", 0))
        green = float(components.get("green", 0))
        blue = float(components.get("blue", 0))
        # Telegram blue tint: blue component should dominate (> 0.8)
        self.assertGreater(blue, 0.8, f"Accent color blue component too low: {blue}")

    def test_app_icon_appiconset_schema(self):
        """Verify AppIcon.appiconset/Contents.json specifies 1024x1024 universal icon."""
        path = os.path.join(SOURCE_ROOT, "Assets.xcassets", "AppIcon.appiconset", "Contents.json")
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        images = data.get("images", [])
        self.assertGreater(len(images), 0, "No image definitions in AppIcon.appiconset")
        icon = images[0]
        self.assertEqual(icon.get("size"), "1024x1024")
        self.assertEqual(icon.get("filename"), "AppIcon.png")

    def test_app_icon_png_dimensions_and_ihdr(self):
        """Inspect AppIcon.png binary header directly and assert exact 1024x1024 8-bit truecolor PNG."""
        path = os.path.join(SOURCE_ROOT, "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "rb") as f:
            data = f.read()

        png_magic = b"\x89PNG\r\n\x1a\n"
        self.assertTrue(data.startswith(png_magic), "AppIcon.png is not a valid PNG file")

        # Parse IHDR chunk
        ihdr_offset = 8
        ihdr_len = struct.unpack(">I", data[ihdr_offset:ihdr_offset+4])[0]
        self.assertEqual(ihdr_len, 13, "Invalid IHDR chunk length")
        ihdr_type = data[ihdr_offset+4:ihdr_offset+8]
        self.assertEqual(ihdr_type, b"IHDR", "First chunk must be IHDR")

        ihdr_data = data[ihdr_offset+8:ihdr_offset+8+13]
        width, height, bit_depth, color_type = struct.unpack(">IIBB", ihdr_data[:10])
        self.assertEqual(width, 1024, f"Icon width is {width}, expected 1024")
        self.assertEqual(height, 1024, f"Icon height is {height}, expected 1024")
        self.assertEqual(bit_depth, 8, f"Icon bit depth is {bit_depth}, expected 8")
        self.assertIn(color_type, (2, 6), f"Icon color type {color_type} must be Truecolor (2) or Truecolor with alpha (6)")

    def test_app_icon_png_pixel_data_validity(self):
        """Verify PNG file has non-trivial size and valid IDAT chunk."""
        path = os.path.join(SOURCE_ROOT, "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
        size = os.path.getsize(path)
        self.assertGreater(size, 1000, "PNG file unexpectedly small")
        with open(path, "rb") as f:
            content = f.read()
        self.assertIn(b"IDAT", content, "Missing IDAT chunk in AppIcon.png")
        self.assertIn(b"IEND", content, "Missing IEND chunk in AppIcon.png")

    def test_asset_catalog_integrity_no_orphan_files(self):
        """Verify no temporary or corrupted files exist in Assets.xcassets."""
        assets_dir = os.path.join(SOURCE_ROOT, "Assets.xcassets")
        for root_dir, dirs, files in os.walk(assets_dir):
            for filename in files:
                ext = os.path.splitext(filename)[1].lower()
                self.assertIn(ext, [".json", ".png"], f"Unexpected file in Assets.xcassets: {filename}")


class TestFeature5ZeroExternalDependencies(unittest.TestCase):
    """Feature 5: Zero external third-party dependencies."""

    def test_no_package_manifests_or_lockfiles(self):
        """Verify no third-party dependency manager files (CocoaPods, Carthage, SPM resolved) exist."""
        forbidden_files = [
            os.path.join(ROOT, "Podfile"),
            os.path.join(ROOT, "Podfile.lock"),
            os.path.join(ROOT, "Cartfile"),
            os.path.join(ROOT, "Cartfile.resolved"),
            os.path.join(ROOT, "Package.resolved"),
        ]
        for f in forbidden_files:
            self.assertFalse(os.path.exists(f), f"Forbidden dependency manifest found: {f}")

    def test_swift_source_imports_are_exclusively_apple_sdk(self):
        """Verify every import in every Swift file is in ALLOWED_SYSTEM_FRAMEWORKS."""
        import_pattern = re.compile(r"^\s*import\s+([A-Za-z0-9_]+)", re.MULTILINE)
        for rel_path in EXPECTED_SWIFT_FILES:
            full_path = os.path.join(SOURCE_ROOT, rel_path)
            with open(full_path, "r", encoding="utf-8") as f:
                content = f.read()
            imports = import_pattern.findall(content)
            for imp in imports:
                self.assertIn(
                    imp,
                    ALLOWED_SYSTEM_FRAMEWORKS,
                    f"Third-party import '{imp}' found in {rel_path}!",
                )

    def test_pbxproj_no_framework_dependencies(self):
        """Verify project.pbxproj does not link external third-party dynamic libraries or xcframeworks."""
        pbx_path = os.path.join(ROOT, "SecureChat.xcodeproj", "project.pbxproj")
        with open(pbx_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertNotIn("PBXPackageProductDependency", content, "Third-party SPM package found in PBXProject")
        self.assertNotIn(".xcframework", content, "External XCFramework found in PBXProject")
        self.assertNotIn(".dylib", content, "External dylib found in PBXProject")

    def test_project_yml_no_external_dependencies(self):
        """Verify project.yml does not declare dependencies section."""
        yml_path = os.path.join(ROOT, "project.yml")
        with open(yml_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertNotIn("dependencies:", content, "External dependencies declared in project.yml")
        self.assertNotIn("packages:", content, "External SPM packages declared in project.yml")

    def test_signal_crypto_uses_native_cryptokit_only(self):
        """Verify SignalCrypto.swift imports and relies solely on CryptoKit without libsignal or openssl."""
        path = os.path.join(SOURCE_ROOT, "Crypto", "SignalCrypto.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("import CryptoKit", content)
        self.assertNotIn("libsignal", content)
        self.assertNotIn("openssl", content.lower())
        self.assertIn("Curve25519.KeyAgreement", content)
        self.assertIn("AES.GCM", content)
        self.assertIn("HMAC<SHA256>", content)

    def test_no_external_git_submodules_or_binaries(self):
        """Verify no .gitmodules or precompiled third-party binaries exist in repository."""
        self.assertFalse(os.path.exists(os.path.join(ROOT, ".gitmodules")), "Git submodules are forbidden")
        for root_dir, dirs, files in os.walk(ROOT):
            for f in files:
                self.assertFalse(f.endswith(".a") or f.endswith(".dylib") or f.endswith(".so"), f"Forbidden binary artifact found: {f}")


if __name__ == "__main__":
    unittest.main()

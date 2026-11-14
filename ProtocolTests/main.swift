// Headless multi-process protocol test for SecureChat v1.2.
// Roles A, B, C run concurrently as separate processes on one Mac; B2 is B
// restarted with the same data directory. They talk over real TCP sockets.
import Foundation
import CryptoKit

let ids = [
    "A": "A0000000-0000-0000-0000-00000000000A",
    "B": "B0000000-0000-0000-0000-00000000000B",
    "C": "C0000000-0000-0000-0000-00000000000C",
]

@MainActor
final class Runner {
    let role: String
    let dir: String
    let start = Date()
    var cm: ChatManager!
    var failures = 0
    var passes = 0

    init(role: String, dir: String) {
        self.role = role
        self.dir = dir
    }

    var me: String { ids[role == "B2" ? "B" : role]! }
    let A = ids["A"]!, B = ids["B"]!, C = ids["C"]!

    func log(_ s: String) {
        let t = String(format: "%6.2f", Date().timeIntervalSince(start))
        print("[\(role) \(t)] \(s)")
        fflush(stdout)
    }

    func check(_ name: String, _ ok: Bool) {
        if ok { passes += 1 } else { failures += 1 }
        log((ok ? "PASS " : "FAIL ") + name)
    }

    func at(_ t: Double, _ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let delay = t - Date().timeIntervalSince(self.start)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            block()
        }
    }

    func finish(at t: Double) {
        at(t) {
            self.dumpState()
            self.log("RESULT \(self.failures == 0 ? "PASS" : "FAIL") passes=\(self.passes) failures=\(self.failures)")
            self.cm.persistence.flushNow()
            exit(self.failures == 0 ? 0 : 1)
        }
    }

    func dumpState() {
        for conv in cm.conversations.values {
            log("conv \(conv.id.prefix(8)) name=\(conv.peer.displayName) online=\(conv.peer.isOnline) group=\(conv.group?.name ?? "-") msgs=\(conv.messages.count)")
            for m in conv.messages {
                log("   msg from=\(m.senderId.prefix(1)) status=\(m.status) text=\(m.text.prefix(40)) pending=\(m.pendingRecipients?.map { String($0.prefix(1)) } ?? []) complete=\(String(describing: m.attachment?.isComplete))")
            }
        }
    }

    func messages(_ conv: String) -> [ChatMessage] { cm.conversations[conv]?.messages ?? [] }
    func find(_ conv: String, _ text: String) -> ChatMessage? { messages(conv).first { $0.text == text } }
    func groupId() -> String? { cm.conversations.values.first { $0.isGroup }?.id }

    func writePort() {
        Task { @MainActor in
            for _ in 0..<40 {
                if let port = self.cm.networkManager.listeningPort, port > 0 {
                    try? "\(port)".write(toFile: "\(self.dir)/\(self.role).port", atomically: true, encoding: .utf8)
                    self.log("listening on \(port)")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.log("listener port never became available")
        }
    }

    func readPort(_ role: String) -> UInt16 {
        UInt16((try? String(contentsOfFile: "\(dir)/\(role).port", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func run() {
        let persistence = PersistenceManager()
        cm = ChatManager(deviceId: me, displayName: "User-\(role)", persistence: persistence)
        log("started as \(me)")
        writePort()
        let env = ProcessInfo.processInfo.environment
        let filePath = env["SC_TEST_FILE"] ?? ""
        let fileSha = env["SC_TEST_SHA"] ?? ""

        switch role {
        case "A":
            at(10) { self.cm.sendMessage("hello from A", to: self.B) }
            at(15) {
                self.check("A got text from B", self.find(self.B, "hello from B") != nil)
                self.check("A text delivered to B", (self.find(self.B, "hello from A")?.status ?? .sending) >= .delivered)
                if let m = self.find(self.B, "hello from B") {
                    self.cm.sendMessage("reply to B", to: self.B, replyTo: m)
                }
            }
            at(30) {
                let fileMsg = self.messages(self.B).first { $0.contentType == .file }
                self.check("A received file message", fileMsg != nil)
                self.check("A file transfer complete", fileMsg?.attachment?.isComplete == true)
                if let a = fileMsg?.attachment, let rel = a.localFile,
                   let data = try? Data(contentsOf: AttachmentStore.location(rel)) {
                    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    self.check("A file sha256 matches (\(data.count) bytes)", sha == fileSha)
                } else {
                    self.check("A file readable", false)
                }
                self.check("B's deleted-for-both message is gone on A", self.find(self.B, "hello from B") == nil)
                self.check("A sees B's new name", self.cm.conversations[self.B]?.peer.displayName == "Bob Renamed")
                self.check("A sees C online", self.cm.isConnected(self.C))
                self.cm.createGroup(name: "Test Group", members: [self.B, self.C])
            }
            at(33) {
                if let g = self.groupId() { self.cm.sendMessage("group hi from A", to: g) }
            }
            at(42) {
                guard let g = self.groupId() else { self.check("A has group", false); return }
                self.check("A got group msg from C", self.find(g, "group hi from C") != nil)
                self.check("A group msg delivered to all", self.find(g, "group hi from A")?.pendingRecipients == nil)
            }
            at(47) {
                self.check("A sees B offline after exit", !self.cm.isConnected(self.B))
                self.cm.sendMessage("queued for B", to: self.B)
            }
            at(66) {
                self.check("A got message from restarted B", self.find(self.B, "after restart") != nil)
                self.check("queued message delivered after reconnect", (self.find(self.B, "queued for B")?.status ?? .sending) >= .delivered)
            }
            finish(at: 70)

        case "B":
            at(2) { self.cm.connectByIP("127.0.0.1", port: 47823) }
            at(10) { self.cm.sendMessage("hello from B", to: self.A) }
            at(12) { self.cm.sendFile(at: URL(fileURLWithPath: filePath), to: self.A) }
            at(15) {
                self.check("B got text from A", self.find(self.A, "hello from A") != nil)
                self.check("B text delivered to A", (self.find(self.A, "hello from B")?.status ?? .sending) >= .delivered)
            }
            at(19) { self.cm.updateDisplayName("Bob Renamed") }
            at(20) {
                let reply = self.find(self.A, "reply to B")
                let mine = self.find(self.A, "hello from B")
                self.check("B got reply with replyToId", reply != nil && reply?.replyToId == mine?.id && mine != nil)
                if let mine { self.cm.deleteMessages([mine.id], in: self.A, forEveryone: true) }
            }
            at(28) {
                let f = self.messages(self.A).first { $0.contentType == .file }
                self.check("B file delivered", (f?.status ?? .sending) >= .delivered)
            }
            at(40) {
                guard let g = self.groupId() else { self.check("B has group", false); return }
                self.check("B group name synced", self.cm.conversations[g]?.group?.name == "Test Group")
                self.check("B got group msg from A", self.find(g, "group hi from A") != nil)
                self.check("B got group msg from C", self.find(g, "group hi from C") != nil)
            }
            finish(at: 43)

        case "C":
            at(3) { self.cm.connectByIP("127.0.0.1", port: 47823) }
            at(6) {
                let p = self.readPort("B")
                self.log("B port = \(p)")
                self.check("C found B's port", p > 0)
                if p > 0 { self.cm.connectByIP("127.0.0.1", port: p) }
            }
            at(37) {
                guard let g = self.groupId() else { self.check("C has group", false); return }
                self.cm.sendMessage("group hi from C", to: g)
            }
            at(41) {
                guard let g = self.groupId() else { return }
                self.check("C got group msg from A", self.find(g, "group hi from A") != nil)
                self.check("C sees B's new name", self.cm.conversations[self.B]?.peer.displayName == "Bob Renamed")
            }
            finish(at: 44)

        case "B2":
            at(1) { self.cm.connectByIP("127.0.0.1", port: 47823) }
            at(7) { self.cm.sendMessage("after restart", to: self.A) }
            at(12) {
                self.check("B2 got queued message", self.find(self.A, "queued for B") != nil)
                self.check("B2 still has history", self.find(self.A, "hello from A") != nil)
            }
            finish(at: 14)

        default:
            log("unknown role")
            exit(2)
        }
    }
}

let role = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "A"
let dir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp"
MainActor.assumeIsolated {
    let runner = Runner(role: role, dir: dir)
    runner.run()
    // keep alive
    _ = Unmanaged.passRetained(runner)
}
RunLoop.main.run()

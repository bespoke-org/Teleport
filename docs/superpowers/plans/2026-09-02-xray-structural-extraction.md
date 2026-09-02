# Xray Structural Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish clear System Proxy, VPN, Xray configuration, installation, geodata, and privileged-helper source boundaries without changing runtime behavior.

**Architecture:** This plan implements only Phase 0/1 of the approved architecture. It keeps the existing synchronous `ConnectionBackend`, UNIX socket protocol, AppleScript installer, generated helper shell scripts, route behavior, persisted state, and Xray JSON unchanged while moving code into vertical slices and splitting the privileged helper into focused files. Later plans will introduce `ConnectionProvider`, XPC, `SMAppService`, authoritative session state, route journaling, curated geodata, and release notarization.

**Tech Stack:** Swift 5, SwiftUI application target, Foundation, Darwin, Security, Xcode 26 project with a file-system-synchronized app source group, shell-based verification scripts, `just` recipes.

**Spec:** `docs/superpowers/specs/2026-09-02-xray-macos-architecture-design.md`

## Global Constraints

- Canonical base is `nrydanov/split-tunneling`.
- Preserve all existing uncommitted work; never reset, overwrite, stash-pop, or broadly stage user-owned changes.
- Before implementation commits, the owner must checkpoint or explicitly authorize inclusion of existing dirty hunks in files this plan moves.
- Phase 1 is strictly behavior-preserving: no new provider API, XPC, `SMAppService`, route behavior, IPv6 behavior, timeout behavior, state format, or geodata policy.
- Do not merge `nrydanov/startup-perf`, `worktree-auto-connect-on-launch`, or `worktree-nrydanov+vpn-ipv6-routing` during this plan.
- Do not create a Swift Package, framework target, or additional executable target.
- Keep all added source comments in English.
- Use `edit` for targeted changes and `write` for new files/full rewrites; do not mutate source files with shell redirection, inline scripts, or stream editors.
- Run `just verify` before the first structural change and after the final task.
- Run the smallest relevant verification recipe after every task.
- A commit step assumes the working tree baseline has first been made safe according to the third constraint; otherwise stop before committing and report the exact dirty paths.

---

## File Structure Locked by This Plan

### App target after extraction

```text
teleport/
├── Connection/
│   ├── ConnectionBackend.swift                 # Existing protocol only
│   └── ConnectionBackendFactory.swift          # Existing mode-to-backend factory only
├── XrayCore/
│   └── XrayConfigurationWriter.swift            # Existing JSON generation, unchanged
├── SystemProxy/
│   ├── SystemProxyConnectionBackend.swift       # Moved from ConnectionBackend.swift
│   ├── SystemProxyService.swift                 # Moved from Proxy/
│   └── XrayRuntimeManager.swift                 # Existing user-owned child process
├── VPN/
│   ├── XrayTunConnectionBackend.swift           # Moved from ConnectionBackendFactory.swift
│   ├── PrivilegedHelperClient.swift
│   ├── PrivilegedXrayRuntimeManager.swift
│   ├── XrayTunRouteInspector.swift
│   └── XrayTunSessionState.swift
├── HelperInstallation/
│   ├── BundledArtifactPolicy.swift
│   ├── BundledArtifactVerifier.swift
│   ├── PrivilegedHelperInstaller.swift
│   └── PrivilegedShellRunner.swift
└── Geodata/
    └── GeodataUpdateService.swift
```

Type names and public/internal signatures remain unchanged except for the new artifact-policy/verifier types consumed only by the installer.

### Helper target after extraction

```text
TeleportPrivilegedHelper/
├── IPC/
│   ├── HelperMessages.swift
│   ├── HelperServer.swift
│   └── ClientAuthenticator.swift
├── Session/
│   └── XrayTunController.swift
├── Xray/
│   └── ManagedXrayProcess.swift
├── Routing/
│   └── XrayTunScriptBuilder.swift
├── Support/
│   ├── HelperConfiguration.swift
│   ├── HelperPlatform.swift
│   └── HelperShellRunner.swift
└── main.swift
```

`main.swift` contains only SIGPIPE setup, server construction, top-level error reporting, and process exit.

---

### Task 1: Establish a verified characterization baseline

**Files:**
- Modify: `scripts/verify_split_tunneling.swift:391-397`
- Modify: `justfile:10,145-178`

**Interfaces:**
- Consumes: Existing helper source and existing `just verify` recipes.
- Produces: `privilegedHelperSource()` test helper that remains valid after helper code is split across files; unchanged runtime behavior.

- [ ] **Step 1: Inspect and record the dirty baseline**

Run:

```bash
git branch --show-current
git status --short
git diff --check
git worktree list
```

Expected:

- Current branch is `nrydanov/split-tunneling`.
- Existing modified/untracked paths are recorded before any implementation edit.
- `git diff --check` exits successfully.

If the baseline differs from the paths documented in the current conversation, stop and report the difference before editing.

- [ ] **Step 2: Run the complete baseline verification**

Run:

```bash
just verify
```

Expected:

- Xcode Debug build succeeds.
- `verify_core`, subscription, health, split-tunneling, geodata, and persistence checks print their respective `all checks passed` messages.
- Exit status is zero.

If it fails, stop and investigate the baseline; do not begin file extraction.

- [ ] **Step 3: Generalize the helper source characterization test**

In `scripts/verify_split_tunneling.swift`, replace the direct read of only `main.swift` with this helper and call it from `testHelperAddsScopedDirectRoutes()`:

```swift
private static func privilegedHelperSource() throws -> String {
    let root = URL(fileURLWithPath: "TeleportPrivilegedHelper", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        preconditionFailure("expected to enumerate privileged helper sources")
    }

    let sourceURLs = enumerator
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }

    precondition(!sourceURLs.isEmpty, "expected privileged helper Swift sources")
    return try sourceURLs
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
}
```

The test body becomes:

```swift
private static func testHelperAddsScopedDirectRoutes() throws {
    let helperSource = try privilegedHelperSource()
    precondition(helperSource.contains("cleanup_direct_routes"), "expected helper to clean up scoped direct routes")
    precondition(helperSource.contains("protect_direct_routes"), "expected helper to install scoped direct routes")
    precondition(helperSource.contains("-ifscope \"$OUTBOUND_INTERFACE\""), "expected direct routes to be scoped to the physical interface")
    precondition(helperSource.contains("route add -net 0.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected lower IPv4 direct route through the physical gateway")
    precondition(helperSource.contains("route add -net 128.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected upper IPv4 direct route through the physical gateway")
}
```

- [ ] **Step 4: Run the characterization test before moving files**

Run:

```bash
just verify-split-tunneling
```

Expected: `verify_split_tunneling: all checks passed`.

This is a green characterization test: it must pass both before and after extraction.

- [ ] **Step 5: Commit the baseline test change when the dirty baseline is safe**

```bash
git add scripts/verify_split_tunneling.swift
git commit -m "test: make helper source checks layout independent"
```

Do not include unrelated dirty files in this commit.

---

### Task 2: Extract Xray configuration and geodata slices

**Files:**
- Move unchanged: `teleport/Xray/XrayConfigurationWriter.swift` → `teleport/XrayCore/XrayConfigurationWriter.swift`
- Move unchanged: `teleport/Xray/GeodataUpdateService.swift` → `teleport/Geodata/GeodataUpdateService.swift`
- Modify: `justfile:10`

**Interfaces:**
- Consumes: Existing `XrayConfigurationWriter`, `GeodataUpdateService`, and all current call sites.
- Produces: The same type names and method signatures at new filesystem locations.

- [ ] **Step 1: Move the two source files without editing declarations or method bodies**

Move exactly these complete files:

```text
teleport/Xray/XrayConfigurationWriter.swift
    → teleport/XrayCore/XrayConfigurationWriter.swift

teleport/Xray/GeodataUpdateService.swift
    → teleport/Geodata/GeodataUpdateService.swift
```

The app target uses a file-system-synchronized `teleport` root group, so no `project.pbxproj` source membership edit is required.

Verify that the moved files still declare:

```swift
struct XrayConfigurationWriter
struct GeodataUpdateService
enum GeodataKind
enum GeodataUpdateError
```

- [ ] **Step 2: Update standalone verification source globs**

After both destination directories exist, change `verify_sources` to include them while retaining the still-populated legacy directories:

```make
verify_sources := "teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/Xray/*.swift teleport/XrayCore/*.swift teleport/Geodata/*.swift teleport/Proxy/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/PrivilegedHelperConstants.swift"
```

- [ ] **Step 3: Verify config generation and geodata behavior**

Run:

```bash
just verify-core
just verify-split-tunneling
just verify-geodata
just build-debug
```

Expected: all three scripts print `all checks passed`; Xcode build succeeds.

- [ ] **Step 4: Confirm no semantic diff was introduced**

Run:

```bash
git diff --check
git diff --find-renames --stat -- teleport/Xray teleport/XrayCore teleport/Geodata justfile
```

Expected: the two source changes are detected as moves plus the deliberate `justfile` glob change; no method-body edit is present.

- [ ] **Step 5: Commit the slice extraction**

```bash
git add teleport/XrayCore teleport/Geodata teleport/Xray/XrayConfigurationWriter.swift teleport/Xray/GeodataUpdateService.swift justfile
git commit -m "refactor: separate Xray config and geodata slices"
```

---

### Task 3: Extract the System Proxy vertical slice

**Files:**
- Move unchanged: `teleport/Xray/XrayRuntimeManager.swift` → `teleport/SystemProxy/XrayRuntimeManager.swift`
- Move unchanged: `teleport/Proxy/SystemProxyService.swift` → `teleport/SystemProxy/SystemProxyService.swift`
- Create: `teleport/SystemProxy/SystemProxyConnectionBackend.swift`
- Modify: `teleport/Connection/ConnectionBackend.swift`
- Modify: `justfile:10`

**Interfaces:**
- Consumes: Existing `ConnectionBackend`, `XrayRuntimeManager`, `SystemProxyService`, `XrayConfigurationWriter`.
- Produces: Existing `SystemProxyConnectionBackend` with the exact same initializer and protocol behavior, now in the System Proxy slice.

- [ ] **Step 1: Capture the existing backend body**

Before editing, verify `teleport/Connection/ConnectionBackend.swift` contains exactly two top-level declarations:

```swift
protocol ConnectionBackend: AnyObject
final class SystemProxyConnectionBackend: ConnectionBackend
```

Run:

```bash
rg -n '^(protocol ConnectionBackend|final class SystemProxyConnectionBackend)' teleport/Connection/ConnectionBackend.swift
```

Expected: one match for each declaration.

- [ ] **Step 2: Move System Proxy runtime files unchanged**

Move:

```text
teleport/Xray/XrayRuntimeManager.swift
    → teleport/SystemProxy/XrayRuntimeManager.swift

teleport/Proxy/SystemProxyService.swift
    → teleport/SystemProxy/SystemProxyService.swift
```

Do not rename either type during this phase.

- [ ] **Step 3: Move the backend class into its own file**

Create `teleport/SystemProxy/SystemProxyConnectionBackend.swift` by extracting the complete source range beginning with `final class SystemProxyConnectionBackend: ConnectionBackend` and ending at that class's closing brace. Prefix it with `import Foundation`. Preserve the initializer, rollback behavior, stop ordering, and `startRuntime()` byte-for-byte; do not change any statement, catch clause, or method signature.

Rewrite `teleport/Connection/ConnectionBackend.swift` to retain only:

```swift
import Foundation

protocol ConnectionBackend: AnyObject {
    func hasRestorableState() -> Bool
    func hasActiveRuntimeSession() -> Bool
    func restorePreviousState() throws
    func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func stop(shouldDisableProxy: Bool) throws
    func teardown()
}
```

- [ ] **Step 4: Replace the Proxy glob with the System Proxy slice**

Once `teleport/Proxy` contains no Swift source, set `verify_sources` to:

```make
verify_sources := "teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/Xray/*.swift teleport/XrayCore/*.swift teleport/Geodata/*.swift teleport/SystemProxy/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/PrivilegedHelperConstants.swift"
```

- [ ] **Step 5: Verify System Proxy behavior and full app compilation**

Run:

```bash
just verify-core
just build-debug
```

Expected: core checks pass, including runtime missing-binary behavior; Debug build succeeds.

- [ ] **Step 6: Commit the System Proxy slice**

```bash
git add teleport/Connection/ConnectionBackend.swift teleport/SystemProxy teleport/Xray/XrayRuntimeManager.swift teleport/Proxy/SystemProxyService.swift justfile
git commit -m "refactor: extract System Proxy runtime slice"
```

---

### Task 4: Extract the app-side VPN vertical slice

**Files:**
- Move unchanged: `teleport/Xray/PrivilegedHelperClient.swift` → `teleport/VPN/PrivilegedHelperClient.swift`
- Move unchanged: `teleport/Xray/PrivilegedXrayRuntimeManager.swift` → `teleport/VPN/PrivilegedXrayRuntimeManager.swift`
- Move unchanged: `teleport/Xray/XrayTunRouteInspector.swift` → `teleport/VPN/XrayTunRouteInspector.swift`
- Move unchanged: `teleport/Xray/XrayTunSessionState.swift` → `teleport/VPN/XrayTunSessionState.swift`
- Create: `teleport/VPN/XrayTunConnectionBackend.swift`
- Modify: `teleport/Connection/ConnectionBackendFactory.swift`
- Modify: `justfile:10`

**Interfaces:**
- Consumes: Existing VPN client, runtime manager, route inspector, session DTOs, and backend factory.
- Produces: The same `XrayTunConnectionBackend` and `XrayTunConnectionError` behavior at a new location; factory remains the only mode switch.

- [ ] **Step 1: Move app-side VPN support files unchanged**

Move the four listed files into `teleport/VPN/`. Preserve all existing uncommitted comments and code in those files exactly.

- [ ] **Step 2: Extract VPN backend and error**

Create `teleport/VPN/XrayTunConnectionBackend.swift` with `import Foundation`, followed by the complete existing `XrayTunConnectionBackend` declaration and complete existing `XrayTunConnectionError` declaration extracted from `ConnectionBackendFactory.swift`. Retain the current English audit annotations and every executable statement unchanged.

Rewrite `teleport/Connection/ConnectionBackendFactory.swift` to contain only:

```swift
import Foundation

/// Selects the orchestration strategy. System Proxy runs Xray as the user and
/// changes macOS proxy settings; VPN delegates root Xray and route ownership to
/// the privileged-helper path.
struct ConnectionBackendFactory {
    func makeBackend(for mode: ConnectionMode) -> ConnectionBackend {
        switch mode {
        case .systemProxy:
            return SystemProxyConnectionBackend(
                runtimeManager: XrayRuntimeManager(),
                proxyService: SystemProxyService()
            )
        case .vpn:
            return XrayTunConnectionBackend(
                runtimeManager: PrivilegedXrayRuntimeManager(),
                routeInspector: XrayTunRouteInspector(),
                systemProxyService: SystemProxyService()
            )
        }
    }
}
```

- [ ] **Step 3: Update verification globs**

Ensure `verify_sources` contains `teleport/VPN/*.swift`. Keep `teleport/Xray/*.swift` temporarily because installer files remain there until Task 5.

- [ ] **Step 4: Verify VPN config and backend compilation**

Run:

```bash
just verify-split-tunneling
just verify-geodata
just build-debug
```

Expected: checks pass and both app/helper targets build.

- [ ] **Step 5: Commit the VPN slice**

```bash
git add teleport/VPN teleport/Connection/ConnectionBackendFactory.swift teleport/Xray/PrivilegedHelperClient.swift teleport/Xray/PrivilegedXrayRuntimeManager.swift teleport/Xray/XrayTunRouteInspector.swift teleport/Xray/XrayTunSessionState.swift justfile
git commit -m "refactor: extract app-side VPN runtime slice"
```

---

### Task 5: Separate helper installation and artifact verification

**Files:**
- Move: `teleport/Xray/PrivilegedHelperInstaller.swift` → `teleport/HelperInstallation/PrivilegedHelperInstaller.swift`
- Move unchanged: `teleport/Xray/PrivilegedShellRunner.swift` → `teleport/HelperInstallation/PrivilegedShellRunner.swift`
- Create: `teleport/HelperInstallation/BundledArtifactPolicy.swift`
- Create: `teleport/HelperInstallation/BundledArtifactVerifier.swift`
- Modify: `scripts/verify_core.swift`
- Modify: `justfile:10`

**Interfaces:**
- Consumes: Existing hardcoded app signing requirement, Xray SHA-256, `codesign`, and `shasum` behavior.
- Produces:

```swift
struct BundledArtifactPolicy: Sendable {
    static let current: BundledArtifactPolicy
    let codeSigningRequirement: String
    let xraySHA256: String
}

struct BundledArtifactVerifier: Sendable {
    let policy: BundledArtifactPolicy
    func verify(appBundleURL: URL, helperURL: URL, runtimeURL: URL) throws
    func verifyCodeSignature(at url: URL) throws
    func verifyXrayHash(_ runtimeURL: URL) throws
}
```

- [ ] **Step 1: Add a focused hash characterization check**

Add this call to `VerifyCore.main()`:

```swift
try testBundledArtifactVerifierAcceptsExpectedHash()
```

Add the test:

```swift
private static func testBundledArtifactVerifierAcceptsExpectedHash() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("teleport-empty-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data().write(to: fileURL)

    let policy = BundledArtifactPolicy(
        codeSigningRequirement: "unused-by-hash-test",
        xraySHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    try BundledArtifactVerifier(policy: policy).verifyXrayHash(fileURL)
}
```

- [ ] **Step 2: Run the new test to verify the type is absent**

Run:

```bash
just verify-core
```

Expected: compilation fails because `BundledArtifactPolicy` and `BundledArtifactVerifier` do not exist.

- [ ] **Step 3: Create the policy**

Create `BundledArtifactPolicy.swift`:

```swift
import Foundation

struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        codeSigningRequirement: "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\"",
        xraySHA256: "650e6edf792ce808554e94f891db5271c77a7c2e80188beaafbf24883b3b84a0"
    )

    let codeSigningRequirement: String
    let xraySHA256: String
}
```

- [ ] **Step 4: Extract the verifier with existing process behavior**

Create `BundledArtifactVerifier.swift` with the existing process behavior and error mapping:

```swift
import Foundation

struct BundledArtifactVerifier: Sendable {
    let policy: BundledArtifactPolicy

    init(policy: BundledArtifactPolicy = .current) {
        self.policy = policy
    }

    func verify(appBundleURL: URL, helperURL: URL, runtimeURL: URL) throws {
        try verifyCodeSignature(at: appBundleURL)
        try verifyCodeSignature(at: helperURL)
        try verifyXrayHash(runtimeURL)
    }

    func verifyCodeSignature(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "--requirement", policy.codeSigningRequirement,
            url.path
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegedHelperInstallerError.installFailed(stderr.isEmpty ? "Teleport bundle signature verification failed." : stderr)
        }
    }

    func verifyXrayHash(_ runtimeURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", runtimeURL.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegedHelperInstallerError.installFailed(stderr.isEmpty ? "Could not verify bundled Xray runtime." : stderr)
        }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let digest = output.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard digest.caseInsensitiveCompare(policy.xraySHA256) == .orderedSame else {
            throw PrivilegedHelperInstallerError.installFailed("Bundled Xray runtime hash verification failed.")
        }
    }
}
```

- [ ] **Step 5: Inject policy and verifier into the installer**

Move `PrivilegedHelperInstaller.swift` and `PrivilegedShellRunner.swift` into `teleport/HelperInstallation/`.

Change installer stored properties and initializer to:

```swift
private let bundle: Bundle
private let shellRunner: PrivilegedShellRunner
private let artifactPolicy: BundledArtifactPolicy
private let artifactVerifier: BundledArtifactVerifier

init(
    bundle: Bundle = .main,
    shellRunner: PrivilegedShellRunner = PrivilegedShellRunner(),
    artifactPolicy: BundledArtifactPolicy = .current,
    artifactVerifier: BundledArtifactVerifier? = nil
) {
    self.bundle = bundle
    self.shellRunner = shellRunner
    self.artifactPolicy = artifactPolicy
    self.artifactVerifier = artifactVerifier ?? BundledArtifactVerifier(policy: artifactPolicy)
}
```

Replace `verifyBundleArtifacts` with:

```swift
private func verifyBundleArtifacts(helperURL: URL, runtimeURL: URL) throws {
    try artifactVerifier.verify(
        appBundleURL: bundle.bundleURL,
        helperURL: helperURL,
        runtimeURL: runtimeURL
    )
}
```

In the generated install script, replace references to removed static constants with:

```swift
REQUIREMENT=\(q(artifactPolicy.codeSigningRequirement))
EXPECTED_XRAY_SHA256=\(q(artifactPolicy.xraySHA256))
```

Do not alter any shell command or installation ordering.

- [ ] **Step 6: Finalize standalone source globs**

Set `verify_sources` to:

```make
verify_sources := "teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/XrayCore/*.swift teleport/SystemProxy/*.swift teleport/VPN/*.swift teleport/HelperInstallation/*.swift teleport/Geodata/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/PrivilegedHelperConstants.swift"
```

At this point `teleport/Xray` and `teleport/Proxy` contain no Swift sources.

- [ ] **Step 7: Run verifier and full build checks**

Run:

```bash
just verify-core
just verify-geodata
just build-debug
```

Expected: all pass.

- [ ] **Step 8: Commit installation separation**

```bash
git add teleport/HelperInstallation teleport/Xray/PrivilegedHelperInstaller.swift teleport/Xray/PrivilegedShellRunner.swift scripts/verify_core.swift justfile
git commit -m "refactor: separate helper artifact verification"
```

---

### Task 6: Make the helper target filesystem-synchronized

**Files:**
- Modify: `teleport.xcodeproj/project.pbxproj:9-12,25-29,32-38,77-84,128-151,241-248`

**Interfaces:**
- Consumes: Existing helper target and `TeleportPrivilegedHelper/main.swift`.
- Produces: The same helper executable, with all Swift files below `TeleportPrivilegedHelper/` automatically included in that target.

- [ ] **Step 1: Run a helper-target baseline build**

Run:

```bash
xcodebuild -project teleport.xcodeproj -target dev.x.teleport.PrivilegedHelper -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Convert the helper group to a synchronized root group**

In `project.pbxproj`:

1. Remove `C2F100032F98000000CCB832 /* main.swift in Sources */` from `PBXBuildFile`.
2. Remove `C2F100012F98000000CCB832 /* main.swift */` from `PBXFileReference`.
3. Replace the manual `C2F1000A2F98000000CCB832` `PBXGroup` object with:

```text
C2F1000A2F98000000CCB832 /* TeleportPrivilegedHelper */ = {
    isa = PBXFileSystemSynchronizedRootGroup;
    path = TeleportPrivilegedHelper;
    sourceTree = "<group>";
};
```

4. Add to the helper target:

```text
fileSystemSynchronizedGroups = (
    C2F1000A2F98000000CCB832 /* TeleportPrivilegedHelper */,
);
```

5. Remove the explicit `main.swift in Sources` entry from the helper `PBXSourcesBuildPhase`; retain `PrivilegedHelperConstants.swift in Sources`.

Do not alter target identifiers, product names, signing settings, dependencies, or copy phases.

- [ ] **Step 3: Build both targets**

Run:

```bash
xcodebuild -project teleport.xcodeproj -target dev.x.teleport.PrivilegedHelper -configuration Debug build
just build-debug
```

Expected: both succeed, and the app bundle still contains:

```text
Contents/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper
```

- [ ] **Step 4: Commit project synchronization**

```bash
git add teleport.xcodeproj/project.pbxproj
git commit -m "build: synchronize privileged helper sources"
```

---

### Task 7: Split helper protocol, server, authentication, and entry point

**Files:**
- Create: `TeleportPrivilegedHelper/Support/HelperConfiguration.swift`
- Create: `TeleportPrivilegedHelper/Support/HelperPlatform.swift`
- Create: `TeleportPrivilegedHelper/IPC/HelperMessages.swift`
- Create: `TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift`
- Create: `TeleportPrivilegedHelper/IPC/HelperServer.swift`
- Create: `TeleportPrivilegedHelper/Session/XrayTunController.swift`
- Rewrite: `TeleportPrivilegedHelper/main.swift`

**Interfaces:**
- Consumes: Existing global constants, `HelperRequest`, `HelperResponse`, `HelperError`, `HelperServer`, and platform helpers.
- Produces:

```swift
struct ClientAuthenticator {
    func authorizePeer(_ fd: Int32) throws
}

final class HelperServer {
    init(authenticator: ClientAuthenticator = ClientAuthenticator())
    func run() throws
}
```

- [ ] **Step 1: Confirm characterization remains green**

Run:

```bash
just verify-split-tunneling
```

Expected: pass before splitting.

- [ ] **Step 2: Extract helper configuration constants**

Create `Support/HelperConfiguration.swift`:

```swift
import Foundation

let helperVersion = PrivilegedHelperConstants.version
let helperLabel = PrivilegedHelperConstants.label
let socketPath = PrivilegedHelperConstants.socketPath
let helperStateDirectoryPath = PrivilegedHelperConstants.helperStateDirectoryPath
let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
let maxRequestBytes = 2 * 1024 * 1024
let maxConfigBytes = 1024 * 1024
let maxLogReadBytes = 1024 * 1024
let maxCapturedShellOutputBytes = 64 * 1024
```

These are the exact current values; changing file-scoped access to target-internal access has no runtime effect.

- [ ] **Step 3: Extract message and error types**

Create `IPC/HelperMessages.swift` with the complete existing definitions of:

```swift
struct HelperRequest: Codable
struct HelperResponse: Codable
struct HelperError: LocalizedError
```

Do not change fields, Codable behavior, or error text.

- [ ] **Step 4: Extract platform helpers**

Create `Support/HelperPlatform.swift` with the complete existing implementations:

```swift
func consoleUserIDs() -> (uid: uid_t, gid: gid_t)
func shellQuote(_ value: String) -> String
```

Import `Foundation` and `Darwin`. Change only access level from file-private to target-internal so other helper files can call them.

- [ ] **Step 5: Extract client authentication**

Create `IPC/ClientAuthenticator.swift`:

```swift
import Darwin
import Foundation
import Security

struct ClientAuthenticator {
    func authorizePeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw HelperError("Could not verify Teleport client identity")
        }
        let consoleOwner = consoleUserIDs()
        guard uid == consoleOwner.uid else {
            throw HelperError("Rejected request from uid \(uid); expected console uid \(consoleOwner.uid)")
        }
        _ = gid
        try authorizePeerCodeSignature(fd)
    }

    private func authorizePeerCodeSignature(_ fd: Int32) throws {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDLength) == 0 else {
            throw HelperError("Could not identify Teleport client process")
        }

        var secCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: peerPID] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &secCode)
        guard status == errSecSuccess, let secCode else {
            throw HelperError("Could not inspect Teleport client signature: OSStatus \(status)")
        }

        var requirement: SecRequirement?
        let requirementText = "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\""
        status = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw HelperError("Could not create Teleport signature requirement: OSStatus \(status)")
        }

        status = SecCodeCheckValidity(secCode, SecCSFlags(), requirement)
        guard status == errSecSuccess else {
            throw HelperError("Rejected request from unsigned or untrusted Teleport client: OSStatus \(status)")
        }
    }
}
```

- [ ] **Step 6: Extract HelperServer**

Create `IPC/HelperServer.swift` with imports `Darwin` and `Foundation`, then extract the current `HelperServer` implementation. Add this stored property and initializer to the extracted class:

```swift
private let authenticator: ClientAuthenticator

init(authenticator: ClientAuthenticator = ClientAuthenticator()) {
    self.authenticator = authenticator
}
```

The extracted class must retain these current methods and their full implementations: `run()`, `makeListeningSocket()`, `handleClient(_:)`, `handle(_:)`, `readAll(from:)`, and `write(_:to:)`. Do not change socket options, loops, request limits, command dispatch, response encoding, or error mapping. Inside `handleClient`, make only the authentication substitution shown below.

Inside `handleClient`, replace:

```swift
try authorizePeer(fd)
```

with:

```swift
try authenticator.authorizePeer(fd)
```

No other behavior changes.

- [ ] **Step 7: Extract the controller unchanged and reduce the entry point**

Extract the source range beginning with `final class XrayTunController` and ending at that class's closing brace into `Session/XrayTunController.swift` without changing its methods. After removing all extracted declarations, `main.swift` must contain exactly the entry behavior:

```swift
import Darwin
import Foundation

// A client may time out and close its socket while a root command is still running.
// Ignoring SIGPIPE turns the later response write into EPIPE instead of terminating
// the long-lived helper process.
signal(SIGPIPE, SIG_IGN)
do {
    try HelperServer().run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("\(helperLabel): \(message)\n", stderr)
    exit(1)
}
```

The build must contain exactly one declaration of `XrayTunController`, now in the Session directory.

- [ ] **Step 8: Build and run helper source characterization**

Run:

```bash
xcodebuild -project teleport.xcodeproj -target dev.x.teleport.PrivilegedHelper -configuration Debug build
just verify-split-tunneling
just build-debug
```

Expected: all pass.

- [ ] **Step 9: Commit helper IPC separation**

```bash
git add TeleportPrivilegedHelper teleport.xcodeproj/project.pbxproj
git commit -m "refactor: split privileged helper IPC boundary"
```

---

### Task 8: Split helper controller, process management, shell execution, and route scripts

**Files:**
- Modify: `TeleportPrivilegedHelper/Session/XrayTunController.swift`
- Create: `TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift`
- Create: `TeleportPrivilegedHelper/Support/HelperShellRunner.swift`
- Create: `TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift`
- Rewrite: `TeleportPrivilegedHelper/main.swift`

**Interfaces:**
- Consumes: Existing `XrayTunController` behavior and all generated shell text.
- Produces:

```swift
struct ManagedXrayProcess
struct HelperShellRunner
struct XrayTunScriptBuilder
final class XrayTunController
```

with the same externally observed `start`, `stop`, and `readLog` behavior.

- [ ] **Step 1: Add behavior-preserving collaborators**

Create collaborator declarations:

```swift
struct ManagedXrayProcess {
    let installedXrayPath: String

    func terminateManagedXray(helperStateDirectoryPath: String) throws
    func terminateLegacyManagedXray(stateDirectoryPath: String) throws
    func managedXrayPID(pidFilePath: String, expectedOwner: uid_t) -> pid_t?
}
```

Move the current process termination, PID parsing, signalling, and `proc_pidpath` implementations into this type. Preserve timing, owner checks, size checks, resolved-path comparison, and signal ordering.

Create:

```swift
struct HelperShellRunner {
    func run(_ script: String) throws
}
```

Move the current `runShell`, pipe-draining functions, and `BoundedOutputCollector` into this file. Preserve output limits, `Process` arguments, wait behavior, and error ordering.

Create:

```swift
struct XrayTunScriptBuilder {
    let installedXrayPath: String

    func makeStartScript(
        helperStateDirectoryPath: String,
        configPath: String,
        protectedHost: String,
        tunnelInterfaceName: String,
        outboundInterface: String
    ) -> String

    func makeStopScript(
        helperStateDirectoryPath: String,
        protectedHost: String?,
        outboundInterface: String?
    ) -> String
}
```

Extract `makeStartScript`, `makeStopScript`, `deleteHostRouteFunction`, `dnsRouteFunctions`, `directRouteFunctions`, and `protectHostRouteCommands` into this type. Preserve every shell command, quote, error message, sleep, retry count, and cleanup operation.

- [ ] **Step 2: Run the test expecting temporary compile failure**

Before updating `XrayTunController` call sites, run:

```bash
xcodebuild -project teleport.xcodeproj -target dev.x.teleport.PrivilegedHelper -configuration Debug build
```

Expected: compilation fails because the controller still references its removed private methods. This proves the extracted collaborators are not dead code.

- [ ] **Step 3: Rewrite XrayTunController to delegate without changing ordering**

At the top of the existing `XrayTunController` class body, insert:

```swift
private let managedProcess: ManagedXrayProcess
private let shellRunner: HelperShellRunner
private let scriptBuilder: XrayTunScriptBuilder

init(
    managedProcess: ManagedXrayProcess = ManagedXrayProcess(installedXrayPath: installedXrayPath),
    shellRunner: HelperShellRunner = HelperShellRunner(),
    scriptBuilder: XrayTunScriptBuilder = XrayTunScriptBuilder(installedXrayPath: installedXrayPath)
) {
    self.managedProcess = managedProcess
    self.shellRunner = shellRunner
    self.scriptBuilder = scriptBuilder
}
```

Keep the current `start`, `stop`, `readLog`, validation, config-writing, state-directory, symlink, and log-tail methods in this type with their existing implementations and access levels.

In `start`, use these exact substitutions while preserving statement order:

```swift
try managedProcess.terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
try shellRunner.run(scriptBuilder.makeStartScript(
    helperStateDirectoryPath: helperStateDirectoryPath,
    configPath: configPath,
    protectedHost: protectedHost,
    tunnelInterfaceName: tunnelInterfaceName,
    outboundInterface: outboundInterface
))
return managedProcess.managedXrayPID(
    pidFilePath: helperStateDirectoryPath + "/xray-tun.pid",
    expectedOwner: 0
)
```

In `stop`, use:

```swift
try managedProcess.terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
try shellRunner.run(scriptBuilder.makeStopScript(
    helperStateDirectoryPath: helperStateDirectoryPath,
    protectedHost: protectedHost.isEmpty ? nil : protectedHost,
    outboundInterface: outboundInterface
))
```

- [ ] **Step 4: Make main.swift entry-only**

Remove all remaining controller/support declarations from `main.swift`. Its complete content must now be the entry-point block specified in Task 7 Step 7.

- [ ] **Step 5: Verify generated route behavior remains represented**

Run:

```bash
just verify-split-tunneling
```

Expected: `verify_split_tunneling: all checks passed`. The recursive source loader must find route strings in `Routing/XrayTunScriptBuilder.swift`.

- [ ] **Step 6: Build and inspect helper composition**

Run:

```bash
xcodebuild -project teleport.xcodeproj -target dev.x.teleport.PrivilegedHelper -configuration Debug build
just build-debug
wc -l TeleportPrivilegedHelper/main.swift TeleportPrivilegedHelper/Session/XrayTunController.swift TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift
```

Expected:

- Both builds succeed.
- `main.swift` is under 20 lines excluding comments/blank lines.
- No individual helper source file contains IPC server, code-signing authentication, process supervision, and route scripts together.

- [ ] **Step 7: Commit helper runtime separation**

```bash
git add TeleportPrivilegedHelper
git commit -m "refactor: split privileged helper runtime responsibilities"
```

---

### Task 9: Add structural guards and complete Phase 1 verification

**Files:**
- Create: `scripts/verify_architecture_layout.swift`
- Modify: `justfile:145-178`
- Modify: `docs/xray-bundling-and-release.md`

**Interfaces:**
- Consumes: Final Phase 1 source layout.
- Produces: `just verify-architecture-layout`, included in `just verify`.

- [ ] **Step 1: Write the layout verification script**

Create `scripts/verify_architecture_layout.swift`:

```swift
import Foundation

@main
struct VerifyArchitectureLayout {
    static func main() throws {
        let requiredFiles = [
            "teleport/XrayCore/XrayConfigurationWriter.swift",
            "teleport/SystemProxy/SystemProxyConnectionBackend.swift",
            "teleport/SystemProxy/SystemProxyService.swift",
            "teleport/SystemProxy/XrayRuntimeManager.swift",
            "teleport/VPN/XrayTunConnectionBackend.swift",
            "teleport/VPN/PrivilegedHelperClient.swift",
            "teleport/HelperInstallation/BundledArtifactVerifier.swift",
            "teleport/Geodata/GeodataUpdateService.swift",
            "TeleportPrivilegedHelper/IPC/HelperServer.swift",
            "TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift",
            "TeleportPrivilegedHelper/Session/XrayTunController.swift",
            "TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift",
            "TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift"
        ]

        for path in requiredFiles {
            precondition(
                FileManager.default.fileExists(atPath: path),
                "missing required architecture file: \(path)"
            )
        }

        let obsoleteFiles = [
            "teleport/Xray/XrayConfigurationWriter.swift",
            "teleport/Xray/XrayRuntimeManager.swift",
            "teleport/Xray/PrivilegedHelperClient.swift",
            "teleport/Xray/PrivilegedHelperInstaller.swift",
            "teleport/Proxy/SystemProxyService.swift"
        ]

        for path in obsoleteFiles {
            precondition(
                !FileManager.default.fileExists(atPath: path),
                "obsolete mixed-responsibility source remains: \(path)"
            )
        }

        let mainSource = try String(
            contentsOfFile: "TeleportPrivilegedHelper/main.swift",
            encoding: .utf8
        )
        precondition(mainSource.contains("HelperServer().run()"))
        precondition(!mainSource.contains("final class HelperServer"))
        precondition(!mainSource.contains("final class XrayTunController"))
        precondition(!mainSource.contains("makeStartScript"))

        print("verify_architecture_layout: all checks passed")
    }
}
```

- [ ] **Step 2: Run the new script directly**

Run:

```bash
swiftc scripts/verify_architecture_layout.swift -o /tmp/teleport-verify-architecture-layout
/tmp/teleport-verify-architecture-layout
```

Expected: `verify_architecture_layout: all checks passed`.

- [ ] **Step 3: Add the just recipe and aggregate dependency**

Add:

```make
verify-architecture-layout:
    swiftc scripts/verify_architecture_layout.swift -o /tmp/teleport-verify-architecture-layout
    /tmp/teleport-verify-architecture-layout
```

Add `verify-architecture-layout` to the `verify` dependency list.

- [ ] **Step 4: Update architecture documentation**

In `docs/xray-bundling-and-release.md`, replace the stale statement that `XrayRuntimeManager` expects all Xray code under one module with a short Phase 1 layout section:

```markdown
## Runtime source boundaries

- `teleport/XrayCore` builds Xray JSON and has no process or privilege code.
- `teleport/SystemProxy` owns the user Xray process and macOS proxy settings.
- `teleport/VPN` owns app-side privileged VPN orchestration.
- `teleport/HelperInstallation` owns the current helper deployment path.
- `teleport/Geodata` owns geodata selection and updates.
- `TeleportPrivilegedHelper` contains root-only IPC, process, and route code.
```

Do not document XPC or `SMAppService` as implemented in this Phase 1 plan.

- [ ] **Step 5: Run complete fresh verification**

Run:

```bash
git diff --check
just clean
just verify
```

Expected:

- Clean Debug build succeeds for app and helper.
- Every verification script prints `all checks passed`.
- Architecture layout check passes.
- `codesign --verify` checks in the build flow remain successful.

- [ ] **Step 6: Review the final diff for behavior changes**

Run:

```bash
git diff --find-renames --stat
git diff --word-diff=porcelain -- teleport/XrayCore teleport/SystemProxy teleport/VPN teleport/Geodata TeleportPrivilegedHelper
```

Review requirements:

- Config generation statements are unchanged.
- Socket protocol fields and commands are unchanged.
- Code-signature requirement is unchanged from the approved working-tree baseline.
- Route shell text is unchanged.
- Startup/stop ordering is unchanged.
- Existing English audit annotations are preserved.
- No sibling branch feature was introduced.

- [ ] **Step 7: Commit Phase 1 structural guards**

```bash
git add scripts/verify_architecture_layout.swift justfile docs/xray-bundling-and-release.md
git commit -m "test: guard Xray runtime source boundaries"
```

- [ ] **Step 8: Request code review before Phase 2**

Review specifically:

1. Whether any extraction changed executable ordering or error handling.
2. Whether target membership includes each new helper file exactly once.
3. Whether existing uncommitted work was preserved.
4. Whether app/helper signing and bundle layout are unchanged.
5. Whether Phase 2 can now introduce `ConnectionProvider` without reopening mixed source files.

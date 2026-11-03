# AgentXAppSDK

Independent Swift package (Foundation + platform POSIX APIs); no dependency on Travel Cat or AgentX host code. Each app owns its version and data schema. `hostAPIMajor` is the compatibility handshake; app versions need not match manager versions. The host must separately authorize schema migrations before upgrading an app.

```swift
import AgentXAppSDK
let manifest = AppManifest(id: "notes", name: "Notes", version: "1.0.0",
    dataSchemaVersion: 1, hostAPIMajor: 1, kind: "utility", runtime: "native", modules: ["notes"])
try manifest.validate(hostAPIMajor: 1)
// Trusted host policy, never an app-supplied grant list:
let grants = [AppFileGrant(appID: "notes", relativePath: "apps/notes", access: .readWrite),
              AppFileGrant(appID: "notes", relativePath: "shared/references", access: .read)]
let files = try AppFileAccess(root: selectedRoot, appID: "notes", grants: grants)
try files.write(Data("hello".utf8), relativePath: "apps/notes/state/note.txt")
let data = try files.read(relativePath: "shared/references/manual.txt")
```

The host creates the required directories before issuing access. All serialized paths and grants are relative to the selected root. Reopen the access broker at the moved root to reuse the exact same grant data. No environment, credentials, or absolute root is persisted by the SDK. Root must be a canonical file URL with no symlink components; resolve the user's selection at the trusted host boundary.

## Security contract

`AppFileAccess` is a **trusted host broker**, not a sandbox for arbitrary in-process Swift code. Its constructor is public for host integration; an untrusted app must never be able to instantiate a host broker or submit authoritative grants. Put grants in host-owned policy and expose broker operations over an authenticated per-app IPC channel. Grant structs being Codable is not a signature or an authorization decision.

Every relative path rejects absolute paths, dot segments, empty components, NUL and backslash. Grants may name only the current app or an explicit child of `shared/`. Access opens each component relative to an already opened directory with `O_NOFOLLOW`; regular files must have exactly one link. Reads reject symlinks, hardlinks, FIFOs and devices. Writes use an exclusive new inode and atomic replacement, never truncate an existing inode. Parent directories must already exist.

The host must own and control root/ancestor directory mutation. File descriptors prevent a symlink substitution from redirecting traversal, but cannot by themselves stop an attacker who can rename an already opened directory outside the managed tree or create links concurrently. Untrusted processes need OS-enforced confinement; do not claim an in-process capability object provides full process isolation. Do not hand the untrusted child inherited data descriptors, manager credentials, or ambient network permissions.

`AppSandboxProfile.generate` produces a macOS deny-default sandbox-exec profile with network denied, OS runtime read/execute access, and only the explicit app/shared data grants. It is a profile generator, not a launcher. The host must apply the profile before executing untrusted code and fail closed if sandbox initialization fails; a future launcher must also scrub environment and inherited descriptors. Runtime OS directory roots are rejected because they overlap baseline runtime access. macOS sandbox-exec is platform-specific; other operating systems need a separately verified container/OS sandbox.

Run the independent suite from the repository using:

```sh
Scripts/travel-cat-swift.sh test --package-path Packages/AgentXAppSDK
```

The sandbox test executes actual `/bin/cat` and shell redirection for own-app read/write, sibling/manager denial, and shared read-only enforcement. If the environment cannot initialize the OS sandbox it explicitly skips, which does **not** certify untrusted execution.

Application IDs are canonical lowercase ASCII to prevent case-insensitive filesystem aliasing. The subprocess profile imports the OS dyld bootstrap rules and scans all granted trees for links and special files before launch. The host must prevent concurrent changes to links/ancestor directories until child exit. Runtime data grants do not include platform configuration, sibling apps, or network access.

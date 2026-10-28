# WindowServer injection and preventing first presentation

Investigation: 2026-10-27. Target: macOS 15.6 (24G84), Apple Silicon. Scope: read-only local metadata, static inspection of the small WindowServer launcher, an own-process SkyLight symbol inventory, existing Shoji evidence, first-party implementation sources, Apple documentation, and Apple-published XNU source. No task-port acquisition, debugger attachment, injection, WindowServer restart, or security-setting change was performed.

## Finding

The user's goal is to keep a newly requested window absent from the screen until Shoji approves presentation. **There is a concrete open-source precedent for injecting WindowServer and intercepting its internal ordering path:** Vanish implements server-side close animations on a different macOS target. This materially strengthens the architectural feasibility of a central gate without loading Shoji into every application. **This investigation does not establish that WindowServer on this host can load our agent or that first-presentation prevention works.** It identifies the process, its loading restriction, specific shared symbol candidates, and the remaining experiments needed to answer those questions.

WindowServer injection and presentation interception are separate capabilities. A successful `dlopen` would establish only that our code runs in the server process; it would not establish a suitable callback, complete path coverage, safe suppression semantics, or absence of a first-frame flash. Conversely, a symbol name or notification establishes neither injection nor a pre-presentation gate.

The current Dock payload cannot provide this simply by replacing an AppKit method inside Dock. Shoji's loader targets `com.apple.dock`; AppKit replacement is process-local. The [existing app-side prototype](../tools/window-interception/README.md) demonstrates the separate per-app approach, including a live example where `orderFrontRegardless` bypassed the initially replaced ordering method. It is not evidence of server-side interception.

## Local evidence and what it establishes

Read-only metadata supplied by the parent investigation identifies the target as `/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`, running as UID 88. The executable is universal x86_64/arm64e. Its arm64e slice has UUID `C18F469E-319B-3066-8556-3CD4F45B113F`, a platform designation, no TeamIdentifier, and signature flags `0x2000 (library-validation)`. The same inspection found Dock without that signature flag. These are relevant differences from the already working Dock injection context, not proof of a particular remote-load error. See the [local evidence directory](evidence/windowserver-24G84/).

The executable imports `_SLXServer` from SkyLight and has few other imports. The implementation to investigate is therefore the matched SkyLight server code, rather than treating the small WindowServer executable as the complete compositor implementation. `_SLXServer` identifies the server entry point; it is not a proven interception location.

A subsequent read-only probe loaded SkyLight **in the probe's own process**, inspected its mapped Mach-O symbol table, and found 26,680 symbols. Its name filter matched 195 window creation/ordering/commit-related symbols and printed the first 100. The [raw symbol evidence](evidence/windowserver-24G84/skylight-symbols.txt) provides more focused candidates for the next analysis:

| Candidate | Investigation question, inferred from name only |
| --- | --- |
| `_WSWindowCreate` | Where is the server-side window object established, and what visibility state is its initial value? |
| `_CGXOrderWindowListWithOperation`, `__CGXOrderWindowListWithGroups` | Do the ordinary ordering paths converge before a window enters visible composition? |
| `__ZL18start_order_windowP13CGXConnectionP19CGXOrderWindowState`, `__ZL20finish_order_windowsP13CGXConnectionP19CGXOrderWindowStatemb` | Is there a bounded preparation/commit boundary for one window's order state? |
| `PKGTransactionOrderWindow`, `PKGTransactionOrderWindowGroup`, `PKGTransactionSafeOrderWindowGroup` name families | Can transaction paths bypass an ordinary ordering gate, and where would hold/release need to apply? |

These are **symbol candidates only**. Name matching did not recover an ABI, validate function semantics, identify all callers, prove live server execution, or establish interception coverage. The probe invoked none of these functions, acquired no WindowServer task port, and did not load anything into WindowServer. A mapped client-process copy of SkyLight is evidence about available image metadata, not successful control of the separate server process.

The current host uses a custom SIP configuration: debugging, filesystem, NVRAM and boot-argument restrictions are disabled; several other protections remain enabled. Authenticated Root is enabled, confirmed by the read-only evidence collection outside the sandbox. The host cannot establish behavior on a fully SIP-enabled machine. No change to those settings is part of this investigation.

The preferred REA tools were unavailable: `npx --offline -y rea-agents@latest doctor` failed with `ENOTCACHED`. No tool installation or configuration change followed. Native Xcode `file`, `nm`, `otool`, and `codesign`, plus the own-process Odin symbol probe, supplied the local observations. The [evidence collector and outputs](evidence/windowserver-24G84/) include small-launcher disassembly and load commands; a full SkyLight server disassembly/call graph has **not** been recovered.

## Concrete implementation precedent: Vanish

Vanish's first-party README describes server-side close animations, with no client app injection. Its prerequisites specify macOS 27+, arm64e, SIP and library validation disabled, and a tweak loader. Those are the project's stated requirements, not a demonstrated minimum required by every possible Shoji loading route. Our target is macOS 15.6, so installing it unchanged would not be a supported compatibility test. [Vanish README](https://github.com/doraorak/Vanish/blob/7b56519292ff1e19e6728fd50d3dc5a2f4131e07/README.md)

Its recovered header identifies `CGXOrderWindowListSpaceSwitchOptions` as a convergence point for several `_XOrderWindow` request variants. It declares a void result and arguments for connection, window-ID list, signed 32-bit order-operation list, relative-window list, unsigned count and a boolean Space-switch option. The exact mangled name `__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb` also appears in our local 15.6 symbol inventory. That gives us a stronger candidate than a name-only search, but the header's ABI and structure offsets remain unverified on 15.6. [Vanish recovered header](https://github.com/doraorak/Vanish/blob/7b56519292ff1e19e6728fd50d3dc5a2f4131e07/SkyLightServer.h)

The implementation walks SkyLight's mapped `LC_SYMTAB`, signs resolved function pointers, checks required resolutions, and installs replacements through `TIL_HOOK` while retaining original functions. Its constructor checks the executable path for WindowServer. The ordering replacement observes operations and forwards them; its close-animation logic manipulates originals and clones. A comment specifically describes a prior error from swallowing an actual order-out: the window remained ordered in and could reappear. This is code evidence for central interception, **not** an implementation of first-open hold/release. [Vanish implementation](https://github.com/doraorak/Vanish/blob/7b56519292ff1e19e6728fd50d3dc5a2f4131e07/Vanish.c)

The Makefile builds arm64e and links the hooking/support libraries plus SkyLight. Its compiler deployment target is 15.0; that is not evidence that its private ABI works on 15.x, given the README's 27+ tested requirement. Its filter selects the WindowServer executable name rather than an app bundle identifier. This is a different deployment mechanism from our remote Dock loader, despite the overlap in payload concerns. [Vanish Makefile](https://github.com/doraorak/Vanish/blob/7b56519292ff1e19e6728fd50d3dc5a2f4131e07/Makefile), [Vanish process filter](https://github.com/doraorak/Vanish/blob/7b56519292ff1e19e6728fd50d3dc5a2f4131e07/Filter.plist)

The associated TI_TweakLoader README describes injection propagated through launchd/xpcproxy process spawning using dynamic-loader insertion, a broad system installation and a userspace restart, with SIP disabled. This is a startup-propagation route into system services; it does not establish that direct remote attachment uses the same prerequisites or that Shoji needs the entire loader installation. No component was installed here. [TI_TweakLoader components and setup](https://github.com/doraorak/TI_TweakLoader)

A historical first-person investigation also records Frida-based WindowServer attachment in a modified security configuration. It is evidence of an additional injection precedent, not current-host compatibility or permission to adopt that article's unrelated indicator behavior. [Alin Panaitiu's investigation, 2023-03-28](https://notes.alinpanaitiu.com/Can-we-hide-the-orange-dot-without-disabling-SIP)

The Vanish reference is pinned to commit `7b56519292ff1e19e6728fd50d3dc5a2f4131e07`, identified by a read-only remote-HEAD query. When fixed-revision web views failed, direct read-only HTTPS retrieval verified the exact symbol, signature declaration, hook installation, pointer signing, constructor, prerequisites, build configuration and process filter at that revision. No upstream code was copied into Shoji.

## Loading restrictions: what the primary sources actually say

Apple's archived SIP guide says protected processes reject runtime attachment and task-port acquisition, including root attempts; dynamic-linker environment variables are purged for protected launches. This describes the normal protected configuration, not the actual outcome on this host with debugging restrictions disabled. It rules out assuming that `sudo` alone solves attachment. [Apple runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)

Library loading is a separate check. Apple documents library validation as accepting Apple-signed code or code sharing the executable's Team ID, with a specific entitlement to disable that validation. WindowServer's observed library-validation flag makes it incorrect to extrapolate our Dock `dlopen` success to a Shoji-signed library inside WindowServer. Whether the target's actual policy permits any proposed loading path remains untested. [Apple library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)

Allowing `DYLD_` variables is also a target entitlement, not a global entitlement an injector can give itself. Environment-variable insertion into a test executable therefore does not establish a startup-injection route into the system WindowServer service. [Apple DYLD entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)

Apple's XNU source shows multiple task-control policy layers: POSIX eligibility, mandatory-access-control checks, and task-access-server checks. Root bypasses certain checks, not every layer. Notably, the source's platform-binary-to-platform-binary task conversion restriction is conditional on **not macOS**; importing that iOS explanation as a blanket macOS rejection reason would be incorrect. The source tag is a concrete Sequoia-era reference, not a claim that it exactly reproduces all private security policy on 24G84. [XNU task-control path](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_proc.c), [XNU task-port conversion policy](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/ipc_tt.c)

Apple's open source does not, in the portions inspected, provide the complete proprietary AMFI policy decision for this process. We have not identified a source-backed entitlement combination that makes an ordinary Shoji build eligible to inject WindowServer. That is an unresolved capability, not proof of impossibility or authorization to patch a check.

## The gate must control presentation, not just creation

The following is an architectural model to test, not a recovered server call graph:

| Stage | What Shoji would need to establish |
| --- | --- |
| Create window/server object | Allocate and return a usable identity while keeping the window nonpresentable. Rejecting creation itself may prevent the app from initializing. |
| Receive ordering request | Record requested visibility/order without placing a blocked window into visible composition. A later show request must not bypass the hold. |
| Receive content/layer transactions | Accept necessary app updates without allowing them to make the held window visible through another path. |
| Approve presentation | Apply the accepted geometry/order and release the hold in a coordinated server update. |
| Cancel/destroy/disconnect | Remove pending state without leaking an invisible resource or retaining an unrelated reused window ID. |

Hooking a client SkyLight export in Shoji or Dock affects calls made from that process. It does not automatically intercept other clients' messages arriving at the server. The relevant candidate would be server-side request handling or the state transition that admits a window into composition. Those paths need to be recovered and tested on the exact binary build.

The candidate design is a **per-window presentation hold installed before first eligible composition**, while accepting the app's initialization and content updates. Logical application ordering, effective composed visibility, input eligibility and focus must be tracked separately. Merely returning early from an ordering function can leave those states divergent, as Vanish's documented order-out bug illustrates. A held invisible window must not receive clicks or steal focus. Release should be a nonblocking native update after a daemon decision, with an independent timeout/watchdog. This is a requirement for a future gate, not a claim that the current candidates expose all those controls.

Suppressing all window activity would also suppress dialogs and system UI. A viable policy must identify the owner, window generation, type and parent relationship before applying the hold. Windows that become visible without a new allocation, transaction-based ordering, restored/tabbed windows, popups, fullscreen/Space transitions and multiple WindowServer sessions require explicit coverage evidence.

## Existing Shoji effects do not establish first-frame prevention

The existing addition can request system alpha, window order and layers after it learns a window ID. Neither that nor a faster asynchronous creation notification establishes that the server waits for Shoji before committing a visible frame. To satisfy the user's requirement, the hold must precede the first eligible composition, rather than hiding a window after its first visible frame.

The [foreign clipping experiment](COMPOSITOR_PROBE_RESULTS.md) also showed why a setter's return alone is insufficient: an owner-issued operation changed the fixture while the same setter from an ordinary separate process did not. The [transaction ABI investigation](TRANSACTION_ABI.md) further separates submission from independently observed effects. Neither result proves WindowServer injection works or fails.

## Recommended investigation sequence

1. Preserve exact target identity and protection metadata. Keep executable UUID, OS build, architecture, codesigning flags, entitlement output and SIP observations together. This phase is read-only and is the evidence obtained here.
2. Start with the exact `CGXOrderWindowListSpaceSwitchOptions` candidate identified by Vanish and present in our local image. Recover its 15.6 ABI and callers; compare the `_WSWindowCreate`, `CGXOrderWindowList`, `start_order_window`/`finish_order_windows` and `PKGTransactionOrderWindow` paths. Establish their relationship to `_SLXServer`, creation, order, transactions and composition admission. Record argument conventions and callers, not merely names. Distinguish a notification after the state change from a policy callback before it.
3. Establish injection eligibility separately in a disposable, recoverable desktop session. A task-control result and a library-load result are separate findings. Do not change security configuration or experiment against the user's active WindowServer as an implicit continuation of read-only research.
4. If code can load, first run a bounded observation-only agent. Prove it can distinguish one disposable fixture's requests and confirm the exact pre-presentation boundary. Do not block the compositor thread waiting for Shoji, Accessibility, disk or network activity.
5. Implement a local hold/release policy for only the disposable fixture, with bounded pending state, window-generation ownership, a watchdog/fail-open path and cleanup on crash/disconnect. Measure independent frame captures: counters and API readbacks do not prove the absence of a visible first frame.
6. Only broaden classification after creation, alternative order paths, transactions, cancellation, dialogs, focus, input routing and session recovery pass. A single AppKit fixture does not establish all-app coverage.

The immediate actionable result is a concrete server-interception precedent, an exact ordering candidate present on the current host, and an additional verified loading-policy obstacle. There is no validated Shoji WindowServer payload or global first-presentation gate yet. The absence of a documented public gate does not negate the private interception mechanism shown by Vanish; adapting that mechanism and proving first-open behavior are the remaining work.

## Implementation update: load probe only

Later on 2026-10-27, an isolated `--load-ws`/`--check-ws` path and separate
`shoji-ws-1` payload were added. The loader requires an explicit PID, exact
system executable path, and VM-only opt-in; the payload checks its host process
and answers a cross-UID handshake with only `Load_Probe`. Compilation and local
checks do not establish WindowServer task-port access, `dlopen` eligibility, or
a live handshake. No private ordering function is hooked by this probe and no
window operation is intercepted or suppressed. See
[WINDOWSERVER_EXPERIMENT.md](WINDOWSERVER_EXPERIMENT.md) for the exact boundary
and recovery procedure.

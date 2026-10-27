# Odin arm64e payload and loader

The patched compiler builds the two arm64e pieces: the Dock payload dylib and
the Dock loader companion. Everything is Odin; no Objective-C or C source
remains. The executable itself stays plain arm64/amd64.

## Why a separate loader exists

Dock is arm64e and the kernel refuses to start a remote thread in an arm64e
task from a plain arm64 caller: `thread_convert_thread_state` succeeds, but
`thread_create_running` returns `KERN_PROTECTION_FAILURE` (verified live on
2026-10-10 on macOS 15.6 / Apple M1 Max; an unsigned thread state fails the
same way). An arm64e caller is required, and the multithreaded daemon cannot
be an arm64e ABI v0 executable with this toolchain — see the TLS note below.
`shoji --load-sa` therefore spawns `bin/shoji-loader`, an arm64e Odin helper
built from `src/loader` that runs the same in-process injector with an
arm64e personality. Upstream yabai also uses a separate arm64e loader: it
embeds a compiled loader binary as a byte array, extracts it under
`/Library/ScriptingAdditions`, and executes it.

## Build and verify

Requires the Odin source revision used by this project (`37d8ab08f`), LLVM 22,
and Apple's Xcode/Command Line Tools. Existing local target/linker changes are
accepted if they exactly match the included patch. The source checkout is not
modified; the compiler is built in a temporary directory.

```sh
task build:dev
./bin/dev build-arm64e "$(odin root)"
task build         # payload + loader + executable
task test:loader   # in-process self-test of the arm64e loader
```

Set `LLVM_CONFIG` for the compiler build if LLVM is not found automatically.
`ODIN_ARM64E` and `ODIN_ARM64E_ROOT` Task variables can select another patched
compiler and its library tree. The generated compiler lives in `bin/` and is
preserved by `task clean`.

`task test` additionally runs the injector self-test from the plain-arm64 (or
amd64) test process: remote thread creation, thread-state signing and
conversion, pthread bootstrap, and a real `dlopen` of an existing system
library, all against the test process itself (amd64 under Rosetta). It needs
no root or Accessibility access and does not contact Dock. `task
test:bootstrap` checks relocation independence of the copied bootstrap in the
Intel executable and the arm64e loader — the two binaries whose injectors
actually copy it into a target; the arm64 executable always spawns the loader
and dead-strips its own copy.

For a machine already configured to permit Dock injection, the live test is
`sudo ./bin/shoji --load-sa "$PWD/bin/shoji-sa.dylib"`, followed by
`./bin/shoji --check-sa` as the desktop user. The first live attempt
(2026-09-23) was blocked before injection: `sudo -n` required a password, and
the unprivileged helper returned `cannot obtain Dock task port (5)`. On
2026-10-05 a sudoers rule pinned to the exact `shoji --load-sa` command enabled
the live test, and the payload — Space focus/create/destroy and window
opacity exercised through it — loaded through the Odin injector into a freshly
restarted Dock. On 2026-10-10 an in-process injection attempt from the plain
arm64 executable reproduced the kernel rejection above, and the spawned-loader
path was re-validated as the default the same day.

## What the patch supplies

`odin-arm64e.patch` adds a `darwin_arm64e` target, passes `-arch arm64e` at
linking, and emits LLVM's `ptrauth.abi-version` module metadata for the legacy
ABI. The target/linker portion was already present in the local Odin checkout;
the missing module metadata caused the original arm64 object/arm64e link
mismatch.

The Tasks use Apple's Clang driver. Homebrew LLVM 22's driver rejected the
legacy arm64e object in this environment. Apple's linker marks its output ABI
v1, so the header normalization to v0 still runs before signing. No object file
is relabelled from arm64 to arm64e.

The loader is built with `-no-thread-local`: LLVM 22 generated an
unauthenticated call to Darwin's signed TLS resolver and the ABI v0 executable
crashed at runtime initialization. Only the loader's main thread uses Odin's
runtime; the copied bootstrap is context-free and uses explicit function
pointers. This restriction must not be applied to the multithreaded payload —
it is a dylib, needs TLS, and runs correctly inside Dock.

Odin procedure values still use raw pointers. The injector explicitly strips
signed `dlsym` results before raw indirect calls, the copied bootstrap signs
the pthread callback inside Dock, and the injector signs fresh thread-state
PC/SP values using Darwin's separate discriminators (29825 for PC with IA,
52205 for SP with DA). The values come from the installed SDK's
`mach/arm/_structs.h` and Clang's expansion of its setters. This does not
implement automatic callback signing, authenticated procedure values, or
general arm64e TLS.

## Bootstrap completion

The old Odin bootstrap called `pthread_join` from a raw Mach thread. The
self-test reproduced a crash in `pthread_testcancel`, because that thread has
no pthread TLS. The pthread now detaches itself, loads the library, and
publishes its load result. On failure, it waits for the injector to copy the
thread-local `dlerror` text and acknowledge receipt. A separate completion flag
is the worker's final shared-data access. The injector waits for that flag and
for the entry thread to finish its create call before terminating the entry
thread and reclaiming data and entry-stack allocations. An acknowledgment error
or timeout retains the allocations. The loader self-test exercises both a
successful system-library load and a rejected load against its own process.

The small copied code allocation remains mapped until the target exits: the
worker may still be executing its return epilogue when completion is observed.
Timeout or uncertain thread-termination paths retain all allocations. Repeated
successful loads therefore retain one page-rounded code allocation per
invocation.

## Evidence and limits

On macOS 15.6 / Apple M1 Max: `task test` (77 tests, both architectures),
`task test:loader`, and the relocation checks pass; live Dock injection of the
actual payload was verified on 2026-10-05 through the Objective-C helper and
the Odin injector, and re-verified on 2026-10-10 through the spawned Odin
loader after the Objective-C loader's removal; the same-day in-process attempt
from the plain arm64 executable was rejected by the kernel, confirming the
companion is required. This covers one macOS release and one Dock build; other
releases remain unverified, and `Animation_Patch` was not reported by this
Dock build. No SIP, launchd, or system settings were changed.

The build script also applies `tools/odin-asm-calls.patch`, which corrects ARM64
call fallthrough and return-address liveness in the template checker. It accepts
an exact existing application and fails on conflicting source changes. To check
the patched arm64e compiler without injecting or restarting Dock:

```sh
task build:harness
./bin/harness check-asm --compiler bin/odin-arm64e \
  --library-root .toolchain/Odin --target darwin_arm64e
```

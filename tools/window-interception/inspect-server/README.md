# Passive WindowServer/SkyLight inspection

This diagnostic loads SkyLight in **its own process** and reads exported names
and the mapped Mach-O symbol table. It does not obtain WindowServer's task port,
execute server entry points, modify a process, or inject code.

```sh
.toolchain/Odin/odin build tools/window-interception/inspect-server -out:bin/window-interception/inspect-server -warnings-as-errors
./bin/window-interception/inspect-server
```

The parser trusts the system framework's mapped image metadata. It is not a
general parser for untrusted Mach-O files. It bounds load-command and string
traversal, then uses the framework's `__TEXT`, `__LINKEDIT`, and `LC_SYMTAB`
metadata to locate its own mapped symbol table. It prints at most 100 names
matching `Window` plus `Order`, `Create`, or `Commit`; the total match count
includes additional unprinted matches. This is a bounded inventory, not an
exhaustive call-graph or entry-point analysis.

The candidates' names do not establish calling conventions, behavior,
permissions, reachability in the server process, or coverage of all presentation
paths. Loading the same framework in an ordinary process does not reproduce
WindowServer's runtime state or privileges.

The saved macOS 15.6 (24G84) output is in
[the evidence directory](../../../docs/evidence/windowserver-24G84/).
See [the research report](../../../docs/WINDOWSERVER_INJECTION_RESEARCH.md).

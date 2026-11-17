# Local copy of QuickJS-Swift 1.0.0

Copied from https://github.com/zqqf16/QuickJS-Swift at revision 5f13d42d81c308d5b70786340c0cd113b78e6315 (tests and CI files left out).

One change, in `Sources/QuickJSC/quickjs.c`: `build_backtrace` holds its own reference to the error object while it runs.
Without it, a script that fills the memory limit with small objects crashes the process with SIGSEGV. The backtrace code
needs small allocations, those fail at the limit, and the new out of memory error frees the error object being filled in.
See `AutomationScriptTests.testRunningOutOfMemoryOnSmallObjectsFailsWithoutCrashing`.

Remove this directory and go back to the upstream package once upstream QuickJS fixes `build_backtrace`.

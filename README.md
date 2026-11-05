# rules_ngspice

ngspice 47 circuit simulation with native Bazel rules. Use it as a library in
your application or run the command-line simulator. XSPICE code models and
OpenMP are enabled by default.

## Usage

Add to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_ngspice", version = "0.1.1")

ngspice = use_extension("@rules_ngspice//:extensions.bzl", "ngspice")
use_repo(ngspice, "ngspice")
```

| Target | Purpose |
| --- | --- |
| `@ngspice//:ngspice` | Static API library; include `<ngspice/sharedspice.h>` |
| `@ngspice//:ngspice_bin` | Headless command-line simulator |
| `@ngspice//:runtime` | XSPICE code models and support scripts |

Run a circuit:

```sh
bazel run @ngspice//:ngspice_bin -- -b "$(pwd)/circuit.cir"
```

The CLI loads its bundled code models automatically. User `.spiceinit` files
still apply; `-n` skips user initialization while bundled code models still load.

Disable XSPICE or OpenMP independently:

```sh
bazel build @ngspice//:ngspice --@ngspice//:xspice=false
bazel build @ngspice//:ngspice --@ngspice//:openmp=false
```

OpenMP parallelizes BSIM3/BSIM4 device evaluation. Set the thread count with
ngspice's `set num_threads=<n>` command. You choose the C/C++ toolchain.
For a pinned compiler setup, see [LLVM configuration](docs/hermetic-llvm.md).

## Embedding

Add `@ngspice//:ngspice` to your target's `deps`. For XSPICE, also add
`@ngspice//:runtime` to `data`, resolve it through your runfiles library, and
load the models you need after initializing ngspice:

```text
codemodel "<runtime>/lib/ngspice/analog.cm"
```

See the [embedding example](tests/shared_smoke.cc) for startup configuration,
model loading, and the event API.

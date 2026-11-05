# Pinned LLVM setup

After the [module setup](../README.md#usage), add this dependency to your
application's `MODULE.bazel`:

```starlark
bazel_dep(name = "llvm", version = "0.8.25", dev_dependency = True)
```

Add these opt-in configurations to your application's `.bazelrc`:

```text
common:hermetic --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
common:hermetic --repo_env=BAZEL_NO_APPLE_CPP_TOOLCHAIN=1
common:hermetic --repo_env=BAZEL_MACOS_USE_HOST_SDK=0

build:hermetic --extra_toolchains=@llvm//toolchain:all
build:hermetic --incompatible_strict_action_env
build:hermetic --action_env=PATH=/usr/bin:/bin
build:hermetic --action_env=LANG=C
build:hermetic --action_env=LC_ALL=C
build:hermetic --action_env=TZ=UTC
build:hermetic --nosandbox_default_allow_network

test:hermetic --test_env=PATH=/usr/bin:/bin
test:hermetic --test_env=LANG=C
test:hermetic --test_env=LC_ALL=C
test:hermetic --test_env=TZ=UTC

build:hermetic-linux --config=hermetic
build:hermetic-linux --platforms=@llvm//platforms:linux_x86_64_gnu.2.28
build:hermetic-linux --host_platform=@llvm//platforms:linux_x86_64_gnu.2.28
build:hermetic-linux --spawn_strategy=linux-sandbox

build:hermetic-macos --config=hermetic
build:hermetic-macos --platforms=@llvm//platforms:macos_aarch64
build:hermetic-macos --host_platform=@llvm//platforms:macos_aarch64
build:hermetic-macos --spawn_strategy=darwin-sandbox
```

On Linux x86-64, run:

```sh
bazel --nosystem_rc --nohome_rc build --config=hermetic-linux @ngspice//:ngspice_bin
```

On macOS ARM64, use `--config=hermetic-macos`. The same configurations apply
to `bazel test`. They select LLVM for both target code and build-time tools,
disable host compiler discovery, and use the downloaded macOS SDK. Sandboxing
must be available; these configurations fail instead of falling back to an
unsandboxed strategy.

Pin Bazel in `.bazelversion` and commit the application's `MODULE.bazel.lock`.
After resolving dependencies, use `--lockfile_mode=error` in CI.

OpenMP message generation still invokes host Bash, and shell tests use host
utilities. This setup controls their environment but does not pin those programs
or the host operating system. Use a digest-pinned execution image to pin the
remaining shell tools in CI.
Network access is disabled for sandboxed actions, while repository downloads
still need access during dependency fetching.

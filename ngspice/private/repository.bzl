"""Fetch ngspice 47 and install its native Bazel build files."""

visibility("//...")

_URL = "https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/47/ngspice-47.tar.gz"
_INTEGRITY = "sha256-iU5kllHxg4oUCV5aVDnn06pj6H7eFNKDFz/aT83vZ18="

_OVERLAY = {
    "BUILD.bazel.tpl": "BUILD.bazel",
    "private/BUILD.bazel.tpl": "private/BUILD.bazel",
    "private/config.bzl": "private/config.bzl",
    "private/config.h.in": "private/config.h.in",
    "private/core.bzl": "private/core.bzl",
    "private/ngspice.sh.in": "private/ngspice.sh.in",
    "private/outputs.bzl": "private/outputs.bzl",
    "private/runtime.bzl": "private/runtime.bzl",
    "private/runtime_tool.cc": "private/runtime_tool.cc",
    "private/sources.bzl": "private/sources.bzl",
    "private/xspice.bzl": "private/xspice.bzl",
    "private/xspice_sources.bzl": "private/xspice_sources.bzl",
}

def _ngspice_repository_impl(ctx):
    # Resolve declared inputs before downloading to avoid repository restarts.
    overlay = [(ctx.path(source), destination) for source, destination in ctx.attr._overlay.items()]
    patches = [ctx.path(patch) for patch in ctx.attr._patches]
    ctx.download_and_extract(
        url = _URL,
        integrity = _INTEGRITY,
        canonical_id = _URL,
        strip_prefix = "ngspice-47",
    )
    for patch in patches:
        ctx.patch(patch, strip = 1)
    for source, destination in overlay:
        ctx.template(destination, source, executable = False)

    # Repository contents caching is available on newer Bazel releases.
    if hasattr(ctx, "repo_metadata"):
        return ctx.repo_metadata(reproducible = True)
    return None

ngspice_repository = repository_rule(
    implementation = _ngspice_repository_impl,
    attrs = {
        "_overlay": attr.label_keyed_string_dict(
            allow_files = True,
            default = {
                Label("//ngspice/private:overlay/" + source): destination
                for source, destination in _OVERLAY.items()
            },
        ),
        "_patches": attr.label_list(
            allow_files = True,
            default = [
                Label("//ngspice/private:patches/codemodel-quoted-paths.patch"),
                Label("//ngspice/private:patches/disabled-xspice.patch"),
                Label("//ngspice/private:patches/long-source-path.patch"),
                Label("//ngspice/private:patches/runtime-library-path.patch"),
            ],
        ),
    },
)

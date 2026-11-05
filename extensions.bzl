"""Module extension providing the ngspice 47 library, CLI, and runtime."""

load("//ngspice/private:repository.bzl", "ngspice_repository")

def _ngspice_impl(module_ctx):
    ngspice_repository(name = "ngspice")
    root_deps = ["ngspice"] if any([module.is_root for module in module_ctx.modules]) else []
    return module_ctx.extension_metadata(
        root_module_direct_deps = root_deps if module_ctx.root_module_has_non_dev_dependency else [],
        root_module_direct_dev_deps = [] if module_ctx.root_module_has_non_dev_dependency else root_deps,
        reproducible = True,
    )

ngspice = module_extension(
    implementation = _ngspice_impl,
    doc = "Download ngspice 47 and expose it as the ngspice repository.",
)

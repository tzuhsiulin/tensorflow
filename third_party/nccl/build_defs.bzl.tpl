"""Repository rule for NCCL."""

load("@local_config_cuda//cuda:build_defs.bzl", "cuda_default_copts")

def _gen_nccl_h_impl(ctx):
    """Creates nccl.h from a template."""
    ctx.actions.expand_template(
        output = ctx.outputs.output,
        template = ctx.file.template,
        substitutions = {
            "${nccl:Major}": "2",
            "${nccl:Minor}": "3",
            "${nccl:Patch}": "5",
            "${nccl:Suffix}": "",
            "${nccl:Version}": "2305",
        },
    )
gen_nccl_h = rule(
    implementation = _gen_nccl_h_impl,
    attrs = {
        "template": attr.label(allow_single_file = True),
        "output": attr.output(),
    },
)
"""Creates the NCCL header file."""


def _process_srcs_impl(ctx):
    """Appends .cc to .cu files, patches include directives."""
    files = []
    for src in ctx.files.srcs:
        if not src.is_source:
          # Process only once, specifically "src/nccl.h".
          files.append(src)
          continue
        name = src.basename
        if src.extension == "cu":
            name = ctx.attr.prefix + name + ".cc"
        file = ctx.actions.declare_file(name, sibling = src)
        ctx.actions.expand_template(
            output = file,
            template = src,
            substitutions = {
                "\"collectives.h": "\"collectives/collectives.h",
                "\"../collectives.h": "\"collectives/collectives.h",
                "#if __CUDACC_VER_MAJOR__":
                    "#if defined __CUDACC_VER_MAJOR__ && __CUDACC_VER_MAJOR__",
                # Substitutions are applied in order.
                "std::nullptr_t": "nullptr_t",
                "nullptr_t": "std::nullptr_t",
            },
        )
        files.append(file)
    return [DefaultInfo(files = depset(files))]
_process_srcs = rule(
    implementation = _process_srcs_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "prefix": attr.string(default = ""),
    },
)
"""Processes the NCCL srcs so they can be compiled with bazel and clang."""


def nccl_library(name, srcs=None, hdrs=None, prefix=None, **kwargs):
    """Processes the srcs and hdrs and creates a cc_library."""

    _process_srcs(
        name = name + "_srcs",
        srcs = srcs,
        prefix = prefix,
    )
    _process_srcs(
        name = name + "_hdrs",
        srcs = hdrs,
    )

    native.cc_library(
        name = name,
        srcs = [name + "_srcs"] if srcs else [],
        hdrs = [name + "_hdrs"] if hdrs else [],
        **kwargs
    )


def rdc_copts():
    """Returns copts for compiling relocatable device code."""

    # The global functions can not have a lower register count than the
    # device functions. This is enforced by setting a fixed register count.
    # https://github.com/NVIDIA/nccl/blob/f93fe9bfd94884cec2ba711897222e0df5569a53/makefiles/common.mk#L48
    maxrregcount = "-maxrregcount=96"

    return cuda_default_copts() + select({
          "@local_config_cuda//cuda:using_nvcc": [
              "-nvcc_options",
              "relocatable-device-code=true",
              "-nvcc_options",
              "ptxas-options=" + maxrregcount,
          ],
          "@local_config_cuda//cuda:using_clang": [
              "-fcuda-rdc",
              "-Xcuda-ptxas",
              maxrregcount,
          ],
          "//conditions:default": [],
      }) + ["-fvisibility=hidden"]


def _filter_impl(ctx):
    suffix = ctx.attr.suffix
    files = [src for src in ctx.files.srcs if src.path.endswith(suffix)]
    return [DefaultInfo(files = depset(files))]
_filter = rule(
    implementation = _filter_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "suffix": attr.string(),
    },
)
"""Filters the srcs to the ones ending with suffix."""


def _gen_link_src_impl(ctx):
    ctx.actions.expand_template(
        output = ctx.outputs.output,
        template = ctx.file.template,
        substitutions = {
            "REGISTERLINKBINARYFILE": '"%s"' % ctx.file.register_hdr.short_path,
            "FATBINFILE": '"%s"' % ctx.file.fatbin_hdr.short_path,
        },
    )
_gen_link_src = rule(
    implementation = _gen_link_src_impl,
    attrs = {
        "register_hdr": attr.label(allow_single_file = True),
        "fatbin_hdr": attr.label(allow_single_file = True),
        "template": attr.label(allow_single_file = True),
        "output": attr.output(),
    },
)
"""Patches the include directives for the link.stub file."""


def device_link(name, srcs):
    """Links seperately compiled relocatable device code into a cc_library."""

    # From .a and .pic.a archives, just use the latter.
    _filter(
        name = name + "_pic_a",
        srcs = srcs,
        suffix = ".pic.a",
    )

    cpu_arch = "X86_64"
    native.genrule(
        name = "get_cpu_gen",
        outs = [cpu_arch],
        cmd = "uname -m",
    )
    cpu_arch = cpu_arch.upper()

    # Device-link to cubins for each architecture.
    images = []
    cubins = []
    for arch in %{gpu_architectures}:
        cubin = "%s_%s.cubin" % (name, arch)
        register_hdr = "%s_%s.h" % (name, arch)
        nvlink = "@local_config_nccl//:nvlink"
        cmd = ("$(location %s) --cpu-arch=%s " % (nvlink, cpu_arch) +
            "--arch=%s $(SRCS) " % arch +
            "--register-link-binaries=$(location %s) " % register_hdr +
            "--output-file=$(location %s)" % cubin)
        native.genrule(
            name = "%s_%s" % (name, arch),
            outs = [register_hdr, cubin],
            srcs = [name + "_pic_a"],
            cmd = cmd,
            tools = [nvlink],
        )
        images.append("--image=profile=%s,file=$(location %s)" % (arch, cubin))
        cubins.append(cubin)

    # Generate fatbin header from all cubins.
    fatbin_hdr = name + ".fatbin.h"
    fatbinary = "@local_config_nccl//:cuda/bin/fatbinary"
    cmd = ("PATH=$$CUDA_TOOLKIT_PATH/bin:$$PATH " + # for bin2c
          "$(location %s) -64 --cmdline=--compile-only --link " % fatbinary +
          "--compress-all %s --create=%%{name}.fatbin " % " ".join(images) +
          "--embedded-fatbin=$@")
    native.genrule(
        name = name + "_fatbin_h",
        outs = [fatbin_hdr],
        srcs = cubins,
        cmd = cmd,
        tools = [fatbinary],
    )

    # Generate the source file #including the headers generated above.
    _gen_link_src(
        name = name + "_cc",
        # Include just the last one, they are equivalent.
        register_hdr = register_hdr,
        fatbin_hdr = fatbin_hdr,
        template = "@local_config_nccl//:cuda/bin/crt/link.stub",
        output = name + ".cc",
    )

    # Compile the source file into the cc_library.
    native.cc_library(
        name = name,
        srcs = [name + "_cc"],
        textual_hdrs = [register_hdr, fatbin_hdr],
        deps = [
            "@local_config_cuda//cuda:cuda_headers",
            "@local_config_cuda//cuda:cudart_static",
        ],
        defines = ["__NV_EXTRA_INITIALIZATION=", "__NV_EXTRA_FINALIZATION="]
    )

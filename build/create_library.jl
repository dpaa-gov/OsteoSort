# Build OSJ as a shared library using PackageCompiler.create_library
# Run from the OsteoSort root directory:
#   julia build/create_library.jl

cd(@__DIR__)
cd("..")  # OsteoSort root

using Pkg
Pkg.activate("OSJ")
Pkg.instantiate()

# Need PackageCompiler in the build environment
Pkg.add("PackageCompiler")
using PackageCompiler

# Build the shared library
# Output goes to dist/libosj/
create_library(
    "OSJ",
    "dist/libosj";
    lib_name = "osj",
    precompile_execution_file = joinpath(@__DIR__, "execution_precompile.jl"),
    incremental = false,
    filter_stdlibs = true,
    force = true
)

println("\n✓ Shared library built at dist/libosj/")
println("  Library: dist/libosj/lib/libosj.so (or .dll)")

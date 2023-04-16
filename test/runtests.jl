using Test, JLLPrefixes, Base.BinaryPlatforms, Pkg
using JLLPrefixes: PkgSpec, flatten_artifact_paths

const verbose = false
const linux64 = Platform("x86_64", "linux")
const linux64_to_linux64 = Platform("x86_64", "linux"; target_arch="x86_64", target_os="linux", target_libc="glibc")

@testset "JLL collection" begin
    function check_zstd_jll(zstd_pkgspec, zstd_artifacts)
        # Ensure this pkgspec is named Zstd_jll
        @test zstd_pkgspec.name == "Zstd_jll"

        # It only had one artifact to download, and it exists
        @test length(zstd_artifacts) == 1
        @test isdir(zstd_artifacts[1])
        @test isfile(joinpath(zstd_artifacts[1], "include", "zstd.h"))
    end

    @testset "Zstd_jll (native)" begin
        # Start with a simple JLL with no dependencies
        artifact_paths = collect_artifact_paths(["Zstd_jll"]; verbose)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)
    end

    # Do another simple JLL installation, but this time for a few different architectures
    for platform in [Platform("aarch64", "linux"), Platform("x86_64", "macos"), Platform("i686", "windows")]
        @testset "Zstd_jll ($(platform))" begin
            artifact_paths = collect_artifact_paths(["Zstd_jll"]; platform, verbose)
            check_zstd_jll(first(artifact_paths)...)

            # Test that we're getting the kind of dynamic library we expect
            artifact_dir = first(first(values(artifact_paths)))
            if os(platform) == "windows"
                libdir = "bin"
                libname = "libzstd-1.dll"
            elseif os(platform) == "macos"
                libdir = "lib"
                libname = "libzstd.1.dylib"
            else
                libdir = "lib"
                libname = "libzstd.so.1"
            end
            @test isfile(joinpath(artifact_dir, libdir, libname))
        end
    end

    # Test that we can request a particular version of Zstd_jll
    @testset "Zstd_jll ($(linux64), v1.4.2+0)" begin
        artifact_paths = collect_artifact_paths([PkgSpec(;name="Zstd_jll", version=v"1.4.2+0")]; platform=linux64, verbose)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)

        # Ensure that this is actually version 1.4.2
        artifact_dir = first(first(values(artifact_paths)))
        @test isfile(joinpath(artifact_dir, "lib", "libzstd.so.1.4.2"))
    end

    # Kick it up a notch; start involving dependencies
    @testset "XML2_jll ($(linux64), v2.9.12+0, dependencies)" begin
        # Lock XML2_jll to v2.9 in case it adds more dependencies in the future
        artifact_paths = collect_artifact_paths([PkgSpec(;name="XML2_jll", version=v"2.9.12+0")]; platform=linux64, verbose)

        @test length(artifact_paths) == 1
        @test sort([p.name for p in keys(artifact_paths)]) == ["XML2_jll"]
        @test length(only(values(artifact_paths))) == 3
    end

    # Install two packages that have nothing to do with eachother at the same time
    @testset "Bzip2_jll + Zstd_jll" begin
        artifact_paths = collect_artifact_paths(["Bzip2_jll", "Zstd_jll"]; verbose)
        @test length(artifact_paths) == 2
        @test sort([p.name for p in keys(artifact_paths)]) == ["Bzip2_jll", "Zstd_jll"]
    end

    # Test stdlibs across versions.  Note that `GMP_jll` was _not_ a standard library in v1.5,
    # it _is_ a standard library in v1.6 and v1.7.
    GMP_JULIA_VERSIONS = [
        ("10.3.2", v"1.5"),
        ("10.4.0", v"1.6"),
        ("10.4.1", v"1.7"),
    ]
    for (GMP_soversion, julia_version) in GMP_JULIA_VERSIONS
        @testset "GMP_jll (Julia $(julia_version))" begin
            artifact_paths = collect_artifact_paths(["GMP_jll"]; platform=Platform("x86_64", "linux"; julia_version), verbose)
            @test length(artifact_paths) == 1
            gmp_artifact_dir = only(first(values(artifact_paths)))
            @test isfile(joinpath(gmp_artifact_dir, "lib", "libgmp.so.$(GMP_soversion)"))
        end
    end

    # Test "impossible" situations via `julia_version == nothing`
    @testset "Impossible Constraints" begin
        # We can't naively install OpenBLAS v0.3.13 and LBT v5.1.1, because those are
        # from conflicting Julia versions, and the Pkg resolver doesn't like that
        for julia_version in (v"1.7.3", v"1.8.0")
            @test_throws Pkg.Resolve.ResolverError collect_artifact_paths([
                PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
                PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
            ]; platform=Platform("x86_64", "linux"; julia_version), verbose)
        end

        # So we must pass julia_version == nothing, as is the case in our `linux64` object
        artifact_paths = collect_artifact_paths([
            PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
            PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
        ]; platform=linux64, verbose)
        @test length(flatten_artifact_paths(artifact_paths)) == 3
        @test sort([p.name for p in keys(artifact_paths)]) == ["OpenBLAS_jll", "libblastrampoline_jll"]
    end

    # Test adding something that doesn't exist on a certain platform
    @testset "Platform Incompatibility" begin
        @test_logs (:warn, r"Dependency Libuuid_jll does not have a mapping for artifact Libuuid for platform") (:warn, r"Unable to find installed artifact") begin
            # This test _must_ be verbose, so we catch the appropriate logs
            artifact_paths = collect_artifact_paths(["Libuuid_jll"]; platform=Platform("x86_64", "macos"), verbose=true)
            @test isempty(artifact_paths)
        end
    end

    @testset "Transitive dependency deduplication" begin
        # Test that when we collect two JLLs that share a transitive dependency, it gets
        # deduplicated when flattened:
        artifact_paths = collect_artifact_paths([
            "libass_jll",
            "wget_jll",
            "Zlib_jll"
        ]; platform=linux64, verbose)
        # Get the Zlib_jll artifact name:
        zlib_artifact_path = only(only([paths for (pkg, paths) in artifact_paths if pkg.name == "Zlib_jll"]))

        # The `Zlib_jll` artifact is counted in every package:
        for (pkg, paths) in artifact_paths
            @test zlib_artifact_path ∈ paths
        end

        # When we flatten the artifact paths, we deduplicate:
        flattened = flatten_artifact_paths(artifact_paths)
        @test zlib_artifact_path ∈ flattened
        @test length(flattened) == length(unique(flattened))
    end

    @testset "Shared dependency resolution" begin
        special_autoconf_pkgspec = PkgSpec(;
            name="autoconf_jll",
            repo=Pkg.Types.GitRepo(
                rev="c726a3f9a56a11c1dbd6d2352a7fe6219e38405a",
                source="https://github.com/staticfloat/autoconf_jll.jl",
            ),
        )

        autoconf_path = only(flatten_artifact_paths(collect_artifact_paths([special_autoconf_pkgspec]; platform=linux64, verbose)))

        # Test that if we have a special version of a JLL, it gets resolved as a dependency of another JLL:
        artifact_paths = collect_artifact_paths([
            special_autoconf_pkgspec,
            PkgSpec(;name="automake_jll"),
        ]; platform=linux64, verbose=true)

        for (pkg, paths) in artifact_paths
            @test autoconf_path ∈ paths
        end
    end
end

exe = ""
if Sys.iswindows()
    exe = ".exe"
end

@testset "FFMPEG installation test" begin
    installer_strategies = [:copy, :hardlink, :symlink, :auto]
    mktempdir() do depot
        for strategy in installer_strategies
            mktempdir() do prefix
                artifact_paths = collect_artifact_paths(["FFMPEG_jll"]; verbose, pkg_depot=depot)
                @testset "$strategy strategy" begin
                    deploy_artifact_paths(prefix, artifact_paths; strategy)

                    # Ensure that a bunch of tools we expect to be installed are, in fact, installed
                    for tool in ("ffmpeg", "fc-cache", "iconv", "x264", "x265")
                        # Use `@eval` here so the test itself shows the tool name, for easier debugging
                        tool_name = string(tool, exe)
                        @eval @test ispath(joinpath($(prefix), "bin", $(tool_name)))

                        # Extra `realpath()` here to explicitly test dereferencing symlinks
                        @eval @test isfile(realpath(joinpath($(prefix), "bin", $(tool_name))))
                    end

                    # Symlinking is insufficient for RPATH, unfortunately.
                    if strategy == :symlink && !Sys.iswindows()
                        @test !success(`$(joinpath(prefix, "bin", "ffmpeg$(exe)")) -version`)
                    else
                        # Hilariously, since Windows doesn't use `RPATH` but just dumps
                        # everything into the `bin` directory, it tends to work just fine:
                        @test success(`$(joinpath(prefix, "bin", "ffmpeg$(exe)")) -version`)
                    end
                end
            end
        end
    end
end

@testset "tree_hash-provided sources" begin
    artifact_paths = collect_artifact_paths([
        PkgSpec(;name="Binutils_jll", version=v"2.38.0+4", tree_hash=Base.SHA1("ffa0762c5e00e109c88f820b3e15fca842ffa808")),
    ]; platform=linux64_to_linux64, verbose)

    # Test that we get precisely the right Binutils_jll version.
    @test any(basename.(only([v for (k, v) in artifact_paths if k.name == "Binutils_jll"])) .== Ref("cfacb1560e678d1d058d397d4b792f0d525ce5e1"))
end

@testset "repo-provided sources" begin
    artifact_paths = collect_artifact_paths([
        PkgSpec(;
            name="Binutils_jll",
            repo=Pkg.Types.GitRepo(
                rev="89943b0c48834fb291b24fb73d90b821185ed44b",
                source="https://github.com/JuliaBinaryWrappers/Binutils_jll.jl"
            ),
        ),
    ]; platform=linux64_to_linux64, verbose)
    @test any(basename.(only([v for (k, v) in artifact_paths if k.name == "Binutils_jll"])) .== "cfacb1560e678d1d058d397d4b792f0d525ce5e1")
end

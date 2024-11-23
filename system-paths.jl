# System path types

abstract type SystemPath <: PlainPath end

selfsegment(::Type{<:SystemPath}) = "."
parentsegment(::Type{<:SystemPath}) = ".."

struct PosixPath <: SystemPath
    path::GenericPlainPath{PosixPath}
end

struct WindowsPath <: SystemPath
    path::GenericPlainPath{WindowsPath}
end

separator(::Type{PosixPath}) = '/'
# Note that Windows also use `/` as separator (inconsistently, but nonetheless).
# So both must be supported
separator(::Type{WindowsPath}) = '\\'

genericpath(path::PosixPath) = path.path
genericpath(path::WindowsPath) = path.path

# I actually like this approach very much: Having a distinct WindowsPath and PosixPath
# and then aliasing Path to whatever the native path is.
# I think, then, that only methods on `Path` should be documented, showing both behaviours
# of Windows and Posix. This way, we are very upfront about platform differences
const Path = @static if Sys.iswindows()
    WindowsPath
else
    PosixPath
end

# System path buffer types

struct PosixPathBuf <: SystemPath
    path::GenericPlainPathBuf{PosixPath}
end

struct WindowsPathBuf <: SystemPath
    path::GenericPlainPathBuf{WindowsPath}
end

# Same as above
separator(::Type{PosixPathBuf}) = '/'
separator(::Type{WindowsPathBuf}) = '\\'

genericpath(path::PosixPathBuf) = path.path
genericpath(path::WindowsPathBuf) = path.path

# REVIEW: Consider generic fallback implementations for these methods with "invalid" type errors

Base.push!(path::PosixPathBuf, segment::AbstractString) = (push!(path.path, segment); path)
Base.push!(path::WindowsPathBuf, segment::AbstractString) = (push!(path.path, segment); path)

Base.pop!(path::PosixPathBuf) = pop!(path.path)
Base.pop!(path::WindowsPathBuf) = pop!(path.path)

Base.popfirst!(path::PosixPathBuf) = popfirst!(path.path)
Base.popfirst!(path::WindowsPathBuf) = popfirst!(path.path)

Base.setindex!(path::PosixPathBuf, segment::String, index::Int) = (setindex!(path.path, segment, index); path)
Base.setindex!(path::WindowsPathBuf, segment::String, index::Int) = (setindex!(path.path, segment, index); path)

const PathBuf = @static if Sys.iswindows()
    WindowsPathBuf
else
    PosixPathBuf
end

Base.convert(::Type{PosixPath}, path::PosixPathBuf) = PosixPath(convert(GenericPlainPath{PosixPath}, path.path))
Base.convert(::Type{PosixPathBuf}, path::PosixPath) = PosixPathBuf(convert(GenericPlainPathBuf{PosixPath}, path.path))

Base.convert(::Type{WindowsPath}, path::WindowsPathBuf) = WindowsPath(convert(GenericPlainPath{WindowsPath}, path.path))
Base.convert(::Type{WindowsPathBuf}, path::WindowsPath) = WindowsPathBuf(convert(GenericPlainPathBuf{WindowsPath}, path.path))

PosixPath(path::PosixPathBuf) = convert(PosixPath, path)
PosixPathBuf(path::PosixPath) = convert(PosixPathBuf, path)

WindowsPath(path::WindowsPathBuf) = convert(WindowsPath, path)
WindowsPathBuf(path::WindowsPath) = convert(WindowsPathBuf, path)

# ---------------------
# FIXME: Hacky constructors as a stopgap
# ---------------------

function PosixPath(path::String)
    npath = rstrip(normpath(path), separator(PosixPath))
    rootsep = first(npath) == separator(PosixPath)
    lastsep = something(findlast(==(separatorbyte(PosixPath)), codeunits(npath)), 0)
    PosixPath(GenericPlainPath{PosixPath}(npath, rootsep, ifelse(lastsep > 1, lastsep, 0), 0))
end

function WindowsPath(path::String)
    npath = normpath(path)
    drive, _ = splitdrive(npath)
    rootsep = if isempty(drive) 0 else ncodeunits(drive) + 1 end
    lastsep = something(findlast(==(separatorbyte(WindowsPath)), codeunits(npath)), 0)
    WindowsPath(GenericPlainPath{WindowsPath}(npath, rootsep, lastsep, 0))
end

# It would be nice if there was a second argument to the macro, to be explicit
# about what paths to create. We could have `p"/abc/def"w` for Windows, e.g.
# Maybe not too relevant for Windows and Posix paths, but could make sense for
# e.g. URIs.

# Super basic for now, should support interpolation etc. eventually
macro p_str(path::String)
    Path(path)
end

using Test
@testset "Some edge cases" begin
    # Surely, the first element of an absolute path is the root dir?
    @test first(p"/abc/def") == "/"
    @test first(WindowsPath("C:\\abc")) == "C:"

    for p in [p"/", p".", p"abc"]
        @test basename(p) == p
    end
    # The last dir may be symlink, so .. brings us to an unknown
    # location in general
    for p in [p"..", p"/abc/def/..", p"/abc/..//"]
        @test basename(p) === nothing
    end
    # Exception: / cannot be a symlink, so this is valid
    @test basename(p"/..") == p"/"

    # These currently fail for some reason
    @test collect(p"abc/def") == ["abc", "def"]
    @test collect(p"/abc/def") == ["/", "abc", "def"]

    # I think if you add '\0' bytes to the end of paths, you also
    # need to check at construction that they never contain
    # null bytes within them.
    # I don't really know if it's worth it for the C interop, but maybe
    # you know more about that than I do.
    @test_throws Exception p"abc\0def/ghi"

    # I'm actually warming up on the idea of paths being iterables of their components.
    # But maybe not SubString? Maybe instead `Path` elements?
    # Perhaps it's weird that paths iterate themselves
    @test length(p"abc") == 1
    @test length(p"abc/def") == 2
    @test length(p"/abc/def") == 3 # root is its own directory
    @test length(p"/abc/./def") == 3
    # This is arguable, but I would emit .. as its distinct path element.
    # See e.g. https://doc.rust-lang.org/src/std/path.rs.html#500
    @test length(p"/abc/../def") == 4
end
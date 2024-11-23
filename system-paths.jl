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
separator(::Type{WindowsPath}) = '\\'

genericpath(path::PosixPath) = path.path
genericpath(path::WindowsPath) = path.path

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

# Super basic for now, should support interpolation etc. eventually
macro p_str(path::String)
    Path(path)
end

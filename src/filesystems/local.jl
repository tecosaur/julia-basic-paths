"""
    LocalFilesystem <: AbstractFilesystem

Filesystem representing the host operating system's local filesystem.

`LocalFilesystem` provides access to files and directories managed by the
underlying OS, using native path resolution and handle semantics.

Handles produced by this filesystem typically wrap operating system file
descriptors or equivalent native resources.
"""
struct LocalFilesystem <: AbstractFilesystem end

"""
    LocalFileHandle <: AbstractFileHandle{LocalFilesystem}

Handle to a resource on the local filesystem.

A `LocalFileHandle` represents an authoritative reference to a local filesystem
object, typically backed by an operating system file descriptor. Operations on
this handle interact directly with the underlying OS resource.
"""
mutable struct LocalFileHandle <: AbstractFileHandle{LocalFilesystem, LocalFileHandle}
    const fd::Base.OS_HANDLE
    const flags::UInt32
    open::Bool
end

filesystem(::LocalFileHandle) = LocalFilesystem()

"""
    SystemPath <: PlatformPath

An abstract type for paths that are native to the current operating system.
"""
abstract type SystemPath <: PlatformPath{LocalFileHandle} end

const PureLocalFilepath = @static if Sys.iswindows()
    WindowsPath
else
    PosixPath
end

"""
    LocalFilepath <: AbstractFilepath{LocalFileHandle}

Filesystem path referring to a location on the local filesystem.

This type supports pure path manipulation independently of filesystem state.
"""
struct LocalFilepath <: SystemPath
    path::PureLocalFilepath
end

separator(::LocalFilepath) = separator(PureLocalFilepath)
genericpath(path::LocalFilepath) = genericpath(path.path)

LocalFilepath(args...) = LocalFilepath(PureLocalFilepath(args...))

function Base.parse(::Type{LocalFilepath}, str::AbstractString)
    LocalFilepath(parse(PureLocalFilepath, str))
end

function Base.show(io::IO, path::LocalFilepath)
    print(io, "p\"")
    for (i, segment) in enumerate(path)
        i > (1 + isone(path.path.path.rootsep)) && print(io, '/')
        print(io, segment)
    end
    print(io, '"')
end

struct DirEntry <: SystemPath
    parent::LocalFileHandle
    name::String
    type::UInt8
end

root(de::DirEntry) = root(de.parent)
isabsolute(de::DirEntry) = isabsolute(de.parent)
Base.parent(de::DirEntry) = convert(LocalFilepath, de.parent)
Base.basename(de::DirEntry) = SubString(de.name)
Base.length(de::DirEntry) = length(parent(de)) + 1
function Base.convert(::Type{LocalFilepath}, de::DirEntry)
    namep = PureLocalFilepath(GenericPlainPath{PureLocalFilepath}(de.name, 0, 0))
    joinpath(parent(de), namep)
end
genericpath(de::DirEntry) = convert(LocalFilepath, de)

# Platform-specific implementations of the AbstractFilesystem interface
@static if Sys.iswindows()
    include("windows.jl")
else
    include("posix.jl")
end

# Generic methods of the AbstractFilesystem interface

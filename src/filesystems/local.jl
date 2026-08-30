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

Base.isopen(h::LocalFileHandle) = h.open

filesystem(::LocalFileHandle) = LocalFilesystem()

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
struct LocalFilepath <: PlatformPath{LocalFileHandle}
    path::PureLocalFilepath
end

separator(::Type{LocalFilepath}) = separator(PureLocalFilepath)
genericpath(path::LocalFilepath) = genericpath(path.path)
validate_path(::Type{InvalidSegment{T}}, ::Type{LocalFilepath}, segment::AbstractString, multipart::Bool = true) where {T <: PlatformPath} =
    validate_path(InvalidSegment{T}, PureLocalFilepath, segment, multipart)

LocalFilepath(path::AbstractString) = LocalFilepath(PureLocalFilepath(path))
LocalFilepath(components::AbstractVector{<:AbstractString}) = LocalFilepath(PureLocalFilepath(components))

function Base.parse(::Type{LocalFilepath}, str::AbstractString)
    LocalFilepath(parse(PureLocalFilepath, str))
end

Base.convert(P::Type{<:PlatformPath}, path::LocalFilepath) = convert(P, path.path)

function Base.show(io::IO, path::LocalFilepath)
    print(io, "p\"")
    for (i, segment) in enumerate(path)
        i > (1 + isone(path.path.path.rootsep)) && print(io, '/')
        print(io, segment)
    end
    print(io, '"')
end

const LocalRelpath = RelativePath{LocalFileHandle, LocalFilepath}

# Platform-specific implementations of the AbstractFilesystem interface
@static if Sys.iswindows()
    include("windows.jl")
else
    include("posix.jl")
end

# Generic methods of the AbstractFilesystem interface

# FIXME: These really shouldn't be hard-coded
const AT_EMPTY_PATH = 0x1000
const O_PATH = 0x00200000
const AT_FDCWD = -100
const AT_SYMLINK_NOFOLLOW = 0x100

using Base.Filesystem: JL_O_RDONLY, JL_O_DIRECTORY, JL_O_NOFOLLOW, JL_O_CLOEXEC

Base.cconvert(::Type{RawFD}, hdl::LocalFileHandle) = hdl.fd

function handle(path::LocalFilepath, flags::Integer = O_PATH)
    pfd = @ccall open(String(path)::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("open"))
    p = LocalFileHandle(pfd, flags, true)
    finalizer(close, p)
    p
end

function handle(rel::LocalRelpath, flags::Integer = O_PATH)
    checkopen(rel.parent)
    pfd = @ccall openat(rel.parent::RawFD, rel.path::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("openat"))
    p = LocalFileHandle(pfd, flags, true)
    finalizer(close, p)
    p
end

handle(de::DirEntry, flags::Integer = O_PATH) = handle(de.rel, flags)

function checkopen(hdl::LocalFileHandle)
    if !isopen(hdl)
        throw(ArgumentError("File handle is not open"))
    end
end

function Base.close(hdl::LocalFileHandle)
    hdl.open || return
    hdl.open = false
    err = @ccall close(hdl.fd::RawFD)::Int
    if err < 0
        throw(SystemError("close"))
    end
end

function reopen(hdl::LocalFileHandle, flags::Integer)
    isopen(hdl) || return hdl # Downstream methods should check for open-ness
    hdl.flags == flags && return hdl
    procpath = string("/proc/self/fd/", reinterpret(Int32, hdl.fd))
    newfd = @ccall open(procpath::Cstring, flags::Cint)::RawFD
    if newfd == -1
        throw(SystemError("open"))
    end
    LocalFileHandle(newfd, flags, true)
end

function Base.convert(::Type{LocalFilepath}, hdl::LocalFileHandle)
    path = readlink(string("/proc/self/fd/", reinterpret(Int32, hdl.fd)))
    lastsep = something(findlast(==(separatorbyte(PureLocalFilepath)), codeunits(path)), 0)
    LocalFilepath(PureLocalFilepath(GenericPlainPath{PureLocalFilepath}(path, 1, ifelse(lastsep > 1, lastsep, 0))))
end

function Base.show(io::IO, hdl::LocalFileHandle)
    show(io, handle)
    print(io, '(')
    show(io, convert(LocalFilepath, hdl))
    print(io, ')')
end

# AbstractFilesystem interface

# TODO

function openflags(; read     :: Union{Bool, Nothing} = nothing,
                     write    :: Union{Bool, Nothing} = nothing,
                     create   :: Union{Bool, Nothing} = nothing,
                     truncate :: Union{Bool, Nothing} = nothing,
                     append   :: Union{Bool, Nothing} = nothing)
    opts = Base.open_flags(; read, write, create, truncate, append)
    flags = if opts.read && (opts.write || opts.append)
        Base.Filesystem.JL_O_RDWR
    elseif opts.write
        Base.Filesystem.JL_O_WRONLY
    else
        Base.Filesystem.JL_O_RDONLY
    end
    opts.create && (flags |= Base.Filesystem.JL_O_CREAT)
    opts.append && (flags |= Base.Filesystem.JL_O_APPEND)
    opts.truncate && (flags |= Base.Filesystem.JL_O_TRUNC)
    flags
end

function Base.open(hdl::LocalFileHandle; lock::Bool = true, kwargs...)
    flags = openflags(; kwargs...)
    io = if hdl.flags == flags
        fdio(reinterpret(Int32, hdl.fd), false)
    else
        fdio(reinterpret(Int32, reopen(hdl, flags).fd), true)
    end
    io._dolock = lock
    io
end

function openio(dirfd::RawFD, name; lock::Bool = true, kwargs...)
    flags = openflags(; kwargs...) | JL_O_CLOEXEC
    fd = @ccall openat(dirfd::RawFD, name::Cstring, flags::Cint, 0o666::Cint)::RawFD
    reinterpret(Int32, fd) < 0 && throw(SystemError("openat"))
    io = fdio(reinterpret(Int32, fd), true)
    io._dolock = lock
    io
end

Base.open(rel::LocalRelpath; kwargs...) = (checkopen(rel.parent); openio(rel.parent.fd, rel.path; kwargs...))
Base.open(entry::DirEntry; kwargs...) = open(entry.rel; kwargs...)
Base.open(path::LocalFilepath; kwargs...) = openio(RawFD(AT_FDCWD), path; kwargs...)

# Stat

const StatForm = @NamedTuple{
    dev::UInt64,
    ino::UInt64,
    nlink::UInt64,
    mode::UInt32,
    uid::UInt32,
    gid::UInt32,
    _0::UInt32, # Padding
    rdev::UInt64,
    size::UInt64,
    blksize::UInt64,
    blocks::UInt64,
    asecs::UInt64,
    ansecs::UInt64,
    msecs::UInt64,
    mnsecs::UInt64,
    csecs::UInt64,
    cnsecs::UInt64
}

function statinterpret(desc::Union{String, RawFD}, statbuf::Memory{UInt8}, err::Int32)
    statinfos = reinterpret(StatForm, view(statbuf, 1:sizeof(StatForm)))
    length(statinfos) == 1 || error("Huh, what's this?")
    si = first(statinfos)
    Base.Filesystem.StatStruct(
        desc,
        UInt(si.dev),
        UInt(si.ino),
        UInt(si.mode),
        Int(si.nlink),
        UInt(si.uid),
        UInt(si.gid),
        UInt(si.rdev),
        Int64(si.size),
        Int64(si.blksize),
        Int64(si.blocks),
        muladd(si.mnsecs, 1e-9, si.msecs),
        muladd(si.cnsecs, 1e-9, si.csecs),
        Int32(err))
end

function Base.stat(path::LocalFileHandle)
    checkopen(path)
    statbuf = fill!(Memory{UInt8}(undef, Int(ccall(:jl_sizeof_stat, Int32, ()))), 0x00)
    err = @ccall fstat(path.fd::Cint, statbuf::Ptr{UInt8})::Int32
    if err < 0
        throw(SystemError("fstat"))
    end
    statinterpret("<LocalFileHandle>", statbuf, err)
end

Base.samefile(a::LocalFileHandle, b::LocalFileHandle) = samefile(stat(a), stat(b))

for f in Symbol[
    :ispath,
    :isdir,
    :isfile,
    :isfifo,
    :ischardev,
    :isblockdev,
    :issocket,
    :issetuid,
    :issetgid,
    :issticky,
    :uperm,
    :gperm,
    :operm,
    :filemode,
    :filesize,
    :mtime,
    :ctime,
]
    @eval (Base.$f)(path::LocalFileHandle)  = ($f)(stat(path))
end

# Directory iterator

const DIRECTORY_FLAGS = JL_O_RDONLY | JL_O_DIRECTORY | JL_O_CLOEXEC

"""
    DirReader

Iterator over the entries of a directory stream, yielding `DirEntry`s relative
to `dir`. The stream is closed once exhausted, or by `close`, and reopened from
`dir` when iterated again; when `ownsdir`, `dir` wraps the stream's own
descriptor and is closed with it, so the reader cannot be restarted.
"""
mutable struct DirReader
    const dir::LocalFileHandle
    const ownsdir::Bool
    dirp::Ptr{Cvoid}
end

DirReader(dir::LocalFileHandle, fd::RawFD, ownsdir::Bool) =
    finalizer(close, DirReader(dir, ownsdir, fdopendir(fd)))

function fdopendir(fd::RawFD)
    dirp = @ccall fdopendir(fd::RawFD)::Ptr{Cvoid}
    dirp == C_NULL && throw(SystemError("fdopendir"))
    dirp
end

Base.isopen(reader::DirReader) = reader.dirp != C_NULL
Base.IteratorSize(::Type{DirReader}) = Base.SizeUnknown()
Base.eltype(::Type{DirReader}) = DirEntry

function Base.close(reader::DirReader)
    isopen(reader) || return
    dirp, reader.dirp = reader.dirp, C_NULL
    reader.ownsdir && (reader.dir.open = false)
    @ccall(closedir(dirp::Ptr{Cvoid})::Cint) < 0 && throw(SystemError("closedir"))
end

function opendir(dirfd::RawFD, name)
    fd = @ccall openat(dirfd::RawFD, name::Cstring, DIRECTORY_FLAGS::Cint, 0::Cint)::RawFD
    reinterpret(Int32, fd) >= 0 && return fd
    Libc.errno() in (Libc.ENOTDIR, Libc.ELOOP) || throw(SystemError("openat"))
    nothing
end

function children(dir::LocalFileHandle)
    checkopen(dir)
    fd = opendir(dir.fd, ".")
    if !isnothing(fd) DirReader(dir, fd, false) end
end

ownedreader(::Nothing) = nothing
ownedreader(fd::RawFD) = DirReader(LocalFileHandle(fd, DIRECTORY_FLAGS, true), fd, true)

children(rel::LocalRelpath) = (checkopen(rel.parent); ownedreader(opendir(rel.parent.fd, rel.path)))
children(entry::DirEntry) = children(entry.rel)
children(path::LocalFilepath) = ownedreader(opendir(RawFD(AT_FDCWD), path))

const DENT_TYPE_OFFSET = sizeof(UInt64) + sizeof(UInt64) + sizeof(UInt16)
const DENT_NAME_OFFSET = DENT_TYPE_OFFSET + sizeof(UInt8)

function Base.iterate(reader::DirReader)
    if isopen(reader)
        @ccall rewinddir(reader.dirp::Ptr{Cvoid})::Cvoid
    elseif reader.ownsdir
        throw(ArgumentError("Cannot restart a directory reader whose directory has been closed"))
    else
        checkopen(reader.dir)
        reader.dirp = fdopendir(opendir(reader.dir.fd, "."))
    end
    iterate(reader, nothing)
end

function Base.iterate(reader::DirReader, ::Nothing)
    function ispseudopath(name::Ptr{UInt8})
        unsafe_load(name) == UInt8('.') || return false
        second = unsafe_load(name + 1)
        second == 0 || second == UInt8('.') && unsafe_load(name + 2) == 0
    end
    isopen(reader) || return
    while true
        Libc.errno(0)
        dent = @ccall readdir(reader.dirp::Ptr{Cvoid})::Ptr{Cvoid}
        if dent == C_NULL
            err = Libc.errno()
            close(reader)
            iszero(err) || throw(SystemError("readdir", err))
            return
        end
        name = Ptr{UInt8}(dent) + DENT_NAME_OFFSET
        ispseudopath(name) && continue
        path = LocalFilepath(PureLocalFilepath(GenericPlainPath{PureLocalFilepath}(unsafe_string(name), 0, 0)))
        return DirEntry(LocalRelpath(reader.dir, path), unsafe_load(Ptr{UInt8}(dent) + DENT_TYPE_OFFSET)), nothing
    end
end

const DENT_TYPES = (
    unknown = 0,
    fifo = 1,
    chardev = 2,
    dir = 4,
    blockdev = 6,
    regular = 8,
    link = 10,
    socket = 12,
    whiteout = 14,
)

Base.islink(entry::DirEntry) =
    if entry.type == DENT_TYPES.unknown islink(lstat(entry)) else entry.type == DENT_TYPES.link end

for (func, dtval) in ((:isfifo, :fifo),
                      (:ischardev, :chardev),
                      (:isdir, :dir),
                      (:isblockdev, :blockdev),
                      (:isfile, :regular),
                      (:issocket, :socket))
    @eval function Base.$func(entry::DirEntry)
        if entry.type in (DENT_TYPES.unknown, DENT_TYPES.link)
            $func(stat(entry))
        else
            entry.type == DENT_TYPES.$dtval
        end
    end
end

Base.stat(entry::DirEntry) = fstatat(entry, 0)
Base.lstat(entry::DirEntry) = fstatat(entry, AT_SYMLINK_NOFOLLOW)

function fstatat(entry::DirEntry, flags::Integer)
    checkopen(entry.rel.parent)
    statbuf = fill!(Memory{UInt8}(undef, Int(ccall(:jl_sizeof_stat, Int32, ()))), 0x00)
    err = @ccall fstatat(entry.rel.parent.fd::RawFD, entry.rel.path::Cstring, statbuf::Ptr{UInt8}, flags::Cint)::Int32
    err < 0 && throw(SystemError("fstatat"))
    statinterpret("<DirEntry>", statbuf, err)
end

# Extra methods: filesystem details

function Base.isexecutable(hdl::Path)
    checkopen(hdl)
    X_OK = 0x01
    ret = @ccall faccessat(hdl.fd::RawFD, ""::Cstring, X_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

function Base.isreadable(hdl::Path)
    checkopen(hdl)
    R_OK = 0x04
    ret = @ccall faccessat(hdl.fd::RawFD, ""::Cstring, R_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

function Base.iswritable(hdl::Path)
    checkopen(hdl)
    W_OK = 0x02
    ret = @ccall faccessat(hdl.fd::RawFD, ""::Cstring, W_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

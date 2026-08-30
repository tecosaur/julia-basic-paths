# FIXME: These constants, the dirent offsets and `StatForm` are hard-coded for glibc on x86-64
const AT_EMPTY_PATH = 0x1000
const O_PATH = 0x00200000
const AT_FDCWD = -100
const AT_SYMLINK_NOFOLLOW = 0x100

using Base.Filesystem: JL_O_RDONLY, JL_O_DIRECTORY, JL_O_NOFOLLOW, JL_O_CLOEXEC

Base.cconvert(::Type{RawFD}, hdl::LocalFileHandle) = hdl.fd

function openat(dirfd::RawFD, name, flags::Integer)
    fd = @ccall openat(dirfd::RawFD, name::Ptr{UInt8}, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, fd) < 0 && throw(SystemError("openat"))
    finalizer(close, LocalFileHandle(fd, flags, true))
end

handle(path::LocalFilepath, flags::Integer = O_PATH) = openat(RawFD(AT_FDCWD), path, flags)
handle(rel::LocalRelpath, flags::Integer = O_PATH) = (checkopen(rel.parent); openat(rel.parent.fd, rel.path, flags))

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
    fd = @ccall openat(dirfd::RawFD, name::Ptr{UInt8}, flags::Cint, 0o666::Cint)::RawFD
    reinterpret(Int32, fd) < 0 && throw(SystemError("openat"))
    io = fdio(reinterpret(Int32, fd), true)
    io._dolock = lock
    io
end

Base.open(rel::LocalRelpath; kwargs...) = (checkopen(rel.parent); openio(rel.parent.fd, rel.path; kwargs...))
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
    cnsecs::UInt64,
    _1::NTuple{3, Int64} # glibc reserved tail; sizeof == struct stat
}

function statinterpret(desc::Union{String, RawFD}, si::StatForm, err::Int32)
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
    statbuf = Ref{StatForm}()
    err = @ccall fstat(path.fd::Cint, statbuf::Ref{StatForm})::Int32
    err < 0 && throw(SystemError("fstat"))
    statinterpret("<LocalFileHandle>", statbuf[], err)
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

const DIRENT_BUFFER_BYTES = 32768
const DIRENT_BUFFERS = Memory{UInt8}[]
const DIRENT_BUFFERS_LOCK = ReentrantLock()

function acquirebuffer()
    @lock DIRENT_BUFFERS_LOCK if isempty(DIRENT_BUFFERS) Memory{UInt8}(undef, DIRENT_BUFFER_BYTES) else pop!(DIRENT_BUFFERS) end
end

"""
    DirReader

Single-pass iterator over the entries of the directory `dir` (relative to the
root of the traversal); closed once exhausted or by `close`. Iterating a
still-open reader again rewinds it.

Entries are views into the reader's buffer, valid until the next refill or
`close` (tracked by `generation`, checked before every use).
"""
mutable struct DirReader
    const dir::LocalFilepath
    const fd::RawFD
    const buf::Memory{UInt8}
    open::Bool
    pos::Int
    len::Int
    generation::UInt32
end

DirReader(fd::RawFD, dir::LocalFilepath) = # a finalizer must not take the pool lock, so it drops its buffer instead
    finalizer(reader -> release(reader, false), DirReader(dir, fd, acquirebuffer(), true, 0, 0, 0))

Base.isopen(reader::DirReader) = reader.open
Base.IteratorSize(::Type{DirReader}) = Base.SizeUnknown()
Base.eltype(::Type{DirReader}) = DirEntry

Base.show(io::IO, reader::DirReader) =
    print(io, "DirReader(", reader.dir, if isopen(reader) "" else ", closed" end, ")")

Base.close(reader::DirReader) = release(reader, true)

function release(reader::DirReader, pool::Bool)
    isopen(reader) || return
    reader.open = false
    reader.generation += 1
    pool && @lock DIRENT_BUFFERS_LOCK push!(DIRENT_BUFFERS, reader.buf)
    @ccall(close(reader.fd::RawFD)::Cint) < 0 && throw(SystemError("close"))
end

"""
    DirEntry

An entry of a directory being read by a `DirReader`: a name and `d_type`
within a known directory. `relpath(entry)` gives its path relative to the root
of the traversal, and `parent(entry)` its directory likewise.
"""
struct DirEntry <: AbstractResolvable{LocalFileHandle}
    reader::DirReader
    generation::UInt32
    nameoffset::UInt16
    namelen::UInt8
    type::UInt8
end

function entryname(entry::DirEntry)
    entry.generation == entry.reader.generation ||
        throw(ArgumentError("Directory entry is stale: its reader has refilled or closed the buffer it was read from"))
    StringView(view(entry.reader.buf, Int(entry.nameoffset):Int(entry.nameoffset) + entry.namelen - 1))
end

function joinname(dir::LocalFilepath, name::AbstractString)
    gdir = genericpath(dir)
    gdir.data == pseudoself(PureLocalFilepath) &&
        return LocalFilepath(PureLocalFilepath(GenericPlainPath{PureLocalFilepath}(String(name), 0, 0)))
    dlen, nlen = ncodeunits(gdir.data), ncodeunits(name)
    sep = dlen + (codeunit(gdir.data, dlen) != separatorbyte(PureLocalFilepath))
    out = Base._string_n(sep + nlen)
    GC.@preserve out gdir name begin
        unsafe_copyto!(pointer(out), pointer(gdir.data), dlen)
        unsafe_store!(pointer(out, sep), separatorbyte(PureLocalFilepath))
        unsafe_copyto!(pointer(out, sep + 1), pointer(name), nlen)
    end
    LocalFilepath(PureLocalFilepath(GenericPlainPath{PureLocalFilepath}(out, gdir.rootsep, if sep > gdir.rootsep sep else 0 end)))
end

Base.basename(entry::DirEntry) = String(entryname(entry))
relpath(entry::DirEntry) = joinname(entry.reader.dir, entryname(entry))
Base.parent(entry::DirEntry) = entry.reader.dir
handle(entry::DirEntry, flags::Integer = O_PATH) = openat(entry.reader.fd, entryname(entry), flags)
Base.open(entry::DirEntry; kwargs...) = openio(entry.reader.fd, entryname(entry); kwargs...)

function Base.show(io::IO, entry::DirEntry)
    print(io, "DirEntry(")
    if entry.generation == entry.reader.generation show(io, relpath(entry)) else print(io, "stale") end
    print(io, ')')
end

function opendir(dirfd::RawFD, name, dir::LocalFilepath)
    fd = @ccall openat(dirfd::RawFD, name::Ptr{UInt8}, DIRECTORY_FLAGS::Cint, 0::Cint)::RawFD
    reinterpret(Int32, fd) >= 0 && return DirReader(fd, dir)
    Libc.errno() in (Libc.ENOTDIR, Libc.ELOOP) || throw(SystemError("openat"))
    nothing
end

children(path::LocalFilepath) = opendir(RawFD(AT_FDCWD), path, LocalFilepath("."))
children(dir::LocalFileHandle) = (checkopen(dir); opendir(dir.fd, ".", LocalFilepath(".")))
children(rel::LocalRelpath) = (checkopen(rel.parent); opendir(rel.parent.fd, rel.path, rel.path))
children(entry::DirEntry) = opendir(entry.reader.fd, entryname(entry), relpath(entry))

const DENT_RECLEN_OFFSET = sizeof(UInt64) + sizeof(UInt64)
const DENT_TYPE_OFFSET = DENT_RECLEN_OFFSET + sizeof(UInt16)
const DENT_NAME_OFFSET = DENT_TYPE_OFFSET + sizeof(UInt8)

function Base.iterate(reader::DirReader)
    isopen(reader) || throw(ArgumentError("Directory reader is closed; call `children` again to re-read the directory"))
    @ccall(lseek(reader.fd::RawFD, 0::Int64, 0::Cint)::Int64) < 0 && throw(SystemError("lseek"))
    reader.pos, reader.len = 0, 0
    iterate(reader, nothing)
end

function Base.iterate(reader::DirReader, ::Nothing)
    isopen(reader) || return
    buf = reader.buf
    while true
        if reader.pos >= reader.len
            n = @ccall getdents64(reader.fd::RawFD, buf::Ptr{UInt8}, length(buf)::Csize_t)::Cssize_t
            if n <= 0
                err = Libc.errno()
                close(reader)
                n < 0 && throw(SystemError("getdents64", err))
                return
            end
            reader.pos, reader.len, reader.generation = 0, n, reader.generation + 1
        end
        dent = reader.pos
        reader.pos += @inbounds buf[dent + DENT_RECLEN_OFFSET + 1] | UInt16(buf[dent + DENT_RECLEN_OFFSET + 2]) << 8
        nameoffset = dent + DENT_NAME_OFFSET + 1
        namelen = something(findnext(iszero, buf, nameoffset)) - nameoffset
        @inbounds (namelen == 1 && buf[nameoffset] == UInt8('.')) && continue
        @inbounds (namelen == 2 && buf[nameoffset] == UInt8('.') && buf[nameoffset + 1] == UInt8('.')) && continue
        return DirEntry(reader, reader.generation, UInt16(nameoffset), UInt8(namelen), @inbounds buf[dent + DENT_TYPE_OFFSET + 1]), nothing
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
    statbuf = Ref{StatForm}()
    err = @ccall fstatat(entry.reader.fd::RawFD, entryname(entry)::Ptr{UInt8}, statbuf::Ref{StatForm}, flags::Cint)::Int32
    err < 0 && throw(SystemError("fstatat"))
    statinterpret("<DirEntry>", statbuf[], err)
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

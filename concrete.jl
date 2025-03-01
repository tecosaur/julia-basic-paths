# Linux only currently

if !Sys.islinux()
    @warn "The concrete path implementation (Path) is Linux-only at the moment."
end

# FIXME: These really shouldn't be hard-coded
const AT_EMPTY_PATH = 0x1000
const O_PATH = 0x00200000
const AT_FDCWD = -100

mutable struct Path <: SystemPath
    const fd::RawFD
    const flags::UInt32
    open::Bool
end

function Path(path::PurePath, flags::Integer = O_PATH)
    pfd = @ccall open(String(path)::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("open"))
    p = Path(pfd, flags, true)
    finalizer(close, p)
    p
end

function Path(parent::Path, child::PurePath, flags::Integer = O_PATH)
    checkopen(parent)
    pfd = @ccall openat(parent.fd::RawFD, String(child)::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("openat"))
    p = Path(pfd, flags, true)
    finalizer(close, p)
    p
end

function Base.close(path::Path)
    path.open || return
    path.open = false
    err = @ccall close(path.fd::RawFD)::Int
    if err < 0
        throw(SystemError("close"))
    end
end

Base.isopen(p::Path) = p.open

function checkopen(path::Path)
    if !isopen(path)
        throw(ArgumentError("Path is not open"))
    end
end

function reopen(path::Path, flags::Integer)
    isopen(path) || return path # Downstream methods should check for open-ness
    path.flags == flags && return path
    procpath = string("/proc/self/fd/", reinterpret(Int32, path.fd))
    newfd = @ccall open(procpath::Cstring, flags::Cint)::RawFD
    if newfd == -1
        throw(SystemError("open"))
    end
    Path(newfd, flags, true)
end

function Base.convert(::Type{PurePath}, pd::Path)
    path = readlink(string("/proc/self/fd/", reinterpret(Int32, pd.fd)))
    lastsep = something(findlast(==(separatorbyte(PurePath)), codeunits(path)), 0)
    PurePath(GenericPlainPath{PurePath}(path, 1, ifelse(lastsep > 1, lastsep, 0)))
end

# AbstractPath interface
root(::Path) = p"/"
isabsolute(::Path) = true
Base.parent(pd::Path) = Path(parent(convert(PurePath, pd)))
Base.basename(pd::Path) = basename(convert(PurePath, pd))
Base.length(pd::Path) = length(convert(PurePath, pd))
Base.iterate(pd::Path) = iterate(convert(PurePath, pd))
Base.iterate(pd::Path, i::Int) = iterate(convert(PurePath, pd), i)
# PlainPath interface
separator(::Type{Path}) = separator(PurePath)
Base.String(pd::Path) = String(convert(PurePath, pd))
# Trivial filesystem API
Base.realpath(pd::Path) = pd

function Base.show(io::IO, pd::Path)
    show(io, Path)
    print(io, '(')
    show(io, convert(PurePath, pd))
    print(io, ')')
end

# See `iostream.jl`
function Base.open(path::Path; lock = true,
    read     :: Union{Bool,Nothing} = nothing,
    write    :: Union{Bool,Nothing} = nothing,
    create   :: Union{Bool,Nothing} = nothing,
    truncate :: Union{Bool,Nothing} = nothing,
    append   :: Union{Bool,Nothing} = nothing,
)
    flagopts = Base.open_flags(
        read = read,
        write = write,
        create = create,
        truncate = truncate,
        append = append,
    )
    flags = 0x0000
    if flagopts.read && (flagopts.write || flagopts.append)
        flags |= Base.Filesystem.JL_O_RDWR
    elseif flagopts.read
        flags |= Base.Filesystem.JL_O_RDONLY
    elseif flagopts.write
        flags |= Base.Filesystem.JL_O_WRONLY
    end
    flagopts.append && (flags |= Base.Filesystem.JL_O_APPEND)
    flagopts.truncate && (flags |= Base.Filesystem.JL_O_TRUNC)
    if path.flags == flags
        fdio(reinterpret(Int32, path.fd), false)
    else
        fdio(reinterpret(Int32, reopen(path, flags).fd), true)
    end
 end

# From `filesystem.jl`

function Base.isexecutable(path::Path)
    checkopen(path)
    X_OK = 0x01
    ret = @ccall faccessat(path.fd::RawFD, ""::Cstring, X_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

function Base.isreadable(path::Path)
    checkopen(path)
    R_OK = 0x04
    ret = @ccall faccessat(path.fd::RawFD, ""::Cstring, R_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

function Base.iswritable(path::Path)
    checkopen(path)
    W_OK = 0x02
    ret = @ccall faccessat(path.fd::RawFD, ""::Cstring, W_OK::Cint, AT_EMPTY_PATH::Cint)::Int32
    if ret ∉ (0, -1)
        throw(SystemError("faccessat"))
    end
    ret == 0
end

# From `stat.jl`

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

function statinterpret(statbuf::Memory{UInt8})
    statinfos = reinterpret(StatForm, view(statbuf, 1:sizeof(StatForm)))
    length(statinfos) == 1 || error("Huh, what's this?")
    si = first(statinfos)
    Base.Filesystem.StatStruct(
        reinterpret(RawFD, path.fd),
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
        Int32(err)
    )
end

function Base.stat(path::Path)
    checkopen(path)
    statbuf = fill!(Memory{UInt8}(undef, Int(ccall(:jl_sizeof_stat, Int32, ()))), 0x00)
    err = @ccall fstat(path.fd::Cint, statbuf::Ptr{UInt8})::Int32
    if err < 0
        throw(SystemError("fstat"))
    end
    statinterpret(statbuf)
end

for f in Symbol[
    :ispath,
    :isfifo,
    :ischardev,
    :isdir,
    :isblockdev,
    :isfile,
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
    @eval (Base.$f)(path::Path)  = ($f)(stat(path))
end

Base.islink(::Path) = false
Base.lstat(p::Path) = stat(p)

# API from `file.jl`

"""
    cwd() -> PurePath

Get the current working directory.
"""
function cwd()
    pfd = @ccall openat(AT_FDCWD::Cint, "."::Cstring, O_PATH::Cint)::Int32
    if pfd < 0
        throw(SystemError("openat"))
    end
    p = Path(pfd, O_PATH, true)
    finalizer(close, p)
    p
end

function Base.cd(path::Path)
    checkopen(path)
    err = @ccall fchdir(path.fd::RawFD)::Int32
    if err < 0
        throw(SystemError("fchdir"))
    end
end

function Base.cd(f::Function, path::Path)
    old = cwd()
    try
        cd(path)
        f()
    finally
        cd(old)
    end
end

function Base.chmod(path::Path, mode::Integer)
    checkopen(path)
    err = @ccall fchmod(path.fd::RawFD, mode::Cint)::Int32
    if err < 0
        throw(SystemError("fchmod"))
    end
end

struct DirEntry <: SystemPath
    parent::Path
    name::String
    type::UInt8
end

# AbstractPath interface
root(::DirEntry) = nothing
isabsolute(::DirEntry) = false
Base.parent(de::DirEntry) = de.parent
Base.basename(de::DirEntry) = de.name
Base.length(de::DirEntry) = 1 + length(de.parent)
Base.iterate(de::DirEntry) = (basename(de.name), nothing)
Base.iterate(de::DirEntry, ::Nothing) = nothing
# PlainPath interface
genericpath(de::DirEntry) = genericpath(convert(PurePath, de))

function Base.isless(a::DirEntry, b::DirEntry)
    # a.parent == b.parent || return isless(a.parent, b.parent)
    isless(a.name, b.name)
end

# Conversion

function Base.convert(::Type{PurePath}, de::DirEntry)
    namep = PurePath(GenericPlainPath{PurePath}(de.name, 0, 0))
    joinpath(convert(PurePath, de.parent), namep)
end

function Base.convert(::Type{Path}, de::DirEntry)
    checkopen(de.parent)
    pfd = @ccall openat(de.parent.fd::RawFD, de.name::Cstring, O_PATH::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("openat"))
    p = Path(pfd, O_PATH, true)
    finalizer(close, p)
    p
end

function Base.convert(::Type{DirEntry}, path::PurePath)
    dir, name = parent(path), basename(path)
    DirEntry(convert(Path, dir), name, 0)
end

Base.convert(::Type{DirEntry}, path::Path) =
    convert(DirEntry, convert(PurePath, path))

# Stat-ing

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

for (func, dtval) in ((:isfifo, :fifo),
                      (:ischardev, :chardev),
                      (:isdir, :dir),
                      (:isblockdev, :blockdev),
                      (:isfile, :regular),
                      (:islink, :link),
                      (:issocket, :socket))
    @eval function Base.$func(de::DirEntry)
        if de.type == DENT_TYPES.unknown
            return Base.$func(stat(de))
        end
        de.type == DENT_TYPES.$dtval
    end
end

function Base.stat(de::DirEntry)
    checkopen(de.parent)
    statbuf = fill!(Memory{UInt8}(undef, Int(ccall(:jl_sizeof_stat, Int32, ()))), 0x00)
    err = @ccall fstatat(de.parent.fd::Cint, de.name::Cstring, statbuf::Ptr{UInt8}, 0::Cint)::Int32
    if err < 0
        throw(SystemError("fstatat"))
    end
    statinterpret(statbuf)
end

# Directory iterator

mutable struct DirReader
    const dir::Path
    dirp::Ptr{Cvoid}
    open::Bool
    start::Bool
end

function DirReader(path::Path)
    reader = DirReader(path, C_NULL, false, true)
    finalizer(close, reader)
    reader
end

function Base.close(reader::DirReader)
    if !reader.open || reader.dirp == C_NULL
        return
    end
    reader.open = false
    err = @ccall closedir(reader.dirp::Ptr{Cvoid})::Int32
    if err < 0
        throw(SystemError("closedir"))
    end
end

function Base.iterate(reader::DirReader)
    if !reader.open
        checkopen(reader.dir)
        pathcopy = reopen(reader.dir, Base.Filesystem.JL_O_RDONLY)
        dirp = @ccall fdopendir(pathcopy.fd::RawFD)::Ptr{Cvoid}
        dirp === C_NULL && throw(SystemError("fdopendir"))
        reader.dirp = dirp
        reader.open = true
        reader.start = true
    end
    if reader.start
        reader.start = false
    else
        err = @ccall rewinddir(reader.dirp::Ptr{Cvoid})::Int32
        err < 0 && throw(SystemError("rewinddir"))
    end
    iterate(reader, nothing)
end

function Base.iterate(reader::DirReader, ::Nothing)
    function ispseudopath(ptr::Ptr{UInt8})
        unsafe_load(ptr) == UInt8('.') || return false
        nextchar = unsafe_load(ptr + 1)
        nextchar == 0 && return true
        nextchar == UInt8('.') && unsafe_load(ptr + 2) == 0 && return true
        false
    end
    reader.open || return
    # FIXME: Hardcoded `dentheader`
    dentheader = sizeof(UInt64) + sizeof(UInt64) + sizeof(UInt16) + sizeof(UInt8)
    while true
        dent = @ccall readdir(reader.dirp::Ptr{Cvoid})::Ptr{Cvoid}
        if dent === C_NULL
            close(reader)
            return
        end
        kind = unsafe_load(Ptr{UInt8}(dent) + dentheader - sizeof(UInt8))
        name_ptr = Ptr{UInt8}(dent) + dentheader
        ispseudopath(name_ptr) && continue
        name = unsafe_string(name_ptr)
        return DirEntry(reader.dir, name, kind), nothing
    end
end

Base.IteratorSize(::Type{DirReader}) = Base.SizeUnknown()
Base.eltype(::Type{DirReader}) = DirEntry

children(path::Path) = DirReader(path)

# TODO: Work out how to reconcile the (dir::FD, name::String) components
# of the syscalls/libc functions with the types we have here.
# This could just be done as extra arguments, but that seems a bit messy.
# NOTE: Now that it's been tweaked, `DirEntry` seems like it
# could be a good fit...

function Base.cp(src::Path, dst::PurePath)
    checkopen(src)
    isdir(src) && throw(ArgumentError("Source is a directory"))
    ret = @ccall linkat(src.fd::RawFD, ""::Cstring,
                        AT_FDCWD::Cint, String(dst)::Cstring,
                        AT_EMPTY_PATH::Cint)::Int32
    ret < 0 && throw(SystemError("linkat"))
    dst
end

function Base.rm(path::Path)
    checkopen(path)
    ret = @ccall unlinkat(path.fd::RawFD, ""::Cstring,
                          AT_EMPTY_PATH::Cint)::Int32
    if ret < 0
        throw(SystemError("unlinkat"))
    end
    # REVIEW: Should we close the FD too?
end

# TODO: implement `mv` (via `renameat`), `rmdir`, `symlink` (via `symlinkat`)
# possibly

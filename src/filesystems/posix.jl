# FIXME: These really shouldn't be hard-coded
const AT_EMPTY_PATH = 0x1000
const O_PATH = 0x00200000
const AT_FDCWD = -100

Base.cconvert(::Type{RawFD}, hdl::LocalFileHandle) = hdl.fd

function handle(path::LocalFilepath, flags::Integer = O_PATH)
    pfd = @ccall open(String(path)::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("open"))
    p = LocalFileHandle(pfd, flags, true)
    finalizer(close, p)
    p
end

function handle(dirent::DirEntry, flags::Integer = O_PATH)
    checkopen(dirent.parent)
    pfd = @ccall openat(dirent.parent.fd::RawFD, String(dirent.name)::Cstring, UInt32(flags)::Cint, 0::Cint)::RawFD
    reinterpret(Int32, pfd) < 0 && throw(SystemError("openat"))
    p = LocalFileHandle(pfd, flags, true)
    finalizer(close, p)
    p
end

Base.isopen(h::LocalFileHandle) = h.open

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

function Base.open(hdl::LocalFileHandle; lock = true,
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
    if hdl.flags == flags
        fdio(reinterpret(Int32, hdl.fd), false)
    else
        fdio(reinterpret(Int32, reopen(hdl, flags).fd), true)
    end
end

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

mutable struct DirReader
    const dir::LocalFileHandle
    dirp::Ptr{Cvoid}
    open::Bool
    start::Bool
end

function DirReader(path::LocalFileHandle)
    reader = DirReader(path, C_NULL, false, true)
    finalizer(close, reader)
    reader
end

function children(path::LocalFileHandle)
    if isdir(path)
        DirReader(path)
    end
end

function children(path::AbstractResolvable{LocalFileHandle})
    children(handle(path))
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
        name_ptr = Ptr{UInt8}(dent) + dentheader
        ispseudopath(name_ptr) && continue
        name = unsafe_string(name_ptr)
        kind = unsafe_load(Ptr{UInt8}(dent) + dentheader - sizeof(UInt8))
        return DirEntry(reader.dir, name, kind), nothing
    end
end

Base.IteratorSize(::Type{DirReader}) = Base.SizeUnknown()
Base.eltype(::Type{DirReader}) = DirEntry

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

# System path types

"""
    PlatformPath <: PlainPath

An abstract type representing platform-specific paths, built on top of [`PlainPath`](@ref).
`PlatformPath` defines the base interface for filesystem paths with operating system–specific
semantics. Concrete subtypes like [`PosixPath`](@ref) and [`WindowsPath`](@ref) implement
platform-dependent behavior.

# Interface

Implementations of `PlatformPath` should provide:

- `separator(::Type{T}) -> Char`: Returns the path separator for type `T`.
- `pseudoself(::Type{T}) -> String`: Returns the self-referential pseudosegment for type `T`.
- `pseudoparent(::Type{T}) -> String`: Returns the parent-referential pseudosegment for type `T`.
"""
abstract type PlatformPath{L} <: PlainPath{L} end

pseudoself(::Type{<:PlatformPath}) = "."
pseudoparent(::Type{<:PlatformPath}) = ".."

struct PosixPath <: PlatformPath{Unhandleable}
    path::GenericPlainPath{PosixPath}
end

separator(::Type{PosixPath}) = '/'
genericpath(path::PosixPath) = path.path

struct WindowsPath <: PlatformPath{Unhandleable}
    path::GenericPlainPath{WindowsPath}
end

separator(::Type{WindowsPath}) = '\\'
genericpath(path::WindowsPath) = path.path

function Base.splitdrive(path::WindowsPath)
    drive, rest = splitdrive(String(path))
    lastsep = something(findlast(==(separatorbyte(WindowsPath)), codeunits(rest)), 0)
    WindowsPath(drive, ncodeunits(drive), 0, 0),
    WindowsPath(rest, 0, lastsep , 0)
end

# Validation

"""
    validate_path(::Type{E<:PlatformPath}, ::Type{P<:PlatformPath}, segment::AbstractString, multipart::Bool = true)

Validate a path or path segment (depending on `multipart`) for the system path type `P`.

Returns `nothing` when `segment` is valid, or an `InvalidSegment{E}` describing the issue.
"""
function validate_path end

"""
    validate_path(::Type{P<:PlatformPath}, segment::AbstractString, multipart::Bool = true)

Validate a path or path segment (depending on `multipart`) for the system path type `P`.

Returns `segment` when it is valid, or throws an `InvalidSegment{P}` describing the issue.
"""
function validate_path(::Type{T}, segment::AbstractString, multipart::Bool = true) where {T <: PlatformPath}
    err = validate_path(InvalidSegment{T}, T, segment, multipart)
    if !isnothing(err)
        throw(err)
    else
        segment
    end
end

# Posix

Base.@assume_effects :foldable function validate_path(::Type{InvalidSegment{T}}, ::Type{PosixPath}, segment::AbstractString, multipart::Bool = true) where {T <: PlatformPath}
    if isempty(segment)
        InvalidSegment{T}(segment, :empty)
    elseif !multipart && (segment == "." || segment == "..")
        InvalidSegment{T}(segment, :reserved)
    elseif 0x00 in codeunits(segment)
        InvalidSegment{T}(segment, :char, '\0')
    elseif !multipart && UInt8('/') in codeunits(segment)
        InvalidSegment{T}(segment, :separator, '/')
    end
end

Base.@assume_effects :foldable function PosixPath(segment::AbstractString)
    if segment == string(separator(PosixPath))
        PosixPath(GenericPlainPath{PosixPath}(segment, 1, 0))
    else
        validate_path(PosixPath, segment)
        PosixPath(GenericPlainPath{PosixPath}(segment, 0, 0))
    end
end

function PosixPath(components::AbstractVector{<:AbstractString})
    isempty(components) && throw(EmptyPath{PosixPath}())
    rooted = first(components) == "/"
    foreach(Iterators.dropwhile(c -> c == ".." && !rooted, Iterators.drop(components, rooted))) do component
        validate_path(PosixPath, component, false)
    end
    PosixPath(join(components, '/'))
end

Base.@assume_effects :foldable function PosixPath(path::String)
    (; data, rootsep, lastsep) = parsepath(path, Int(startswith(path, '/')); separators = ('/',),
                                                validate = segment -> validate_path(PosixPath, segment, false))
    PosixPath(GenericPlainPath{PosixPath}(data, rootsep, lastsep))
end

Base.parse(::Type{PosixPath}, path::AbstractString) = PosixPath(String(path))

# Windows

Base.@assume_effects :foldable function validate_path(::Type{InvalidSegment{T}}, ::Type{WindowsPath}, segment::AbstractString, multipart::Bool = false) where {T <: PlatformPath}
    posix_err = validate_path(InvalidSegment{WindowsPath}, PosixPath, segment, multipart)
    isnothing(posix_err) || throw(posix_err) # Since Windows rules are a superset of Posix rules
    if segment in ("CON", "PRN", "AUX", "NUL",
                   "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                   "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")
        throw(InvalidSegment{T}(segment, :reserved))
    elseif endswith(segment, '.') || endswith(segment, ' ')
        throw(InvalidSegment{T}(segment, :suffix, last(segment)))
    end
    for char in ('<', '>', ':', '"', '|', '?', '*')
        if char in segment
            throw(InvalidSegment{T}(segment, :char, char))
        end
    end
    if '\\' in segment && !multipart
        throw(InvalidSegment{T}(segment, :separator, '\\'))
    end
end

# Grabbed from `base/path.jl`
const WINDOWS_DRIVE_RE = r"^([\\/][\\/]\?[\\/]UNC[\\/][^\\/]+[\\/][^\\/]+|[\\/][\\/]\?[\\/][^\\/]+:|[\\/][\\/][^\\/]+[\\/][^\\/]+|[^\\/]+:|)(.*)$"sa

Base.@assume_effects :foldable function WindowsPath(segment::AbstractString)
    m = match(WINDOWS_DRIVE_RE, segment)::AbstractMatch
    if ncodeunits(something(m.captures[1])) == ncodeunits(segment)
        WindowsPath(GenericPlainPath{WindowsPath}(segment, ncodeunits(segment) + 1, 0))
    else
        validate_path(WindowsPath, segment)
        WindowsPath(GenericPlainPath{WindowsPath}(segment, 0, 0))
    end
end

function WindowsPath(components::AbstractVector{<:AbstractString})
    isempty(components) && throw(EmptyPath{WindowsPath}())
    rooted = ncodeunits(windowsdrive(first(components))) == ncodeunits(first(components))
    foreach(Iterators.dropwhile(c -> c == ".." && !rooted, Iterators.drop(components, rooted))) do component
        validate_path(WindowsPath, component, false)
    end
    WindowsPath(join(components, '\\'))
end

Base.@assume_effects :foldable function WindowsPath(path::String)
    (; data, rootsep, lastsep) = parsepath(path, ncodeunits(windowsdrive(path)); separators = ('\\', '/'),
                                                validate = segment -> validate_path(WindowsPath, segment, false))
    WindowsPath(GenericPlainPath{WindowsPath}(data, rootsep, lastsep))
end

windowsdrive(path::AbstractString) = something(match(WINDOWS_DRIVE_RE, path).captures[1])

Base.parse(::Type{WindowsPath}, path::AbstractString) = WindowsPath(String(path))

"""
    parsepath(path::String, rootlen::Int; separators, validate, pseudoself = ".", pseudoparent = "..")
        -> (; data::String, rootsep::Int, lastsep::Int)

Parse `path` into the fields of a normalised `GenericPlainPath`, with its first
`rootlen` bytes taken as its root.

Any of `separators` is accepted in `path`; the result uses the first only,
contains no empty or `pseudoself` segments nor trailing separator, and has
`pseudoparent` segments collapsed against the segments before them (or the
root, which is a fixed point). Each remaining segment is passed to `validate`.
An empty result becomes `pseudoself`.

When `path` is already normalised, it is used as `data` without copying.
"""
function parsepath(path::String, rootlen::Int; separators::Tuple{Vararg{Char}}, validate::F,
                   pseudoself::String = ".", pseudoparent::String = "..") where {F}
    sepbytes = map(UInt8, separators)
    sep = first(sepbytes)
    rootsep = if iszero(rootlen) 0 else rootlen + (codeunit(path, rootlen) != sep) end
    function materialise(n::Int)
        buf = Base._string_n(ncodeunits(path))
        GC.@preserve buf for i in 1:n
            byte = codeunit(path, i)
            unsafe_store!(pointer(buf, i), if byte in sepbytes sep else byte end)
        end
        buf
    end
    inplace = !any(b -> b in sepbytes && b != sep, codeunits(SubString(path, 1, rootlen)))
    out = if inplace path else materialise(rootlen) end
    n, parentsend, i = rootlen, 0, rootlen + 1
    while i <= ncodeunits(path)
        j = something(findnext(in(sepbytes), codeunits(path), i), ncodeunits(path) + 1)
        segment, segstart = SubString(path, i - 1, j - i, Val(:noshift)), i
        i = j + 1
        if isempty(segment) || segment == pseudoself
            continue
        elseif segment == pseudoparent
            if n > max(rootlen, parentsend)
                n = max(something(findprev(==(sep), codeunits(out), n), 1) - 1, rootlen)
                continue
            end
            iszero(rootlen) || continue
        else
            validate(segment)
        end
        needsep = n > 0 && codeunit(out, n) != sep
        start = n + needsep + 1
        if inplace && segstart == start && (!needsep || codeunit(path, n + 1) == sep)
            n = start + ncodeunits(segment) - 1
        else
            if inplace
                out, inplace = materialise(n), false
            end
            needsep && GC.@preserve out unsafe_store!(pointer(out, n + 1), sep)
            n = start + Base.__unsafe_string!(out, segment, start) - 1
        end
        segment == pseudoparent && (parentsend = n)
    end
    data = if iszero(n) pseudoself elseif n == ncodeunits(out) out else GC.@preserve out unsafe_string(pointer(out), n) end
    lastsep = something(findlast(==(sep), codeunits(data)), 0)
    (; data, rootsep, lastsep = if lastsep > rootsep lastsep else 0 end)
end

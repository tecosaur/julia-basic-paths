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

struct PosixPath <: PlatformPath{Nothing}
    path::GenericPlainPath{PosixPath}
end

separator(::Type{PosixPath}) = '/'
genericpath(path::PosixPath) = path.path

struct WindowsPath <: PlatformPath{Nothing}
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
    if segment == ""
        InvalidSegment{T}(segment, :empty)
    elseif segment == "." && !multipart
        InvalidSegment{T}(segment, :reserved)
    elseif segment == ".." && !multipart
        InvalidSegment{T}(segment, :reserved)
    elseif '\0' in segment
        InvalidSegment{T}(segment, :char, '\0')
    elseif '/' in segment && !multipart
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
    pathbuf, rootsep, lastsep = IOBuffer(), 0, 0
    i = firstindex(components)
    if first(components) == string(separator(PosixPath))
        print(pathbuf, separator(PosixPath))
        rootsep = 1
        i = nextind(components, i)
    else
        while i <= lastindex(components) && components[i] == pseudoparent(PosixPath)
            lastsep = position(pathbuf)
            print(pathbuf, pseudoparent(PosixPath), separator(PosixPath))
            i = nextind(components, i)
        end
    end
    while i <= lastindex(components)
        validate_path(PosixPath, components[i])
        lastsep = position(pathbuf)
        print(pathbuf, components[i], separator(PosixPath))
        i = nextind(components, i)
    end
    truncate(pathbuf, position(pathbuf) - 1)
    PosixPath(GenericPlainPath{PosixPath}(String(take!(pathbuf)), rootsep, lastsep))
end

Base.@assume_effects :foldable function PosixPath(path::String)
    npath = normpath(path)
    if npath != "/"
        npath = String(rstrip(normpath(path), separator(PosixPath)))
        for segment in eachsplit(npath, separator(PosixPath), keepempty=false)
            segment ∈ (pseudoself(PosixPath), pseudoparent(PosixPath)) && continue
            validate_path(PosixPath, segment)
        end
    end
    rootsep = first(npath) == separator(PosixPath)
    lastsep = something(findlast(==(separatorbyte(PosixPath)), codeunits(npath)), 0)
    PosixPath(GenericPlainPath{PosixPath}(npath, rootsep, ifelse(lastsep > 1, lastsep, 0)))
end

function Base.parse(::Type{PosixPath}, path::String)
    validate_path(PosixPath, path, true)
    PosixPath(path)
end

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
    pathbuf, rootsep, lastsep = IOBuffer(), 0, 0
    i = firstindex(components)
    drivematch = match(WINDOWS_DRIVE_RE, first(components))
    if ncodeunits(something(drivematch.captures[1])) == ncodeunits(first(components))
        print(pathbuf, first(components))
        rootsep = ncodeunits(first(components)) + 1
        i = nextind(components, i)
    else
        while i <= lastindex(components) && components[i] == pseudoparent(WindowsPath)
            lastsep = position(pathbuf)
            print(pathbuf, pseudoparent(WindowsPath), separator(WindowsPath))
            i = nextind(components, i)
        end
    end
    while i <= lastindex(components)
        validate_path(WindowsPath, components[i])
        lastsep = position(pathbuf)
        print(pathbuf, components[i], separator(WindowsPath))
        i = nextind(components, i)
    end
    truncate(pathbuf, position(pathbuf) - 1)
    WindowsPath(GenericPlainPath{WindowsPath}(String(take!(pathbuf)), rootsep, lastsep))
end

Base.@assume_effects :foldable function WindowsPath(path::String)
    function splitdrive_w(p::AbstractString)
        m = match(WINDOWS_DRIVE_RE, p)::AbstractMatch
        String(something(m.captures[1])), String(something(m.captures[2]))
    end
    npath = replace(rstrip(normpath(path), ('/', '\\')), '/' => separator(WindowsPath))
    drive, rest = splitdrive_w(npath)
    for segment in eachsplit(rest, separator(WindowsPath), keepempty=false)
        validate_path(WindowsPath, segment)
    end
    rootsep = if isempty(drive) 0 else ncodeunits(drive) + 1 end
    lastsep = something(findlast(==(separatorbyte(WindowsPath)), codeunits(npath)), 0)
    WindowsPath(GenericPlainPath{WindowsPath}(npath, rootsep, lastsep))
end

function Base.parse(::Type{WindowsPath}, path::String)
    validate_path(WindowsPath, path, true)
    WindowsPath(path)
end

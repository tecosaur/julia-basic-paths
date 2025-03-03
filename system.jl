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
abstract type PlatformPath <: PlainPath end

pseudoself(::Type{<:PlatformPath}) = "."
pseudoparent(::Type{<:PlatformPath}) = ".."

"""
    SystemPath <: PlatformPath

An abstract type for paths that are native to the current operating system.
"""
abstract type SystemPath <: PlatformPath end

@static if !Sys.iswindows()
    struct PosixPath <: SystemPath
        path::GenericPlainPath{PosixPath}
    end

    struct WindowsPath <: PlatformPath
        path::GenericPlainPath{WindowsPath}
    end

    const PurePath = PosixPath
else
    struct PosixPath <: PlatformPath
        path::GenericPlainPath{PosixPath}
    end

    struct WindowsPath <: SystemPath
        path::GenericPlainPath{WindowsPath}
    end

    const PurePath = WindowsPath
end

separator(::Type{PosixPath}) = '/'
separator(::Type{WindowsPath}) = '\\'

genericpath(path::PosixPath) = path.path
genericpath(path::WindowsPath) = path.path

function Base.show(io::IO, path::PurePath)
    print(io, "p\"")
    for (i, segment) in enumerate(path)
        i > (1 + isone(path.path.rootsep)) && print(io, '/')
        print(io, segment)
    end
    print(io, '"')
end

function children(path::PurePath)
    if isdir(path)
        readdir(path, join=true)
    end
end

# System path buffer types

struct PosixPathBuf <: PlatformPath
    path::GenericPlainPathBuf{PosixPath}
end

struct WindowsPathBuf <: PlatformPath
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

# General path methods (could be defined for each path subtype)

Base.:(==)(a::PurePath, b::PurePath) = a.path.data == b.path.data

function Base.hash(path::PurePath, h::UInt)
    h = hash(PurePath, h)
    hash(path.data.path, h)
end

function Base.startswith(a::PurePath, b::PurePath)
    if ncodeunits(a.path.data) < ncodeunits(b.path.data)
        false
    elseif ncodeunits(a.path.data) == ncodeunits(b.path.data)
        a == b
    else
        startswith(a.path.data, b.path.data) &&
            codeunit(a.path.data, ncodeunits(b.path.data) + 1) == separatorbyte(PurePath)
    end
end

Base.:(<)(a::PurePath, b::PurePath) = startswith(b, a)
Base.:(>)(a::PurePath, b::PurePath) = startswith(a, b)

function Base.endswith(a::PurePath, b::PurePath)
    if ncodeunits(a.path.data) < ncodeunits(b.path.data)
        false
    elseif ncodeunits(a.path.data) == ncodeunits(b.path.data)
        a == b
    else
        endswith(a.path.data, b.path.data) &&
            codeunit(a.path.data, ncodeunits(a.path.data) - ncodeunits(b.path.data)) == separatorbyte(PurePath)
    end
end

# ---------------------
# PurePath construction
# ---------------------

"""
    validate_path(::Type{E<:PlatformPath}, ::Type{P<:PlatformPath}, segment::AbstractString, allowsep::Bool = true)

Validate a path or path segment (depending on `allowsep`) for the system path type `P`.

Returns `nothing` when `segment` is valid, or an `InvalidSegment{E}` describing the issue.
"""
function validate_path end

"""
    validate_path(::Type{P<:PlatformPath}, segment::AbstractString, allowsep::Bool = true)

Validate a path or path segment (depending on `allowsep`) for the system path type `P`.

Returns `segment` when it is valid, or throws an `InvalidSegment{P}` describing the issue.
"""
function validate_path(::Type{T}, segment::AbstractString, allowsep::Bool = true) where {T <: PlatformPath}
    err = validate_path(InvalidSegment{T}, T, segment, allowsep)
    if !isnothing(err)
        throw(err)
    else
        segment
    end
end

# Posix

Base.@assume_effects :foldable function validate_path(::Type{InvalidSegment{T}}, ::Type{PosixPath}, segment::AbstractString, allowsep::Bool = true) where {T <: PlatformPath}
    if segment == ""
        InvalidSegment{T}(segment, :empty)
    elseif segment == "."
        InvalidSegment{T}(segment, :reserved)
    elseif segment == ".."
        InvalidSegment{T}(segment, :reserved)
    elseif '\0' in segment
        InvalidSegment{T}(segment, :char, '\0')
    elseif '/' in segment && !allowsep
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
    # validate_path(PosixPath, path, true)
    PosixPath(path)
end

# Windows

Base.@assume_effects :foldable function validate_path(::Type{InvalidSegment{T}}, ::Type{WindowsPath}, segment::AbstractString, allowsep::Bool = false) where {T <: PlatformPath}
    posix_err = validate_path(InvalidSegment{WindowsPath}, PosixPath, segment, allowsep)
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
    if '\\' in segment && !allowsep
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

# The path macro, and helper functions

"""
    @p_str -> PurePath

Construct a [`PurePath`](@ref) from a cross-platform literal representation.

The path should be written in posix style, with `/` as the separator.

Paths starting with `~` will be expanded to the user's home directory.

During construction, the part will be normalised such that:
- Parent pseudopath segments (`..`) only appear at the start
  of relative paths.
- Redundant self-referential pseudopath segments (`.`) are removed.
- The path does not end with a separator.

Similarly to strings in Julia, `\$` can be used to interpolate *path components*.
A path component can be an `AbstractString` that forms a single path segment, an
`AbstractVector{<:AbstractString}` of path segments, or another `PurePath`. Literal
`\$` characters can be escaped with `\\\$`.

# Examples

```julia
$(if Sys.iswindows()
"julia> docs = p\"~/Documents\"
p\"C:/Users/Me/Documents\"

julia> p\"\$docs/../../Jane/Public\"
p\"C:/Users/Jane/Public\"

julia> p\"tiny//in/my/head/../../../dancer\"
p\"tiny/dancer\"
"
else
"julia> docs = p\"~/Documents\"
p\"/home/me/Documents\"

julia> p\"\$docs/../../jane/Public\"
p\"/home/jane/Public\"

julia> p\"tiny//in/my/head/../../../dancer\"
p\"tiny/dancer\"
"
end)
```
"""
macro p_str(raw_path::String, flags...)
    pathkind = if isempty(flags)
        PurePath
    elseif first(flags) == "posix"
        PosixPath
    elseif first(flags) == "win"
        WindowsPath
    else
        throw(ArgumentError("Invalid path kind: $(first(flags)), should be 'posix' or 'win'"))
    end
    components = Any[]
    path = unescape_string(Base.escape_raw_string(raw_path), '$')
    withindepot = false
    lastidx = idx = 1
    if startswith(path, "~/") || path == "~"
        push!(components, :(parse(PurePath, homedir())))
        lastidx = idx = 1 + ncodeunits("~/")
    elseif startswith(path, "~")
        tuser = first(eachsplit(path, '~'))
        throw(ArgumentError("~user tilde expansion not implemented. This path can expressed verbatim as \$'~'$(tuser[2:end])."))
    elseif startswith(path, "@/")
        dir = pkgdir(__module__)
        isnothing(dir) && throw(ArgumentError("Directory of the current module could not be determined."))
        deprel, withindepot = depot_remove(dir)
        push!(components, parse(PurePath, deprel))
        lastidx = idx = 1 + ncodeunits("@/")
    elseif startswith(path, "@./")
        dir = Base.var"@__DIR__"(__source__, __module__)
        isnothing(dir) && throw(ArgumentError("Directory of the current file could not be determined."))
        deprel, withindepot = depot_remove(dir)
        push!(components, parse(PurePath, deprel))
        lastidx = idx = 1 + ncodeunits("@./")
    elseif startswith(path, "@")
        atname = first(eachsplit(path, '@'))
        throw(ArgumentError("$atname shorthand not supported. This path component can be expressed verbatim as \$'@'$(atname[2:end])."))
    end
    escaped = false
    function makecomponent(prefix::String, val::Union{Expr, Symbol, String, Char}, suffix::String, delimorfinal::Bool)
        var = gensym("path#segment")
        patherr = if !delimorfinal
            :(throw(ArgumentError($"PurePath `$val` should be separated from subsequent components with a / separator")))
        elseif !isempty(prefix) && !isempty(suffix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string prefix ($(sprint(show, prefix))) or suffix ($(sprint(show, suffix)))")))
        elseif !isempty(prefix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string prefix ($(sprint(show, prefix)))")))
        elseif !isempty(suffix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string suffix ($(sprint(show, suffix)))")))
        end
        vecerr = if !delimorfinal
            :(throw(ArgumentError($"PurePath component vector `$val` should be separated from subsequent components with a / separator")))
        end
        strparts = filter(!isnothing,
                          (if !isempty(prefix) prefix end,
                           :(String(string($var))),
                           if !isempty(suffix) suffix end))
        cstr = if length(strparts) == 1
            first(strparts)
        else
            Expr(:call, :joinpath, filter(!isnothing, strparts)...)
        end
        quote
            let $var = $(esc(val))
                if $var isa AbstractString || $var isa AbstractChar
                    $pathkind(validate_path($pathkind, $cstr, false))
                elseif $var isa AbstractVector{<:AbstractString}
                    $vecerr
                    $pathkind([validate_path($pathkind, component, false) for component in $var])
                elseif $var isa $pathkind
                    $patherr
                    $var
                else
                    throw(ArgumentError("Invalid path component type: $var of type $(typeof($var)), should be an AbstractString or PurePath"))
                end
            end
        end
    end
    makecomponent(::String, val, ::String, ::Bool) =
        throw(ArgumentError("Invalid path component type: $val of type $(typeof(val))"))
    while idx < ncodeunits(path)
        if escaped
            escaped = false
            idx += 1
        elseif path[idx] == '\\'
            escaped = true
            idx += 1
        elseif path[idx] == '$'
            prefix, suffix = "", ""
            if lastidx < idx
                pidx = if path[prevind(path, idx)] != '/'
                    segstart = something(findprev(==('/'), path, idx), 0)
                    prefix = path[segstart+1:prevind(path, idx)]
                    segstart
                else idx end
                if lastidx < pidx
                    text = path[lastidx:prevind(path, pidx)]
                    push!(components, parse(pathkind, text))
                end
            end
            idx += ncodeunits('$')
            expr, idx = Meta.parseatom(path, idx; filename=string(__source__.file))
            if idx <= ncodeunits(path) && path[idx] != '/'
                sesc = false
                sidx = idx
                while sidx < ncodeunits(path)
                    if path[sidx] == '/'
                        break
                    elseif sesc
                        sesc = false
                    elseif path[sidx] == '\\'
                        sesc = true
                    elseif path[sidx] == '$'
                        break
                    end
                    sidx = nextind(path, sidx)
                end
                suffix = path[idx:prevind(path, sidx)]
                idx = sidx
            end
            push!(components, makecomponent(prefix, expr, suffix, idx > ncodeunits(path) || path[idx] == '/'))
            if idx < ncodeunits(path) && path[idx] == separator(pathkind)
                idx += 1
            end
            lastidx = idx
        else
            idx = nextind(path, idx)
        end
    end
    if lastidx > 1 && lastidx == lastindex(path) && path[lastidx] == '/'
    elseif lastidx <= lastindex(path)
        push!(components, parse(pathkind, path[lastidx:end]))
    end
    pathexpr = if length(components) == 1
        components[1]
    else
        Expr(:call, :joinpath, components...)
    end
    if withindepot
        :(depot_locate($pathexpr))
    else
        pathexpr
    end
end

function depot_remove(path::String)
    for depot in DEPOT_PATH
        if startswith(path, depot)
            nodep = chopprefix(chopprefix(path, depot), string(separator(PurePath)))
            return String(nodep), true
        end
    end
    path, false
end

function depot_locate(subpath::PurePath)
    for depot in DEPOT_PATH
        dpath = joinpath(parse(PurePath, depot), subpath)
        ispath(dpath) && return dpath
    end
    throw(error("Failed to relocate [depot]/$(String(subpath)) to any of DEPOT_PATH."))
end

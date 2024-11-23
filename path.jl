# Implementation of the `GenericPlainPath` type and its methods.

struct GenericPlainPath{P <: PlainPath} <: PlainPath
    data::String
    rootsep::UInt16
    lastsep::UInt16
    # What are these for? I like that it makes use of the 4 byte padding on
    # 64-bit platforms.
    # How likely is it that Julia will run on 32-bit platforms in the future?
    flags::UInt32
end

function root(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.rootsep)
        nothing
    elseif ncodeunits(path.data) == path.rootsep
        path
    else
        # For Windows, the root is usually prefixed by a drive, e.g. C:\\a\\b\\c.
        # so this will not work.
        GenericPlainPath{P}(path.data[1:path.rootsep], path.rootsep, 0, 0)
    end
end

# Again, Windows require a drive prefix to be absolute
isabsolute(path::GenericPlainPath) = !iszero(path.rootsep)

# Here, too, it's impossible to compute the parent of a path whose last
# element is ..
function parent(path::GenericPlainPath{P}) where {P <: PlainPath}
    iszero(path.lastsep) && return nothing
    parentdata = path.data[1:max(1, path.lastsep-1)]
    # I think this is buggy? You search for a byte in a String. You need
    # to search in the codeunits.
    priorsep = something(findlast(isequal(separatorbyte(P)), parentdata),
                         zero(UInt16))
    GenericPlainPath{P}(parentdata, path.rootsep, priorsep, 0)
end

function basename(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.lastsep)
        SubString(path.data)
    else
        # If the last element of the path is `..`, then this cannot be known.
        # E.g. suppose `foo` is a symlinked directory.
        # Then `/qux/foo/..` has an unknown basename. I should return `nothing` in this case.
        SubString(path.data, Int(path.lastsep), ncodeunits(path.data) - path.lastsep, Val(:noshift))
    end
end

# This is not true in the presence of ..'s, necessarily (see my other comments)
# on how `..` is unresolvable in the presence of symlinks.
# Also I think it's off by one.
Base.length(path::GenericPlainPath) =
    count(==(separatorbyte(typeof(path))), path.data) + iszero(path.rootsep)

function Base.iterate(path::GenericPlainPath{P}) where {P}
    # Maybe this should be an assert, then
    isempty(path.data) && return nothing # Should never happen
    iterate(path, Int(isone(path.rootsep)))
end

function Base.iterate(path::GenericPlainPath{P}, start::Int) where {P}
    start >= ncodeunits(path.data) && return nothing
    nextsep = findnext(==(separatorbyte(P)), codeunits(path.data), start + 1)
    stop, nextstart = if isnothing(nextsep)
        ncodeunits(path.data) - start, ncodeunits(path.data)
    else
        # This is not a valid index for some non-ASCII paths.
        nextsep - start - 1, nextsep
    end
    SubString(path.data, start, stop, Val(:noshift)), nextstart
end

function Base.:(*)(a::GenericPlainPath{P}, b::GenericPlainPath{P}) where {P}
    isabsolute(b) && return b
    cdata = a.data * separator(P) * b.data
    GenericPlainPath{P}(cdata, a.rootsep, ncodeunits(a.data) + b.lastsep + 1, 0)
end

separator(::Type{GenericPlainPath{P}}) where {P <: PlainPath} = separator(P)

# This is normally implemented as `print`.
# Maybe you wanted `String(path)`?
Base.string(path::GenericPlainPath) = path.data

# Display

function Base.show(io::IO, path::PlainPath)
    show(io, typeof(path))
    print(io, '(')
    show(io, string(path))
    print(io, ')')
end

# Optional API

"""
    genericpath(path::PlainPath) -> GenericPlainPath | GenexicPlainPathBuf

Return the `GenericPlainPath` or `GenericPlainPathBuf` backing `path`.

Optional component of the `PlainPath` interface.
"""
function genericpath end

# Private API
root(path::PlainPath) = generic_rewrap(root, path)
parent(path::PlainPath) = generic_rewrap(parent, path)
basename(path::PlainPath) = basename(genericpath(path))
isabsolute(path::PlainPath) = isabsolute(genericpath(path))
Base.length(path::PlainPath) = length(genericpath(path))
Base.iterate(path::PlainPath) = iterate(genericpath(path))
Base.iterate(path::PlainPath, i::Int) = iterate(genericpath(path), i)
Base.string(path::PlainPath) = string(genericpath(path))

# See the end of `pathbuf.jl` for the implementation of
# `generic_rewrap` and `*(::PlainPath, ::PlainPath)`.

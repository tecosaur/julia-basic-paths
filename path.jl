# Implementation of the `GenericPlainPath` type and its methods.

struct GenericPlainPath{P <: PlainPath} <: PlainPath
    data::String
    rootsep::UInt16
    lastsep::UInt16
    flags::UInt32
end

function root(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.rootsep)
        nothing
    elseif ncodeunits(path.data) == path.rootsep
        path
    else
        GenericPlainPath{P}(path.data[1:path.rootsep], path.rootsep, 0, 0)
    end
end

isabsolute(path::GenericPlainPath) = !iszero(path.rootsep)

function parent(path::GenericPlainPath{P}) where {P <: PlainPath}
    iszero(path.lastsep) && return nothing
    parentdata = path.data[1:max(1, path.lastsep-1)]
    priorsep = something(findlast(isequal(separatorbyte(P)), parentdata),
                         zero(UInt16))
    GenericPlainPath{P}(parentdata, path.rootsep, priorsep, 0)
end

function basename(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.lastsep)
        SubString(path.data)
    else
        SubString(path.data, Int(path.lastsep), ncodeunits(path.data) - path.lastsep, Val(:noshift))
    end
end

Base.length(path::GenericPlainPath) =
    count(==(separatorbyte(typeof(path))), path.data) + iszero(path.rootsep)

function Base.iterate(path::GenericPlainPath{P}) where {P}
    isempty(path.data) && return nothing # Should never happen
    iterate(path, Int(isone(path.rootsep)))
end

function Base.iterate(path::GenericPlainPath{P}, start::Int) where {P}
    start >= ncodeunits(path.data) && return nothing
    nextsep = findnext(==(separatorbyte(P)), codeunits(path.data), start + 1)
    stop, nextstart = if isnothing(nextsep)
        ncodeunits(path.data) - start, ncodeunits(path.data)
    else
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

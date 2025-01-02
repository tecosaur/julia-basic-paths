# Implementation of the `GenericPlainPath` type and its methods.

struct GenericPlainPath{P <: PlainPath} <: PlainPath
    data::String
    rootsep::UInt16
    lastsep::UInt16
    # NOTE: taking padding into account, we have a free extra
    # 4B of memory here we could use for /something/ else.
end

function root(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.rootsep)
        nothing
    elseif ncodeunits(path.data) == path.rootsep
        path
    else
        GenericPlainPath{P}(path.data[1:path.rootsep+isone(path.rootsep)-1], path.rootsep, 0)
    end
end

isabsolute(path::GenericPlainPath) = !iszero(path.rootsep)

function Base.parent(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.lastsep)
        return if !iszero(path.rootsep) && ncodeunits(path.data) > path.rootsep
            GenericPlainPath{P}(path.data[1:path.rootsep+isone(path.rootsep)-1], path.rootsep, 0)
        end
    end
    iszero(path.lastsep) && path.rootsep ∈ (0, 1) && return nothing
    parentdata = path.data[1:max(1, path.lastsep-1)]
    priorsep = something(findlast(isequal(separatorbyte(P)), parentdata),
                         zero(UInt16))
    GenericPlainPath{P}(parentdata, path.rootsep, priorsep)
end

function Base.basename(path::GenericPlainPath{P}) where {P <: PlainPath}
    bname = SubString(path.data, Int(path.lastsep), ncodeunits(path.data) - path.lastsep, Val(:noshift))
    if bname != pseudoparent(P)
        bname
    end
end

Base.length(path::GenericPlainPath) =
    count(==(separatorbyte(typeof(path))), codeunits(path.data)) + (path.rootsep ∈ (0, 1))

function Base.iterate(path::GenericPlainPath{P}) where {P}
    isempty(path.data) && return nothing # Should never happen
    iterate(path, 0)
end

function Base.iterate(path::GenericPlainPath{P}, start::Int) where {P}
    start >= ncodeunits(path.data) && return nothing
    nextsep = findnext(==(separatorbyte(P)), codeunits(path.data), start + 1)
    stop, nextstart = if isnothing(nextsep)
        ncodeunits(path.data) - start, ncodeunits(path.data)
    else
        nextsep - start - !(isone(nextsep) && isone(path.rootsep)), nextsep
    end
    SubString(path.data, start, stop, Val(:noshift)), nextstart
end

struct AbsolutePathError{P <: GenericPlainPath} <: Exception
    a::P
    b::P
end

function Base.showerror(io::IO, ex::AbsolutePathError)
    print(io, "AbsolutePathError: Cannot join one path ($(ex.a.data)) with an absolute path ($(ex.b.data))")
end

Base.@assume_effects :foldable function Base.:(*)(a::GenericPlainPath{P}, b::GenericPlainPath{P}) where {P}
    isabsolute(b) && throw(AbsolutePathError(a, b))
    simplejoin = isnothing(pseudoparent(P)) ||
        (iszero(b.lastsep) && b.data != pseudoparent(P)) ||
        (ncodeunits(b.data) > ncodeunits(pseudoparent(P)) &&
         !(view(codeunits(b.data), 1:ncodeunits(pseudoparent(P))) == codeunits(pseudoparent(P)) &&
           codeunit(b.data, ncodeunits(pseudoparent(P)) + 1) == separatorbyte(P)))
    if simplejoin
        cdata = a.data * separator(P) * b.data
        lastsep = ncodeunits(a.data) + b.lastsep + 1
        GenericPlainPath{P}(cdata, a.rootsep, lastsep)
    else # Worry about leading `pseudoparent` components in `b`
        abytes, bbytes = codeunits(a.data), codeunits(b.data)
        aend = ncodeunits(a.data)
        bstart = 1
        bsegend = something(findnext(==(separatorbyte(P)), bbytes, bstart),
                            length(bbytes) + 1) - 1
        while true
            if view(bbytes, bstart:bsegend) == codeunits(pseudoparent(P))
                if aend > a.rootsep
                    aprev = something(findprev(==(separatorbyte(P)), abytes, aend), 1)
                    aend = aprev - 1
                elseif iszero(a.rootsep)
                    aend -= 1
                else
                    throw(InsufficientParents(a, count(==(pseudoparent(P)), collect(b))))
                end
                bstart = bsegend + 2
                bsegend = something(findnext(==(separatorbyte(P)), bbytes, min(length(bbytes), bstart)),
                                    length(bbytes) + 1) - 1
            elseif view(bbytes, bstart:bsegend) == codeunits(pseudoself(P))
                bstart = bsegend + 2
                bsegend = something(findnext(==(separatorbyte(P)), bbytes, min(length(bbytes), bstart)),
                                    length(bbytes) + 1) - 1
            else
                break
            end
        end
        cdata = if aend > 0
            asub = SubString(a.data, 0, aend, Val(:noshift))
            if bstart < length(bbytes)
                asub * separator(P) * SubString(b.data, bstart - 1, length(bbytes) - bstart + 1, Val(:noshift))
            else
                asub
            end
        elseif aend == 0
            String(bbytes[bstart:length(bbytes)])
        else
            cbytes = UInt8[]
            sizehint!(cbytes, 3 * aend + length(bbytes) - bstart + 1)
            for _ in 1:-aend
                append!(cbytes, codeunits(pseudoparent(P)))
                push!(cbytes, separatorbyte(P))
            end
            append!(cbytes, view(bbytes, bstart:length(bbytes)))
            String(cbytes)
        end
        lastsep = b.lastsep + ncodeunits(cdata) - ncodeunits(b.data)
        GenericPlainPath{P}(cdata, a.rootsep, lastsep)
    end
end

separator(::Type{GenericPlainPath{P}}) where {P <: PlainPath} = separator(P)

Base.String(path::GenericPlainPath) = path.data

# Display

function Base.show(io::IO, path::PlainPath)
    show(io, typeof(path))
    print(io, '(')
    show(io, String(path))
    print(io, ')')
end

# Optional API

"""
    genericpath(path::PlainPath) -> GenericPlainPath | GenexicPlainPathBuf

Return the `GenericPlainPath` or `GenericPlainPathBuf` backing `path`.

Optional component of the `PlainPath` interface.
"""
function genericpath end

# Generic implementations
root(path::PlainPath) = generic_rewrap(root, path)
Base.parent(path::PlainPath) = generic_rewrap(parent, path)
Base.basename(path::PlainPath) = basename(genericpath(path))
isabsolute(path::PlainPath) = isabsolute(genericpath(path))
Base.length(path::PlainPath) = length(genericpath(path))
Base.iterate(path::PlainPath) = iterate(genericpath(path))
Base.iterate(path::PlainPath, i::Int) = iterate(genericpath(path), i)
Base.String(path::PlainPath) = String(genericpath(path))

# See the end of `pathbuf.jl` for the implementation of
# `generic_rewrap` and `*(::PlainPath, ::PlainPath)`.

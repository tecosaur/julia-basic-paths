# Implementation of the `GenericPlainPath` type and its methods.

struct GenericPlainPath{P <: PlainPath} <: PlainPath{Unhandleable}
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
        GenericPlainPath{P}(String(SubString(path.data, 0, path.rootsep + isone(path.rootsep) - 1, Val(:noshift))), path.rootsep, 0)
    end
end

isabsolute(path::GenericPlainPath) = !iszero(path.rootsep)

function Base.parent(path::GenericPlainPath{P}) where {P <: PlainPath}
    if iszero(path.lastsep)
        return if iszero(path.rootsep) # Relative, single segment path
            if path.data == pseudoself(P) # Turn "." into ".."
                GenericPlainPath{P}(pseudoparent(P), 0, 0)
            elseif path.data == pseudoparent(P) # Turn ".." into "../.."
                GenericPlainPath{P}(pseudoparent(P) * separator(P) * pseudoparent(P), 0, ncodeunits(pseudoparent(P)) + 1)
            elseif !isnothing(pseudoself(P)) # Parent of "something" is "."
                GenericPlainPath{P}(pseudoself(P), 0, 0)
            end
        elseif ncodeunits(path.data) > path.rootsep # Root + single segment
            root(path)
        end
    elseif basename(path) === nothing # Of the form "../../.."
        GenericPlainPath{P}(path.data * separator(P) * pseudoparent(P), path.rootsep, path.lastsep + ncodeunits(pseudoparent(P)) + 1)
    else # Some multi-segment path
        priorsep = something(findprev(==(separatorbyte(P)), codeunits(path.data), path.lastsep - 1), 0)
        GenericPlainPath{P}(String(SubString(path.data, 0, max(1, path.lastsep - 1), Val(:noshift))), path.rootsep,
                            if priorsep > path.rootsep priorsep else 0 end)
    end
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

Base.@assume_effects :foldable function Base.joinpath(a::GenericPlainPath{P}, b::GenericPlainPath{P}) where {P}
    isabsolute(b) && throw(AbsolutePathError(a, b))
    if a.data == pseudoself(P)
        return b
    elseif b.data == pseudoself(P)
        return a
    end
    if ispseudopath(b)
        joinpsudoparent(a, b)
    else
        pathconcat(a, b)
    end
end

"""
    ispseudopath(p::GenericPlainPath{P})

Determine whether `p` either:
- Consists of the pseudoself segment for `P`
- Consists of the psudoparent segment for `P`
- Starts with a psudoparent segment and is immediately
  followed by a separator.

These checks should be sufficient as `GenericPlainPath`s are always represented
in a normalised form.
"""
function ispseudopath(p::GenericPlainPath{P}) where {P}
    p.data == pseudoself(P) && return true
    ppar = pseudoparent(P)
    if isnothing(ppar)
        false
    elseif startswith(p.data, ppar)
        ncodeunits(p.data) == ncodeunits(ppar) ||
            codeunit(p.data, ncodeunits(ppar) + 1) == separatorbyte(P)
    else
        false
    end
end

"""
    pathconcat(a::GenericPlainPath{P}, b::GenericPlainPath{P})

Join paths `a` and `b` together with the path separator of `P`.
"""
function pathconcat(a::GenericPlainPath{P}, b::GenericPlainPath{P}) where {P}
    cdata = a.data * separator(P) * b.data
    lastsep = ncodeunits(a.data) + b.lastsep + 1
    GenericPlainPath{P}(cdata, a.rootsep, lastsep)
end

"""
    joinpsudoparent(a::GenericPlainPath{P}, b::GenericPlainPath{P})

Join one path (`a`) with another that starts with one or more pseudo-parent segments.
"""
Base.@assume_effects :foldable function joinpsudoparent(a::GenericPlainPath{P}, b::GenericPlainPath{P}) where {P}
    sep, parentseg = separatorbyte(P), pseudoparent(P)
    plen, blen = ncodeunits(parentseg), ncodeunits(b.data)
    nparents, bstart = 0, 1
    while bstart + plen - 1 <= blen && SubString(b.data, bstart - 1, plen, Val(:noshift)) == parentseg &&
          (bstart + plen > blen || codeunit(b.data, bstart + plen) == sep)
        nparents += 1
        bstart += plen + 1
    end
    aend = ncodeunits(a.data)
    for _ in 1:nparents
        if aend > a.rootsep
            aend = something(findprev(==(sep), codeunits(a.data), aend), 1) - 1
        elseif iszero(a.rootsep)
            aend -= 1
        else
            throw(InsufficientParents(a, nparents))
        end
    end
    tail = SubString(b.data, bstart, blen)
    cdata = if aend >= 0
        head = SubString(a.data, 1, max(aend, a.rootsep))
        if isempty(head) && isempty(tail)
            pseudoself(P)
        elseif isempty(head) || isempty(tail) || endswith(head, separator(P))
            concat(head, tail)
        else
            concat(head, sep, tail)
        end
    else
        parents = join(Iterators.repeated(parentseg, -aend), separator(P))
        if isempty(tail) parents else concat(parents, sep, tail) end
    end
    lastsep = if b.lastsep >= bstart
        b.lastsep + ncodeunits(cdata) - ncodeunits(b.data)
    elseif !isempty(tail) && ncodeunits(cdata) > ncodeunits(tail)
        ncodeunits(cdata) - ncodeunits(tail)
    else
        something(findlast(==(sep), codeunits(cdata)), 0)
    end
    GenericPlainPath{P}(cdata, a.rootsep, if lastsep > a.rootsep lastsep else 0 end)
end

const PathText = Union{String, SubString{String}}

function concat(a::PathText, b::PathText)
    out = Base._string_n(ncodeunits(a) + ncodeunits(b))
    Base.__unsafe_string!(out, a, 1)
    Base.__unsafe_string!(out, b, ncodeunits(a) + 1)
    out
end

function concat(a::PathText, sep::UInt8, b::PathText)
    out = Base._string_n(ncodeunits(a) + 1 + ncodeunits(b))
    Base.__unsafe_string!(out, a, 1)
    GC.@preserve out unsafe_store!(pointer(out, ncodeunits(a) + 1), sep)
    Base.__unsafe_string!(out, b, ncodeunits(a) + 2)
    out
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
    genericpath(path::PlainPath) -> GenericPlainPath

Return the `GenericPlainPath` backing `path`.

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
# `generic_rewrap` and `joinpath(::PlainPath, ::PlainPath)`.

function generic_rewrap(f::F, path::T) where {F <: Function, T <: PlainPath}
    gp = genericpath(path)
    P = if gp isa GenericPlainPath
        (((::GenericPlainPath{P}) where {P}) -> P)(gp)
    else
        throw(ArgumentError("Unsupported path type: $(typeof(path))"))
    end
    fp = f(gp)
    isnothing(fp) && return
    if fieldtype(T, 1) == P
        T(P(fp))
    else
        P(fp)
    end
end

function Base.joinpath(a::T, b::PlainPath) where {T <: PlainPath}
    cgp = joinpath(genericpath(a), genericpath(b))
    P = if cgp isa GenericPlainPath
        (((::GenericPlainPath{P}) where {P}) -> P)(cgp)
    else
        throw(ArgumentError("Unsupported path type: $(typeof(cgp))"))
    end
    if fieldtype(T, 1) == P
        T(P(cgp))
    else
        P(cgp)
    end
end

# Implementation of the `GenericPlainPath` type and its methods.

struct GenericPlainPath{P <: PlainPath} <: PlainPath{Nothing}
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
        return if iszero(path.rootsep) # Relative, single segment path
            if path.data == pseudoself(P) # Turn "." into ".."
                GenericPlainPath{P}(pseudoparent(P), 0, 0)
            elseif path.data == pseudoparent(P) # Turn ".." into "../.."
                GenericPlainPath{P}(pseudoparent(P) * separator(P) * pseudoparent(P), 0, ncodeunits(pseudoparent(P)) + 1)
            elseif !isnothing(pseudoself(P)) # Parent of "something" is "."
                GenericPlainPath{P}(pseudoself(P), 0, 0)
            end
        elseif ncodeunits(path.data) > path.rootsep # Root + single segment
            GenericPlainPath{P}(path.data[1:path.rootsep+isone(path.rootsep)-1], path.rootsep, 0)
        end
    elseif path.data[max(path.rootsep, path.lastsep)+1:end] == pseudoparent(P) # Of the form "../../.."
        GenericPlainPath{P}(path.data * separator(P) * pseudoparent(P), path.rootsep, path.lastsep + ncodeunits(pseudoparent(P)) + 1)
    else # Some multi-segment path
        parentdata = path.data[1:max(1, path.lastsep-1)]
        priorsep = something(findlast(isequal(separatorbyte(P)), parentdata),
                            zero(UInt16))
        GenericPlainPath{P}(parentdata, path.rootsep, priorsep)
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
    abytes, bbytes = codeunits(a.data), codeunits(b.data)
    aend = ncodeunits(a.data)
    bstart = 1
    bsegend = something(findnext(==(separatorbyte(P)), bbytes, bstart),
                        length(bbytes) + 1) - 1
    # bsegend > 1 || return pathconcat(a, b)
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
        if bstart > length(bbytes)
            if a.rootsep > 0
                String(abytes[1:a.rootsep])
            else
                pseudoself(P)
            end
        else
            String(bbytes[bstart:length(bbytes)])
        end
    else
        cbytes = UInt8[]
        psegsize = ncodeunits(pseudoparent(P)) + 1
        sizehint!(cbytes, psegsize * -aend + length(bbytes) - bstart + 1)
        for _ in 1:-aend
            append!(cbytes, codeunits(pseudoparent(P)))
            push!(cbytes, separatorbyte(P))
        end
        append!(cbytes, view(bbytes, bstart:length(bbytes)))
        String(cbytes)
    end
    lastsep = b.lastsep + max(0, ncodeunits(cdata) - ncodeunits(b.data))
    GenericPlainPath{P}(cdata, a.rootsep, lastsep)
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

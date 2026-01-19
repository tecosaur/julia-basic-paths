"""
    @p_str -> LocalFilepath

Construct a [`LocalFilepath`](@ref) from a cross-platform literal representation.

The path should be written in posix style, with `/` as the separator.

Paths starting with `~` will be expanded to the user's home directory.

During construction, the part will be normalised such that:
- Parent pseudopath segments (`..`) only appear at the start
  of relative paths.
- Redundant self-referential pseudopath segments (`.`) are removed.
- The path does not end with a separator.

Similarly to strings in Julia, `\$` can be used to interpolate *path components*.
A path component can be an `AbstractString` that forms a single path segment, an
`AbstractVector{<:AbstractString}` of path segments, or another `LocalFilepath`. Literal
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
        LocalFilepath
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
        push!(components, :(parse(LocalFilepath, homedir())))
        lastidx = idx = 1 + ncodeunits("~/")
    elseif startswith(path, "~")
        tuser = first(eachsplit(path, '~'))
        throw(ArgumentError("~user tilde expansion not implemented. This path can expressed verbatim as \$'~'$(tuser[2:end])."))
    elseif startswith(path, "@/")
        dir = pkgdir(__module__)
        isnothing(dir) && throw(ArgumentError("Directory of the current module could not be determined."))
        deprel, withindepot = depot_remove(dir)
        push!(components, parse(LocalFilepath, deprel))
        lastidx = idx = 1 + ncodeunits("@/")
    elseif startswith(path, "@./")
        dir = Base.var"@__DIR__"(__source__, __module__)
        isnothing(dir) && throw(ArgumentError("Directory of the current file could not be determined."))
        deprel, withindepot = depot_remove(dir)
        push!(components, parse(LocalFilepath, deprel))
        lastidx = idx = 1 + ncodeunits("@./")
    elseif startswith(path, "@")
        atname = first(eachsplit(path, '@'))
        throw(ArgumentError("$atname shorthand not supported. This path component can be expressed verbatim as \$'@'$(atname[2:end])."))
    end
    escaped = false
    function makecomponent(prefix::String, val::Union{Expr, Symbol, String, Char}, suffix::String, delimorfinal::Bool)
        var = gensym("path#segment")
        patherr = if !delimorfinal
            :(throw(ArgumentError($"LocalFilepath `$val` should be separated from subsequent components with a / separator")))
        elseif !isempty(prefix) && !isempty(suffix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string prefix ($(sprint(show, prefix))) or suffix ($(sprint(show, suffix)))")))
        elseif !isempty(prefix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string prefix ($(sprint(show, prefix)))")))
        elseif !isempty(suffix)
            :(throw(ArgumentError($"Cannot concatenate path ($val) with a string suffix ($(sprint(show, suffix)))")))
        end
        vecerr = if !delimorfinal
            :(throw(ArgumentError($"LocalFilepath component vector `$val` should be separated from subsequent components with a / separator")))
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
                    throw(ArgumentError("Invalid path component type: $var of type $(typeof($var)), should be an AbstractString or LocalFilepath"))
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
            nodep = chopprefix(chopprefix(path, depot), string(separator(LocalFilepath)))
            return String(nodep), true
        end
    end
    path, false
end

function depot_locate(subpath::LocalFilepath)
    for depot in DEPOT_PATH
        dpath = joinpath(parse(LocalFilepath, depot), subpath)
        ispath(dpath) && return dpath
    end
    throw(error("Failed to relocate [depot]/$(String(subpath)) to any of DEPOT_PATH."))
end

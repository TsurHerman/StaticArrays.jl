################
## broadcast! ##
################

import Base.Broadcast:
    _containertype, promote_containertype, broadcast_indices,
    broadcast_c, broadcast_c!

# Add StaticArray as a new output type in Base.Broadcast promotion machinery.
# This isn't the precise output type, just a placeholder to return from
# promote_containertype, which will control dispatch to our broadcast_c.
_containertype(::Type{<:StaticArray}) = StaticArray

# With the above, the default promote_containertype gives reasonable defaults:
#   StaticArray, StaticArray -> StaticArray
#   Array, StaticArray       -> Array
#
# We could be more precise about the latter, but this isn't really possible
# without using Array{N} rather than Array in Base's promote_containertype.
#
# Base also has broadcast with tuple + Array, but while implementing this would
# be consistent with Base, it's not exactly clear it's a good idea when you can
# just use an SVector instead?
promote_containertype(::Type{StaticArray}, ::Type{Any}) = StaticArray
promote_containertype(::Type{Any}, ::Type{StaticArray}) = StaticArray

broadcast_indices(::Type{StaticArray}, A) = indices(A)


# Override for when output type is deduced to be a StaticArray.
@inline function broadcast_c(f, ::Type{StaticArray}, as...)
    _broadcast(f, broadcast_sizes(as...), as...)
end

@inline broadcast_sizes(a::StaticArray, as...) = (Size(a), broadcast_sizes(as...)...)
@inline broadcast_sizes(a, as...) = (Size(), broadcast_sizes(as...)...)
@inline broadcast_sizes() = ()

function broadcasted_index(oldsize, newindex)
    index = ones(Int, length(oldsize))
    for i = 1:length(oldsize)
        if oldsize[i] != 1
            index[i] = newindex[i]
        end
    end
    return sub2ind(oldsize, index...)
end

@generated function _broadcast(f, s::Tuple{Vararg{Size}}, a...)
    first_staticarray = 0
    for i = 1:length(a)
        if a[i] <: StaticArray
            first_staticarray = a[i]
            break
        end
    end

    sizes = [sz.parameters[1] for sz ∈ s.parameters]

    ndims = 0
    for i = 1:length(sizes)
        ndims = max(ndims, length(sizes[i]))
    end

    newsize = ones(Int, ndims)
    for i = 1:length(sizes)
        s = sizes[i]
        for j = 1:length(s)
            if newsize[j] == 1 || newsize[j] == s[j]
                newsize[j] = s[j]
            else
                throw(DimensionMismatch("Tried to broadcast on inputs sized $sizes"))
            end
        end
    end
    newsize = tuple(newsize...)

    exprs = Array{Expr}(newsize)
    more = prod(newsize) > 0
    current_ind = ones(Int, length(newsize))

    while more
        exprs_vals = [(!(a[i] <: AbstractArray) ? :(a[$i]) : :(a[$i][$(broadcasted_index(sizes[i], current_ind))])) for i = 1:length(sizes)]
        exprs[current_ind...] = :(f($(exprs_vals...)))

        # increment current_ind (maybe use CartesianRange?)
        current_ind[1] += 1
        for i ∈ 1:length(newsize)
            if current_ind[i] > newsize[i]
                if i == length(newsize)
                    more = false
                    break
                else
                    current_ind[i] = 1
                    current_ind[i+1] += 1
                end
            else
                break
            end
        end
    end

    eltype_exprs = [t <: AbstractArray ? :($(eltype(t))) : :($t) for t ∈ a]
    newtype_expr = :(Core.Inference.return_type(f, Tuple{$(eltype_exprs...)}))

    return quote
        @_inline_meta
        @inbounds return similar_type($first_staticarray, $newtype_expr, Size($newsize))(tuple($(exprs...)))
    end
end


################
## broadcast! ##
################

# TODO: This signature could be relaxed to (::Any, ::Type{StaticArray}, ::Type, ...), though
# we'd need to rework how _broadcast!() and broadcast_sizes() interact with normal AbstractArray.
@inline function broadcast_c!(f, ::Type{StaticArray}, ::Type{StaticArray}, dest, as...)
    _broadcast!(f, Size(dest), dest, broadcast_sizes(as...), as...)
end


@generated function _broadcast!(f, ::Size{newsize}, dest::StaticArray, s::Tuple{Vararg{Size}}, as...) where {newsize}
    sizes = [sz.parameters[1] for sz ∈ s.parameters]
    sizes = tuple(sizes...)

    ndims = 0
    for i = 1:length(sizes)
        ndims = max(ndims, length(sizes[i]))
    end

    for i = 1:length(sizes)
        s = sizes[i]
        for j = 1:length(s)
            if s[j] != 1 && s[j] != (j <= length(newsize) ? newsize[j] : 1)
                throw(DimensionMismatch("Tried to broadcast to destination sized $newsize from inputs sized $sizes"))
            end
        end
    end

    exprs = Array{Expr}(newsize)
    j = 1
    more = prod(newsize) > 0
    current_ind = ones(Int, max(length(newsize), length.(sizes)...))
    while more
        exprs_vals = [(!(as[i] <: AbstractArray) ? :(as[$i]) : :(as[$i][$(broadcasted_index(sizes[i], current_ind))])) for i = 1:length(sizes)]
        exprs[current_ind...] = :(dest[$j] = f($(exprs_vals...)))

        # increment current_ind (maybe use CartesianRange?)
        current_ind[1] += 1
        for i ∈ 1:length(newsize)
            if current_ind[i] > newsize[i]
                if i == length(newsize)
                    more = false
                    break
                else
                    current_ind[i] = 1
                    current_ind[i+1] += 1
                end
            else
                break
            end
        end
        j += 1
    end

    return quote
        @_inline_meta
        @inbounds $(Expr(:block, exprs...))
        return dest
    end
end

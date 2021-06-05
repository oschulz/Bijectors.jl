import Base: inv, ∘

import Random: AbstractRNG
import Distributions: logpdf, rand, rand!, _rand!, _logpdf

#######################################
# AD stuff "extracted" from Turing.jl #
#######################################

abstract type ADBackend end
struct ForwardDiffAD <: ADBackend end
struct ReverseDiffAD <: ADBackend end
struct TrackerAD <: ADBackend end
struct ZygoteAD <: ADBackend end

const ADBACKEND = Ref(:forwarddiff)
setadbackend(backend_sym::Symbol) = setadbackend(Val(backend_sym))
setadbackend(::Val{:forwarddiff}) = ADBACKEND[] = :forwarddiff
setadbackend(::Val{:reversediff}) = ADBACKEND[] = :reversediff
setadbackend(::Val{:tracker}) = ADBACKEND[] = :tracker
setadbackend(::Val{:zygote}) = ADBACKEND[] = :zygote

ADBackend() = ADBackend(ADBACKEND[])
ADBackend(T::Symbol) = ADBackend(Val(T))
ADBackend(::Val{:forwarddiff}) = ForwardDiffAD
ADBackend(::Val{:reversediff}) = ReverseDiffAD
ADBackend(::Val{:tracker}) = TrackerAD
ADBackend(::Val{:zygote}) = ZygoteAD
ADBackend(::Val) = error("The requested AD backend is not available. Make sure to load all required packages.")

######################
# Bijector interface #
######################
"""

Abstract type for a transformation.

## Implementing

A subtype of `Transform` of should at least implement `transform(b, x)`.

If the `Transform` is also invertible:
- Required:
  - [`invertible`](@ref): should return [`Invertible`](@ref).
  - _Either_ of the following:
    - `transform(::Inverse{<:MyTransform}, x)`: the `transform` for its inverse.
    - `Base.inv(b::MyTransform)`: returns an existing `Transform`.
  - [`logabsdetjac`](@ref): computes the log-abs-det jacobian factor.
- Optional:
  - [`forward`](@ref): `transform` and `logabsdetjac` combined. Useful in cases where we
    can exploit shared computation in the two.

For the above methods, there are mutating versions which can _optionally_ be implemented:
- [`transform!`](@ref)
- [`logabsdetjac!`](@ref)
- [`forward!`](@ref)

Finally, there are _batched_ versions of the above methods which can _optionally_ be implemented:
- [`transform_batch`](@ref)
- [`logabsdetjac_batch`](@ref)
- [`forward_batch`](@ref)

and similarly for the mutating versions. Default implementations depends on the type of `xs`.
Note that these methods are usually used through broadcasting, i.e. `b.(x)` with `x` a `AbstractBatch`
falls back to `transform_batch(b, x)`.
"""
abstract type Transform end

Broadcast.broadcastable(b::Transform) = Ref(b)

# Invertibility "trait".
struct NotInvertible end
struct Invertible end

# Useful for checking if compositions, etc. are invertible or not.
Base.:+(::NotInvertible, ::Invertible) = NotInvertible()
Base.:+(::Invertible, ::NotInvertible) = NotInvertible()
Base.:+(::NotInvertible, ::NotInvertible) = NotInvertible()
Base.:+(::Invertible, ::Invertible) = Invertible()

invertible(::Transform) = NotInvertible()

"""
    inv(t::Transform[, ::Invertible])

Returns the inverse of transform `t`.
"""
Base.inv(t::Transform) = Base.inv(t, invertible(t))
Base.inv(t::Transform, ::NotInvertible) = error("$(t) is not invertible")

"""
    transform(b, x)

Transform `x` using `b`.

Alternatively, one can just call `b`, i.e. `b(x)`.
"""
transform
(t::Transform)(x) = transform(t, x)

"""
    transform!(b, x, y)

Transforms `x` using `b`, storing the result in `y`.
"""
transform!(b, x, y) = (y .= transform(b, x))

"""
    logabsdetjac(b, x)

Computes the log(abs(det(J(b(x))))) where J is the jacobian of the transform.
"""
logabsdetjac

"""
    logabsdetjac!(b, x, logjac)

Computes the log(abs(det(J(b(x))))) where J is the jacobian of the transform,
_accumulating_ the result in `logjac`.
"""
logabsdetjac!(b, x, logjac) = (logjac += logabsdetjac(b, x))

"""
    forward(b, x)

Computes both `transform` and `logabsdetjac` in one forward pass, and
returns a named tuple `(rv=b(x), logabsdetjac=logabsdetjac(b, x))`.

This defaults to the call above, but often one can re-use computation
in the computation of the forward pass and the computation of the
`logabsdetjac`. `forward` allows the user to take advantange of such
efficiencies, if they exist.
"""
forward(b, x) = (result = transform(b, x), logabsdetjac = logabsdetjac(b, x))

function forward!(b, x, out)
    y, logjac = forward(b, x)
    out.result .= y
    out.logabsdetjac .+= logjac

    return out
end

"Abstract type of a bijector, i.e. differentiable bijection with differentiable inverse."
abstract type Bijector <: Transform end

invertible(::Bijector) = Invertible()

"""
    isclosedform(b::Bijector)::bool
    isclosedform(b⁻¹::Inverse{<:Bijector})::bool

Returns `true` or `false` depending on whether or not evaluation of `b`
has a closed-form implementation.

Most bijectors have closed-form evaluations, but there are cases where
this is not the case. For example the *inverse* evaluation of `PlanarLayer`
requires an iterative procedure to evaluate.
"""
isclosedform(b::Bijector) = true

"""
    inv(b::Bijector)
    Inverse(b::Bijector)

A `Bijector` representing the inverse transform of `b`.
"""
struct Inverse{B<:Bijector} <: Bijector
    orig::B
end

# field contains nested numerical parameters
Functors.@functor Inverse

inv(b::Bijector) = Inverse(b)
inv(ib::Inverse{<:Bijector}) = ib.orig
Base.:(==)(b1::Inverse{<:Bijector}, b2::Inverse{<:Bijector}) = b1.orig == b2.orig

logabsdetjac(ib::Inverse{<:Bijector}, y) = -logabsdetjac(ib.orig, ib(y))

"""
    logabsdetjacinv(b::Bijector, y)

Just an alias for `logabsdetjac(inv(b), y)`.
"""
logabsdetjacinv(b::Bijector, y) = logabsdetjac(inv(b), y)

##############################
# Example bijector: Identity #
##############################

struct Identity <: Bijector end
inv(b::Identity) = b

transform(::Identity, x) = copy(x)
transform!(::Identity, x, y) = (y .= x; return y)
logabsdetjac(::Identity, x) = zero(eltype(x))
logabsdetjac!(::Identity, x, logjac) = logjac

####################
# Batched versions #
####################
"""
    transform_batch(b, xs)

Transform `xs` by `b`, treating `xs` as a "batch", i.e. a collection of independent inputs.

See also: [`transform`](@ref)
"""
transform_batch

"""
    logabsdetjac_batch(b, xs)

Computes `logabsdetjac(b, xs)`, treating `xs` as a "batch", i.e. a collection of independent inputs.

See also: [`logabsdetjac`](@ref)
"""
logabsdetjac_batch

"""
    forward_batch(b, xs)

Computes `forward(b, xs)`, treating `xs` as a "batch", i.e. a collection of independent inputs.

See also: [`transform`](@ref)
"""
forward_batch(b, xs) = (result = transform_batch(b, xs), logabsdetjac = logabsdetjac_batch(b, xs))

######################
# Bijectors includes #
######################
# General
include("bijectors/adbijector.jl")
include("bijectors/composed.jl")
include("bijectors/stacked.jl")

# Specific
include("bijectors/exp_log.jl")
include("bijectors/logit.jl")
include("bijectors/scale.jl")
include("bijectors/shift.jl")
include("bijectors/permute.jl")
include("bijectors/simplex.jl")
include("bijectors/pd.jl")
include("bijectors/corr.jl")
include("bijectors/truncated.jl")
include("bijectors/named_bijector.jl")

# Normalizing flow related
include("bijectors/planar_layer.jl")
include("bijectors/radial_layer.jl")
include("bijectors/leaky_relu.jl")
include("bijectors/coupling.jl")
include("bijectors/normalise.jl")
include("bijectors/rational_quadratic_spline.jl")

##################
# Other includes #
##################
include("transformed_distribution.jl")

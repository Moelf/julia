# This file is a part of Julia. License is MIT: https://julialang.org/license

module TestBoundsCheck

using Test, Random, InteractiveUtils

@enum BCOption bc_default bc_on bc_off
bc_opt = BCOption(Base.JLOptions().check_bounds)

# test for boundscheck block eliminated at same level
@inline function A1()
    r = 0
    @boundscheck r += 1
    return r
end

@noinline function A1_noinline()
    r = 0
    @boundscheck r += 1
    return r
end

function A1_inbounds()
    r = 0
    @inbounds begin
        @boundscheck r += 1
    end
    return r
end
A1_wrap() = @inbounds return A1_inbounds()

if bc_opt == bc_default
    @test A1() == 1
    @test A1_inbounds() == 1
    @test A1_wrap() == 0
elseif bc_opt == bc_on
    @test A1() == 1
    @test A1_inbounds() == 1
    @test A1_wrap() == 1
else
    @test A1() == 0
    @test A1_inbounds() == 0
    @test A1_wrap() == 0
end

# test for boundscheck block eliminated one layer deep, if the called method is inlined
@inline function A2()
    r = A1()+1
    return r
end

function A2_inbounds()
    @inbounds r = A1()+1
    return r
end

function A2_notinlined()
    @inbounds r = A1_noinline()+1
    return r
end

Base.@propagate_inbounds function A2_propagate_inbounds()
    r = A1()+1
    return r
end

if bc_opt == bc_default
    @test A2() == 2
    @test A2_inbounds() == 1
    @test A2_notinlined() == 2
    @test A2_propagate_inbounds() == 2
elseif bc_opt == bc_on
    @test A2() == 2
    @test A2_inbounds() == 2
    @test A2_notinlined() == 2
    @test A2_propagate_inbounds() == 2
else
    @test A2() == 1
    @test A2_inbounds() == 1
    @test A2_notinlined() == 1
    @test A2_propagate_inbounds() == 1
end

# test boundscheck NOT eliminated two layers deep, unless propagated

function A3()
    r = A2()+1
    return r
end

function A3_inbounds()
    @inbounds r = A2()+1
    return r
end

function A3_inbounds2()
    @inbounds r = A2_propagate_inbounds()+1
    return r
end

if bc_opt == bc_default
    @test A3() == 3
    @test A3_inbounds() == 3
    @test A3_inbounds2() == 2
elseif bc_opt == bc_on
    @test A3() == 3
    @test A3_inbounds() == 3
    @test A3_inbounds2() == 3
else
    @test A3() == 2
    @test A3_inbounds() == 2
    @test A3_inbounds2() == 2
end

# swapped nesting order of @boundscheck and @inbounds
function A1_nested()
    r = 0
    @boundscheck @inbounds r += 1
    return r
end

if bc_opt == bc_default || bc_opt == bc_on
    @test A1_nested() == 1
else
    @test A1_nested() == 0
end

# elide a throw
cb(x) = x > 0 || throw(BoundsError())

@inline function B1()
    y = [1, 2, 3]
    @inbounds begin
        @boundscheck cb(0)
    end
    return 0
end
B1_wrap() = @inbounds return B1()

if bc_opt == bc_default
    @test_throws BoundsError B1()
    @test B1_wrap() == 0
elseif bc_opt == bc_off
    @test B1() == 0
    @test B1_wrap() == 0
else
    @test_throws BoundsError B1()
    @test_throws BoundsError B1_wrap()
end

# elide a simple branch
cond(x) = x > 0 ? x : -x

function B2()
    y = [1, 2, 3]
    @inbounds begin
        @boundscheck cond(0)
    end
    return 0
end

@test B2() == 0

# Make sure type inference doesn't incorrectly optimize out
# `Expr(:inbounds, false)`
# Simply `return a[1]` doesn't work due to inlining bug
@inline function f1(a)
    # This has to be an arrayget / arrayset since these currently have a
    # implicit `Expr(:boundscheck)` that's not visible to type inference
    x = a[1]
    return x
end
# second level
@inline function g1(a)
    x = f1(a)
    return x
end
function k1(a)
    # This `Expr(:inbounds, true)` shouldn't affect `f1`
    @inbounds x = g1(a)
    return x
end
if bc_opt != bc_off
    @test_throws BoundsError k1(Int[])
end

# Ensure that broadcast doesn't use @inbounds when calling the function
if bc_opt != bc_off
    let A = zeros(3,3)
        @test_throws BoundsError broadcast(getindex, A, 1:3, 1:3)
    end
end

# issue #19554
function f19554(a)
    a[][3]
end
function f19554_2(a, b)
    a[][3] = b
    return a
end
a19554 = Ref{Array{Float64}}([1 2; 3 4])
@test f19554(a19554) === 2.0
@test f19554_2(a19554, 1) === a19554
@test a19554[][3] === f19554(a19554) === 1.0

# Ensure unsafe_view doesn't check bounds
function V1()
    A = rand(10,10)
    B = view(A, 4:7, 4:7)
    C = Base.unsafe_view(B, -2:7, -2:7)
    @test C == A
    nothing
end

if bc_opt == bc_default || bc_opt == bc_off
    @test V1() === nothing
else
    @test_throws BoundsError V1()
end

# This tests both the bounds check elision and the behavior of `jl_array_isassigned`
# For `isbits` array the `ccall` should return a constant `true` and does not access
# the array
inbounds_isassigned(a, i) = @inbounds return isassigned(a, i)
if bc_opt == bc_default || bc_opt == bc_off
    @test inbounds_isassigned(Int[], 2) == true
else
    @test inbounds_isassigned(Int[], 2) == false
end

# Test that @inbounds annotations don't propagate too far for Array; Issue #20469
struct BadVector20469{T} <: AbstractVector{Int}
    data::T
end
Base.size(X::BadVector20469) = size(X.data)
Base.getindex(X::BadVector20469, i::Int) = X.data[i-1]
if bc_opt != bc_off
    @test_throws BoundsError BadVector20469([1,2,3])[:]
end

# Ensure iteration over arrays is vectorizable with boundschecks off
function g27079(X)
    r = 0
    @inbounds for x in X
        r += x
    end
    r
end
if bc_opt == bc_default || bc_opt == bc_off
    @test occursin("vector.body", sprint(code_llvm, g27079, Tuple{Vector{Int}}))
end

# Ensure broadcasting can vectorize when bounds checks are off
if bc_opt != bc_on
    function goo28126(u, uprev, k1, k2, k3, k4, k5, k6, k7)
        @. u = uprev + 0.1*(0.1*k1 + 0.2*k2 + 0.3*k3 + 0.4*k4 + 0.5*k5 + 0.6*k6 + 0.7*k7)
        nothing
    end
    @test occursin("vector.body", sprint(code_llvm, goo28126, NTuple{9, Vector{Float32}}))
end

end

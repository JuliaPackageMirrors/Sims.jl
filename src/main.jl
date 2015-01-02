
##############################################
## Non-causal time-domain modeling in Julia ##
##############################################

# Tom Short, tshort@epri.com
#
#
# Copyright (c) 2012, Electric Power Research Institute 
# BSD license - see the LICENSE file
 
# 
# This file is an experiment in doing non-causal modeling in Julia.
# The idea behind non-causal modeling is that the user develops models
# based on components which are described by a set of equations. A
# tool can then transform the equations and solve the differential
# algebraic equations. Non-causal models tend to match their physical
# counterparts in terms of their specification and implementation.
#
# Causal modeling is where all signals have an input and an output,
# and the flow of information is clear. Simulink is the
# highest-profile example.
# 
# The highest profile noncausal modeling tools are in the Modelica
# (www.modelica.org) family. The MathWorks also has Simscape that uses
# Matlab notation. Modelica is an object-oriented, open language with
# multiple implementations. It is a large, complex, powerful language
# with an extensive standard library of components.
#
# This implementation follows the work of David Broman and his MKL
# simulator and the work of George Giorgidze and Henrik Nilsson and
# their functional hybrid modeling.
#
# A nodal formulation is used based on David's work. His thesis
# documents this nicely:
# 
#   David Broman. Meta-Languages and Semantics for Equation-Based
#   Modeling and Simulation. PhD thesis, Thesis No 1333. Department of
#   Computer and Information Science, Link�ping University, Sweden,
#   2010.
#   http://www.bromans.com/david/publ/thesis-2010-david-broman.pdf
#
# Here is David's code and home page:
# 
#   http://www.bromans.com/software/mkl/mkl-source-1.0.0.zip
#   http://www.ida.liu.se/~davbr/
#   
# Modeling of dynamically varying systems is handled similarly to
# functional hybrid modelling (FHM), specifically the Hydra
# implementation by George. See here for links:
# 
#   https://github.com/giorgidze/Hydra
#   http://db.inf.uni-tuebingen.de/team/giorgidze
#   http://www.cs.nott.ac.uk/~nhn/
# 
# FHM is also a functional approach. Hydra is implemented as a domain
# specific language embedded in Haskell. Their implementation handles
# dynamically changing systems with JIT-compiled code from an
# amazingly small amount of code.
# 
# As stated, this file implements something like David's approach. A
# model constructor returns a list of equations. Models are made of
# models, so this builds up a hierarchical structure of equations that
# then need to be flattened. David's approach is nodal; nodes are
# passed in as parameters to models to perform connections between
# devices.
#
# What can it do:
#   - Index-1 DAE's using the DASSL solver
#   - Arrays of unknown variables
#   - Complex valued unknowns
#   - Hybrid modeling
#   - Discrete systems
#   - Structurally variable systems
#   
# What's missing:
#   - Initial equations
#   - Causal relationships or input/outputs (?)
#   - Metadata like variable name, units, and annotations (hard?)
#   - Symbolic processing like index reduction
#   - Error checking
#   - Tests
#
# Downsides of this approach:
#   - No connect-like capability. Must be nodal.
#   - Tough to do model introspection.
#   - Tough to map to a GUI. This is probably true with most
#     functional approaches. Tough to add annotations.
#
# For an implementation point of view, Julia works well for this. The
# biggest headache was coding up the callback to the residual
# function. For this, I used a kludgy approach with several global
# variables. This should improve in the future with a better C api. I
# also tried interfacing with the Sundials IDA solver, but that was
# even more difficult to interface. 
# 

sim_verbose = 1
function sim_info(msgs...)
    if sim_verbose > 0
        apply(println,msgs)
    end
end

########################################
## Type definitions                   ##
########################################

#
# This includes a few symbolic types of abstracted type ModelType.
# This includes symbols, expressions, and other objects that reduce to
# expressions.
#
# Expressions (of type MExpr) are built up based on Unknown's. Unknown
# is a symbol with a uniquely generated symbol name. If you have
#   a = 1
#   b = Unknown()
#   a * b + b^2
# evaluation produces the following:
#   MExpr(+(*(1,##1029),*(##1029,##1029)))
#   
# This is an expression tree where ##1029 is the symbol name for b.
# 
# The idea is that you can set up a set of hierarchical equations that
# will be later flattened.
#
# Other types or method definitions can be used to assign behavior
# during flattening (like the Branch type) or during instantiation
# (like the der method).
# 

abstract ModelType
abstract UnknownCategory
abstract UnknownVariable <: ModelType

type DefaultUnknown <: UnknownCategory
end

type Unknown{T<:UnknownCategory} <: UnknownVariable
    sym::Symbol
    value         # holds initial values (and type info)
    label::String
    fixed::Bool
    save_history::Bool
    Unknown() = new(gensym(), 0.0, "", false, false)
    Unknown(sym::Symbol, label::String) = new(sym, 0.0, label, false, true)
    Unknown(sym::Symbol, value) = new(sym, value, "", false, false)
    Unknown(value) = new(gensym(), value, "", false, false)
    Unknown(label::String) = new(gensym(), 0.0, label, false, true)
    Unknown(value, label::String) = new(gensym(), value, label, false, true)
    Unknown(sym::Symbol, value, label::String) = new(sym, value, label, false, true)
    Unknown(sym::Symbol, value, label::String, fixed::Bool, save_history::Bool) =
        new(sym, value, label, fixed, save_history)
end
Unknown() = Unknown{DefaultUnknown}(gensym(), 0.0, "", false, false)
Unknown(x) = Unknown{DefaultUnknown}(gensym(), x, "", false, false)
Unknown(s::Symbol, label::String) = Unknown{DefaultUnknown}(s, 0.0, label, false, true)
Unknown(x, label::String) = Unknown{DefaultUnknown}(gensym(), x, label, false, true)
Unknown(label::String) = Unknown{DefaultUnknown}(gensym(), 0.0, label, false, true)
Unknown(s::Symbol, x, fixed::Bool) = Unknown{DefaultUnknown}(s, x, "", fixed, false)
Unknown(s::Symbol, x) = Unknown{DefaultUnknown}(s, x, "", false, false)


is_unknown(x) = isa(x, UnknownVariable)
    
type DerUnknown <: UnknownVariable
    sym::Symbol
    value        # holds initial values
    fixed::Bool
    parent::Unknown
    # label::String    # Do we want this? 
end
DerUnknown(u::Unknown) = DerUnknown(u.sym, 0.0, false, u)
der(x::Unknown) = DerUnknown(x.sym, compatible_values(x), false, x)
der(x::Unknown, val) = DerUnknown(x.sym, val, true, x)
der(x) = 0.0

show(io::IO, a::UnknownVariable) = print(io::IO, "<<", name(a), ",", value(a), ">>")

type MExpr <: ModelType
    ex::Expr
end
mexpr(hd::Symbol, args::ANY...) = MExpr(Expr(hd, args...))


type Parameter{T<:UnknownCategory} <: UnknownVariable
    sym::Symbol
    value         # holds parameter value (and type info)
    label::String
    Parameter(sym::Symbol, value) = new(sym, value, "")
    Parameter(value) = new(gensym(), value, "")
    Parameter(sym::Symbol, label::String) = new(sym, 0.0, label)
    Parameter(value, label::String) = new(gensym(), value, label)
end
Parameter(v) = Parameter{DefaultUnknown}(gensym(), v)


# Set up defaults for operations on ModelType's for many common
# methods.


unary_functions = [:(+), :(-), :(!),
                   :abs, :sign, :acos, :acosh, :asin,
                   :asinh, :atan, :atanh, :sin, :sinh,
                   :cos, :cosh, :tan, :tanh, :ceil, :floor,
                   :round, :trunc, :exp, :exp2, :expm1, :log, :log10, :log1p,
                   :log2, :sqrt, :gamma, :lgamma, :digamma,
                   :erf, :erfc, 
                   :min, :max, :prod, :sum, :mean, :median, :std,
                   :var, :norm,
                   :diff, 
                   :cumprod, :cumsum, :cumsum_kbn, :cummin, :cummax,
                   :fft,
                   ## :rowmins, :rowmaxs, :rowprods, :rowsums,
                   ## :rowmeans, :rowmedians, :rowstds, :rowvars,
                   ## :rowffts, :rownorms,
                   ## :colmins, :colmaxs, :colprods, :colsums,
                   ## :colmeans, :colmedians, :colstds, :colvars,
                   ## :colffts, :colnorms,
                   :any, :all,
                   :iceil,  :ifloor, :itrunc, :iround,
                   :angle,
                   :sin,    :cos,    :tan,    :cot,    :sec,   :csc,
                   :sinh,   :cosh,   :tanh,   :coth,   :sech,  :csch,
                   :asin,   :acos,   :atan,   :acot,   :asec,  :acsc,
                   :acoth,  :asech,  :acsch,  :sinc,   :cosc,
                   :transpose, :ctranspose]

binary_functions = [:(.==), :(!=), :(.!=), :isless, 
                    :(.>), :(.>=), :(.<), :(.<=),
                    :(>), :(>=), :(<), :(<=),
                    :(+), :(.+), :(-), :(.-), :(*), :(.*), :(/), :(./),
                    :(.^), :(^), :(div), :(mod), :(fld), :(rem),
                    :(&), :(|), :($),
                    :atan2,
                    :dot, :cor, :cov]

_expr(x) = x
_expr(x::MExpr) = x.ex

macro doimport(name)
  Expr(:toplevel, Expr(:import, :Base, esc(name)))
end

# special case to avoid a warning:
import Base.(^)
(^)(x::ModelType, y::Integer) = mexpr(:call, (^), _expr(x), y)

for f in binary_functions
    ## @eval import Base.(f)
    eval(Expr(:toplevel, Expr(:import, :Base, f)))
    @eval ($f)(x::ModelType, y::ModelType) = mexpr(:call, ($f), _expr(x), _expr(y))
    @eval ($f)(x::ModelType, y::Number) = mexpr(:call, ($f), _expr(x), y)
    @eval ($f)(x::ModelType, y::AbstractArray) = mexpr(:call, ($f), _expr(x), y)
    @eval ($f)(x::Number, y::ModelType) = mexpr(:call, ($f), x, _expr(y))
    @eval ($f)(x::AbstractArray, y::ModelType) = mexpr(:call, ($f), x, _expr(y))
end 

for f in unary_functions
    ## @eval import Base.(f)
    eval(Expr(:toplevel, Expr(:import, :Base, f)))

    # Define separate method to get rid of 'ambiguous definition' warnings in base/floatfuncs.jl
    @eval ($f)(x::ModelType, arg::Integer) = mexpr(:call, ($f), _expr(x), arg)

    @eval ($f)(x::ModelType, args...) = mexpr(:call, ($f), _expr(x), map(_expr, args)...)
end

# Non-Base functions:
for f in [:der, :pre]
    @eval ($f)(x::ModelType, args...) = mexpr(:call, ($f), _expr(x), args...)
end

# For now, a model is just a vector that anything, but probably it
# should include just ModelType's.
const Model = Vector{Any}


# Add array access capability for Unknowns:

type RefUnknown{T<:UnknownCategory} <: UnknownVariable
    u::Unknown{T}
    idx
end
getindex(x::Unknown, args...) = RefUnknown(x, args)
getindex(x::MExpr, args...) = mexpr(:call, :getindex, args...)
length(u::UnknownVariable) = length(value(u))
size(u::UnknownVariable, i) = size(value(u), i)
hcat(x::ModelType...) = mexpr(:call, :hcat, x...)
vcat(x::ModelType...) = mexpr(:call, :vcat, x...)

value(x) = x
value(x::Model) = map(value, x)
value(x::UnknownVariable) = x.value
value(x::RefUnknown) = x.u.value[x.idx...]
value(a::MExpr) = value(a.ex)
value(e::Expr) = eval(Expr(e.head, (isempty(e.args) ? e.args : map(value, e.args))...))
value(x::Parameter) = x.value

function symname(s::Symbol)
    s = string(s)
    length(s) > 3 && s[1:2] == "##" ? "`" * s[3:end] * "`" : s
end
name(a::Unknown) = a.label != "" ? a.label : symname(a.sym)
name(a::DerUnknown) = a.parent.label != "" ? a.parent.label : symname(a.parent.sym)
name(a::RefUnknown) = a.u.label != "" ? a.u.label : symname(a.u.sym)
name(a::Parameter) = a.label != "" ? a.label : symname(a.sym)

# The following helper functions are to return the base value from an
# unknown to use when creating other unknowns. An example would be:
#   a = Unknown(45.0 + 10im)
#   b = Unknown(base_value(a))   # This one gets initialized to 0.0 + 0.0im.
#
compatible_values(x) = zero(x)
compatible_values(x,y) = length(x) > length(y) ? zero(x) : zero(y)
compatible_values(u::UnknownVariable) = value(u) .* 0.0
# The value from the unknown determines the base value returned:
compatible_values(u1::UnknownVariable, u2::UnknownVariable) = length(value(u1)) > length(value(u2)) ? value(u1) .* 0.0 : value(u2) .* 0.0  
compatible_values(u::UnknownVariable, num::Number) = length(value(u)) > length(num) ? value(u) .* 0.0 : num .* 0.0 
compatible_values(num::Number, u::UnknownVariable) = length(value(u)) > length(num) ? value(u) .* 0.0 : num .* 0.0 
# This should work for real and complex valued unknowns, including
# arrays. For something more complicated, it may not.



# System time - a special unknown variable
const MTime = Unknown(:time, 0.0)


#  The type RefBranch and the helper Branch are used to indicate the
#  potential between nodes and the flow between nodes.

type RefBranch <: ModelType
    n     # This is the reference node.
    i     # This is the flow variable that goes with this reference.
end

function Branch(n1, n2, v, i)
    {
     RefBranch(n1, i)
     RefBranch(n2, -i)
     n1 - n2 - v
     }
end



########################################
## Initial equations                  ##
########################################

type InitialEquation
    eq
end

# TODO enhance this to support begin..end blocks
macro init(eqs...)
   Expr(:cell1d, [:(InitialEquation($eq)) for eq in eqs])
end

########################################
## delay                              ##
########################################


# Identity unknown: don't replace with a ref to the y array
type PassedUnknown <: UnknownVariable
    ref
end

## TODO: refactor for SimStateHistory interface
function _interp(x, t)
    # assumes that tvec is sorted from low to high
    if length(x.t) == 0 || t < 0.0 return zero(x.value) end
    idx = searchsortedfirst(x.t, t)
    if idx == 1
        return x.x[1]
    elseif idx > length(x.t) 
        return x.x[end]
    else
        return (t - x.t[idx-1]) / (x.t[idx] - x.t[idx-1]) .* (x.x[idx] - x.x[idx-1]) + x.x[idx-1]
    end
end
# version vectorized on t:
function _interp(x, t)
    res = zero(t)
    for i in 1:length(res)
        if t[i] < 0.0 continue end
        idx = searchsortedfirst(x.t, t[i])
        if idx > length(res) continue end
        if idx == 1
            res[i] = x.x[1][i]
        elseif idx > length(x.t) 
            res[i] = x.x[end][i]
        else
            res[i] = (t[i] - x.t[idx-1]) / (x.t[idx] - x.t[idx-1]) .* (x.x[idx][i] - x.x[idx-1][i]) + x.x[idx-1][i]
        end
    end
    res
end


function delay(x::Unknown, val)
    x.save_history = true
    MExpr(:(Sims._interp($(PassedUnknown(x)), t[1] - $(val))))
end


########################################
## Utilities for Hybrid Modeling      ##
########################################



#
# Discrete is a type for discrete variables. These are only changed
# during events. They are not used by the integrator.
#
type Discrete <: UnknownVariable
    sym::Symbol
    value
    label::String
    ## hooks::Vector{Function}
    hookex::Vector{Expr}
end
Discrete() = Discrete(gensym(), 0.0, "")
Discrete(x) = Discrete(gensym(), x, "")
Discrete(s::Symbol, label::String) = Discrete(s, 0.0, label)
Discrete(x, label::String) = Discrete(gensym(), x, label)
Discrete(label::String) = Discrete(gensym(), 0.0, label)
Discrete(s::Symbol, x) = Discrete(s, x, "")
Discrete(s::Symbol, x, label::String) = Discrete(s, x, label, Expr[])

## function Discrete(s::Symbol, x, ex::MExpr, label::String)
##     res = Discrete(s, x, label)
##     x.value = value(ex)
##     x.ex = ex
## end

type RefDiscrete <: UnknownVariable
    u::Discrete
    idx
end
getindex(x::Discrete, args...) = RefDiscrete(x, args)

## DiscreteVar is used inside of the residual function.
type DiscreteVar
    value
    pre
    hooks::Vector{Function}
end
DiscreteVar(d::Discrete, funs::Vector{Function}) = DiscreteVar(d.value, d.value, funs)
DiscreteVar(d::Discrete) = DiscreteVar(d.value, d.value, Function[])

# Add hooks to a discrete variable.
addhook!(d::Discrete, ex::ModelType) = push!(d.hookex, strip_mexpr(ex))

value(x::RefDiscrete) = x.u.value[x.idx...]
value(x::DiscreteVar) = x.value
name(x::Discrete) = x.label != "" ? x.label : symname(x.sym)
name(x::RefDiscrete) = x.u.label != "" ? x.u.label : symname(x.u.sym)
name(x::DiscreteVar) = "D"
pre(x::DiscreteVar) = x.pre

#
# Event is the main type used for hybrid modeling. It contains a
# condition for root finding and model expressions to process after
# positive and negative root crossings are detected.
#

type Event <: ModelType
    condition::ModelType   # An expression used for the event detection. 
    pos_response::Model    # An expression indicating what to do when
                           # the condition crosses zero positively.
    neg_response::Model    # An expression indicating what to do when
                           # the condition crosses zero in the
                           # negative direction.
end
Event(condition::ModelType, p::MExpr, n::MExpr) = Event(condition, {p}, {n})
Event(condition::ModelType, p::Model, n::MExpr) = Event(condition, p, {n})
Event(condition::ModelType, p::MExpr, n::Model) = Event(condition, {p}, n)
Event(condition::ModelType, p::Model) = Event(condition, p, {})
Event(condition::ModelType, p::MExpr) = Event(condition, {p}, {})
Event(condition::ModelType, p::Expr) = Event(condition, p, {})

#
# reinit is used in Event responses to redefine variables. LeftVar is
# needed to mark unknowns as left-side variables in assignments during
# event responses.
# 
type LeftVar <: ModelType
    var
end
function reinit(x, y)
    sim_info("reinit: ", x[], " to ", y)
    x[:] = y
end
function reinit(x::DiscreteVar, y)
    sim_info("reinit discrete: ", x.value, " to ", y)
    x.pre = x.value
    x.value = y
    for fun in x.hooks
        fun()
    end
end
reinit(x::LeftVar, y) = mexpr(:call, :(Sims.reinit), x, y)
reinit(x::LeftVar, y::MExpr) = mexpr(:call, :(Sims.reinit), x, y.ex)
reinit(x::Unknown, y) = reinit(LeftVar(x), y)
reinit(x::RefUnknown, y) = reinit(LeftVar(x), y)
reinit(x::DerUnknown, y) = reinit(LeftVar(x), y)
reinit(x::Discrete, y) = reinit(LeftVar(x), y)
reinit(x::RefDiscrete, y) = reinit(LeftVar(x), y)
## reinit(x::Discrete, y) = mexpr(:call, :reinit, x, y)
## reinit(x::RefDiscrete, y) = mexpr(:call, :reinit, x, y)
setindex!(x::DiscreteVar, y, idx) = x.value = y

#
# BoolEvent is a helper for attaching an event to a boolean variable.
# In conjunction with ifelse, this allows constructs like Modelica's
# if blocks.
#
function BoolEvent(d::Union(Discrete, RefDiscrete), condition::ModelType)
    lend = length(value(d))
    lencond = length(value(condition))
    if lend > 1 && lencond == lend
        convert(Vector{Any},
                map((idx) -> BoolEvent(d[idx], condition[idx]), [1:lend]))
    elseif lend == 1 && lencond == 1
        Event(condition,       
              {reinit(d, true)},
              {reinit(d, false)})
    else
        error("Mismatched lengths for BoolEvent")
    end
end

#
# ifelse is like an if-then-else block, but for ModelTypes.
#
ifelse(x::Bool, y, z) = x ? y : z
ifelse(x::Bool, y) = x ? y : nothing
ifelse(x::Array{Bool}, y, z) = map((x) -> ifelse(x,y,z), x)
ifelse(x::Array{Bool}, y) = map((x) -> ifelse(x,y), x)
ifelse(x::ModelType, y, z) = mexpr(:call, :ifelse, x, y, z)
ifelse(x::ModelType, y) = mexpr(:call, :ifelse, x, y)
ifelse(x::MExpr, y, z) = mexpr(:call, :ifelse, x.ex, y, z)
ifelse(x::MExpr, y) = mexpr(:call, :ifelse, x.ex, y)
ifelse(x::MExpr, y::MExpr, z::MExpr) = mexpr(:call, :ifelse, x.ex, y.ex, z.ex)
ifelse(x::MExpr, y::MExpr) = mexpr(:call, :ifelse, x.ex, y.ex)




########################################
## Types for Structural Dynamics      ##
########################################

#
# StructuralEvent defines a type for elements that change the
# structure of the model. An event is created (condition is the zero
# crossing). When the event is triggered, the model is re-flattened
# after replacing default with new_relation in the model. 
type StructuralEvent <: ModelType
    condition::ModelType  # Expression indicating a zero crossing for event detection.
    default
    new_relation::Function
    activated::Bool       # Indicates whether the event condition has fired
    response::Union(Function,Nothing) # if given, the response function will be called with the model state and parameters
end
StructuralEvent(condition::MExpr, default, new_relation::Function) =
    StructuralEvent(condition, default, new_relation, false, nothing)
StructuralEvent(condition::MExpr, default, new_relation::Function, response::Function) =
    StructuralEvent(condition, default, new_relation, false, response)





########################################
## Complex number support             ##
########################################

#
# To support objects other than Float64, the methods to_real and
# from_real need to be defined.
#
# When complex quantities are output, the y array will contain the
# real and imaginary parts. These will not be labeled as such.
#

## from_real(x::Array{Float64, 1}, ref::Complex) = complex(x[1:2:length(x)], x[2:2:length(x)])
basetypeof{T}(x::Array{T}) = T
basetypeof(x) = typeof(x)
from_real(x::Array{Float64, 1}, basetype, sz) = reinterpret(basetype, x, sz)

to_real(x::Float64) = x
to_real(x::Array{Float64, 1}) = x
to_real(x::Array{Float64}) = x[:]
## to_real(x::Complex) = Float64[real(x), imag(x)]
## function to_real(x::Array{Complex128, 1}) # I tried reinterpret for this, but it seemed broken.
##     res = fill(0., 2*length(x))
##     for idx = 1:length(x)
##         res[2 * idx - 1] = real(x[idx])
##         res[2 * idx] = imag(x[idx])
##     end
##     res
## end
to_real(x) = reinterpret(Float64, [x][:])



########################################
## @equations macro                   ##
########################################

macro equations(args)
    esc(equations_helper(args))
end

function parse_args(a::Expr)
    if a.head == :line
        nothing
    elseif a.head == :(=)
        Expr(:call, :-, parse_args(a.args[1]), parse_args(a.args[2]))
    else
        Expr(a.head, [parse_args(x) for x in a.args]...)
    end
end

parse_args(a::Array) = [parse_args(x) for x in a]
parse_args(x) = x

function equations_helper(arg)
    Expr(:ref, :Equation, parse_args(arg.args)...)
end

typealias Equation Any
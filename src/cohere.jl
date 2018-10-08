using MacroTools
using Match
using Parameters
using Parameters
using AxisArrays
using Unitful

export cohere, component, mask, ncomponents, components, component_means,
  windowing, map_windowing

abstract type CoherenceMethod end
struct CParams{M,P}
  cort::P
  ncomponents::Int
  skipframes::Int
  window::typeof(1.0s)
  delta::typeof(1.0s)
  method::M
end

const Coherence = MetaArray{<:AxisArray,<:CParams}
const CParamLike = Union{CParams,Coherence}

ShammaModel.Δt(as::CParamLike) = as.delta

function Base.show(io::IO,::MIME"text/plain",x::Coherence)
  if !get(io, :compact, false)
    println(io,"Coherence Components")
    describe_axes(io,x)
  else
    println(io,string(duration(x))," Coherence Components")
  end
end

ncomponents(x::CParams) = x.ncomponents
ncomponents(x::AbstractArray) = size(x,axisdim(x,Axis{:component}))
components(x::CParams) = 1:ncomponents(x)
components(x::AbstractArray) = axisvalues(AxisArrays.axes(x,Axis{:component}))[1]
component(x::AbstractArray,n) = x[Axis{:component}(n)]

ShammaModel.hastimes(x::Coherence) = HasTimes()

function component_means(C)
  mdims = filter(x -> x != axisdim(C,Axis{:component}),1:ndims(C))
  vec(mean(C,dims=mdims))
end

ShammaModel.frame_length(params::CParams,x) =
  max(1,floor(Int,params.delta / Δt(x)))

function CParams(x;ncomponents=1,window_ms=1000,window=window_ms*ms,
                 delta_ms=10,delta=delta_ms*ms,
                 method=:nmf,skipframes=0,method_kwds...)
  method = CoherenceMethod(Val{method},method_kwds)

  CParams(getmeta(x), ncomponents, skipframes,
          convert(typeof(1.0s),window), convert(typeof(1.0s),delta), method)
end

windowing(x,params::CParams) =
  windowing(x,length=params.window,step=params.delta)

windowing(x,dim=timedim(x);kwds...) = windowing(hastimes(x),x,dim;kwds...)
map_windowing(fn,x,dim=timedim(x);kwds...) =
  map_windowing(fn,hastimes(x),x,dim;kwds...)
function map_windowing(fn,::HasTimes,x,dim;step=nothing,kwds...)
  windows = windowing(x,dim;step=step,kwds...)
  xs = map(windows) do ixs
    fn(x[Axis{:time}(ixs)])
  end
  AxisArray(xs,AxisArrays.axes(windows,Axis{:time}))
end
map_windowing(fn,::HasNoTimes,x,dim;kwds...) =
  map(ixs -> fn(x[Axis{:time}(ixs)]),windowing(HasNoTimes(),x,dim;kwds...))

function windowing(::HasNoTimes,x::AbstractArray,dim;
                   length=nothing,step=nothing,minlength=length)
  (max(1,t-length+1):t for t in Base.axes(x,dim)[minlength:step:end])
end

function windowing(::HasTimes,data::AbstractArray,dim;
                   length=nothing,step=nothing,minlength=length)
  helper(x::Number) = x
  helper(x::Quantity) = max(1,floor(Int,x / Δt(data)))
  length_,step_,minlength_ = helper.((length,step,minlength))

  win = windowing(HasNoTimes(),data,dim,
                  length=length_,step=step_,minlength=minlength_)
  AxisArray(collect(win),
            Axis{:time}((minlength_:step_:size(data,dim))*Δt(data)))
end

windowlen(params::CParams,x) = round(Int,params.window/Δt(x))
function nunits(params::CParams,x)
  mapreduce(*,AxisArrays.axes(x)) do ax
    isa(ax,Axis{:time}) || isa(ax,Axis{:rate}) ? 1 : length(ax)
  end
end

cohere(x::ShammaModel.Cortical;progressbar=true,params...) =
  cohere(x,CParams(x;params...),progressbar)

function cohere_progress(progressbar,x,params)
  if progressbar
    windows = windowing(x,params)
    Progress(length(windows),desc="Temporal Coherence Analysis: ")
  end
end

function cohere(x::MetaUnion{AxisArray},params::CParams,
                progressbar=true,
                progress = cohere_progress(progressbar,x,params))
  @assert axisdim(x,Axis{:time}) == 1
  @assert axisdim(x,Axis{:rate}) == 2
  @assert axisdim(x,Axis{:scale}) == 3
  @assert axisdim(x,Axis{:freq}) == 4
  @assert ndims(x) == 4

  # if we already have components, just wrap up the values with
  # parameters (since we've already computed components)
  if :component in axisnames(x)
    return MetaArray(params,x)
  end

  windows = windowing(x,params)

  K = ncomponents(params)
  C_data = zeros(eltype(params.method,x),length(windows),size(x)[3:end]...,K)
  C = AxisArray(C_data,
                AxisArrays.axes(windows,Axis{:time}),
                AxisArrays.axes(x)[3:end]...,
                Axis{:component}(1:K))

  with_method(params.method,K) do extract
    for (i,w_inds) in enumerate(windows)
      skipped = w_inds[1:1+params.skipframes:end]
      # axis array can't handle skipped indices, so we assume
      # the right dimensionality
      components = extract(x[skipped,:,:,:])
      C[i,Base.axes(components)...] = components

      next!(progress)
    end
  end

  MetaArray(params,C)
end

function mask(cr::AbstractArray{T},C::Coherence) where T
  if size(C,4) != 1
    error("Please select one component (see documentation for `component`).")
  end
  @assert axisdim(cr,Axis{:time}) == 1
  @assert axisdim(cr,Axis{:rate}) == 2
  @assert size(cr)[3:4] == size(C)[2:3] "Dimension mismatch"

  windows = enumerate(windowing(cr,getmeta(C)))
  y = zeros(Array(cr))
  norm = similar(y,real(T))
  norm .= zero(real(T))
  @showprogress "Masking: " for (i,w_inds) in windows
    c = C[Axis{:time}(i)]
    y[Axis{:time}(w_inds)] .+= reshape(c,1,1,size(c)...)
    norm[Axis{:time}(w_inds)] += 1
  end
  y ./= norm
  y ./= maximum(abs,y)
  y .= sqrt.(abs.(cr) .* y) .* exp.(angle.(cr).*im)

  cortical(y,getmeta(cr))
end

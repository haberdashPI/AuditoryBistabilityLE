export bistable_model, as_namedtuple

function checkparams(params)
  checkunits(params,s,:Δt)
  checkunits(params,Hz,:f)

  checkunits(params,s,:f_τ_σ)
  checkunits(params,s,:f_τ_m)
  checkunits(params,s,:f_τ_a)
  checkunits(params,s,:f_τ_x)

  checkunits(params,s,:s_τ_σ)
  checkunits(params,s,:s_τ_m)
  checkunits(params,s,:s_τ_a)
  checkunits(params,s,:s_τ_x)

  checkunits(params,s,:t_τ_σ)
  checkunits(params,s,:t_τ_m)
  checkunits(params,s,:t_τ_a)
  checkunits(params,s,:t_τ_x)
end

function bistable_model(params,settings;kwds...)
  settings = read_settings(settings)
  params = read_params(params)
  checkparams(params)

  bistable_model(audiospect_stimulus(params,settings,cache=true),
                 params,settings;kwds...)
end

function bistable_model(stim::AbstractVector,params,settings;interactive=false,
                        progressbar=interactive,
                        intermediate_results=interactive)
  settings = read_settings(settings)
  spect = audiospect(stim,progressbar=progressbar; settings.freqs.analyze...)
  bistable_model(spect,params,settings;progressbar=progressbar,
                 intermediate_results=intermediate_results)
end

function bistable_model(spect::ShammaModel.AuditorySpectrogram,params,settings;
                        interactive=false,
                        progressbar=interactive,
                        intermediate_results=interactive)
  settings = read_settings(settings)
  checkparams(params)

  # auditory spectrogram
  spectat = apply_bistable(spect,:freqs,params,progressbar=progressbar,
                           intermediate_results=intermediate_results;
                           settings.freqs.bistable...)
  specta = spectat.result

  # cortical scales
  cs = cortical(specta, progressbar=progressbar; settings.scales.analyze...)
  csclean = cortical(spect, progressbar=progressbar; settings.scales.analyze...)
  csat = apply_bistable(cs,:scales,params,progressbar=progressbar,
                        intermediate_results=intermediate_results;
                        settings.scales.bistable...)

  # cortical rates
  csa = csat.result
  crs = cortical(csa, progressbar=progressbar; settings.rates...)

  # temporal coherence (simultaneous grouping)
  C = cohere(crs, method=:nmf, progressbar=progressbar;
             settings.nmf...)

  # source tracking (sequential grouping)
  tracks,track_lp = track(C, method=:multi_prior, progressbar=progressbar;
                          settings.track.analyze...)

  track_lp_at = apply_bistable!(track_lp,:track,params,
                               progressbar=progressbar,
                               intermediate_results=intermediate_results;
                               settings.track.bistable...)
  track_lp = track_lp_at.result

  # compute the mask for the primary source
  startHz, stopHz = settings.rates.freq_limits_Hz.*Hz
  crmask = mask(csclean[:,:,startHz .. stopHz],tracks,track_lp;settings.mask...)
  spmask = audiospect(crmask,progressbar=progressbar)

  # compute the ratio of the mask's and the scene's bandwidth
  ratio,sband,tband = bandwidth_ratio(spmask, spect[:,startHz .. stopHz]; 
                                      settings.bandwidth_ratio...)

  if intermediate_results
    (percepts=(ratio=ratio,sband=sband,tband=tband,
               counts=percept_lengths(ratio,settings)),
     primary_source=spmask,
     sources=merge((tracks=tracks,),track_lp_at),
     cohere=C,
     cortical=csat,
     spect=spectat,
     input=spect)
  else
    (percepts=(ratio=ratio,counts=percept_lengths(ratio,settings)),
     primary_source=spmask)
  end
end


#############################################
#############################################
# Unified plot function for single comparison
# Returns reference differences + sort difference for plotting in R
#
# Replaces: TTEST_plot, TTESTA_plot, TTESTAB_plot, TTESTB_plot

function TTEST_plot(SL, SR, RL, RR; absolute::Bool=false, yeojohnson::Bool=false)
	res = zeros(1,size(SL,2))
	dsum = 0
	for g in 1:size(SL,2)
		if SL[g] != 0 && SR[g] != 0
			if absolute
				dsum += abs(SL[g] - SR[g])
			else
				dsum += (SL[g] - SR[g])
			end
			res[g] = 1
		end
	end
	res = res[1,1:end]
	ref = ref_dif(res, RL, RR, absolute=absolute)
	if yeojohnson
		bc = lambda(ref)[1]
		ref = transform(ref, bc)
		dsum = transform([dsum, dsum], bc)[1]
	end
	results = zeros(size(ref,1)+1,1)
	results[1:size(ref,1),1] = ref
	results[size(ref,1)+1,1] = dsum
	return results
end



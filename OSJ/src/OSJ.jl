module OSJ

# Osteometric sorting: comparing skeletal measurements of case specimens
# against reference populations to see which bones could belong together.

using Statistics
using Rmath
using Optim

include("yeojohnson.jl")   # the Yeo-Johnson transformation
include("core.jl")         # the comparisons themselves, on matrices
include("data.jl")         # reference groups and case tables
include("prepare.jl")      # choosing and aligning rows for an analysis
include("analysis.jl")     # running the comparisons and labelling the results

export BoneTable, ReferenceGroup, SortTable
export Settings, AnalysisResult
export available_measurements, articulation_pairs
export prepare_pair_match, prepare_articulation, prepare_regression
export prepare_single_pair_match, prepare_single_articulation, prepare_single_regression
export ttest, regression_test
export compare_pairs, compare_regression

end # module OSJ

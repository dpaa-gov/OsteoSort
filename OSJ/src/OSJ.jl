module OSJ

#pulls depends into scope
using Statistics
using GLM
using Rmath
using Optim

#include osteometric sorting code
include("t_test.jl")
include("t_test_cache.jl")
include("t_test_plot.jl")
include("yeojohnson.jl")
include("regression.jl")
include("regression_helpers.jl")
include("regression_plot.jl")

#export function calls
export TTEST
export TTEST_plot
export REGSL
export REGSL_plot

#C-ABI wrappers for shared library builds
include("c_api.jl")

end # module OSJ

# The Yeo-Johnson transformation: a power transformation that brings skewed
# values closer to a normal distribution and, unlike Box-Cox, accepts zero and
# negative values.

# One value, for a given parameter λ
yeo_johnson(x::Real, λ) =
    x >= 0 ? (λ ≈ 0 ? log(x + 1) : ((x + 1)^λ - 1) / λ) :
             (λ ≈ 2 ? -log(-x + 1) : -((-x + 1)^(2 - λ) - 1) / (2 - λ))

# A set of values
transform(𝐱, λ) = Float64[yeo_johnson(x, λ) for x in 𝐱]

# The λ that makes the transformed values most nearly normal, found by
# maximising the log-likelihood over the interval. Returns the value and the
# optimiser's report.
function lambda(𝐱; interval = (-2.0, 2.0), optim_args...)
    i1, i2 = interval
    res = optimize(λ -> -log_likelihood(𝐱, λ), i1, i2; optim_args...)
    (value=Optim.minimizer(res), details=res)
end

function log_likelihood(𝐱, λ)
    N = length(𝐱)
    𝐲 = transform(float.(𝐱), λ)
    σ² = var(𝐲, corrected = false)
    c = sum(sign.(𝐱) .* log.(abs.(𝐱) .+ 1))
    llf = -N / 2.0 * log(σ²) + (λ - 1) * c
    llf
end

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
# maximising the log-likelihood over the interval.
function lambda(𝐱; interval = (-2.0, 2.0))
    i1, i2 = interval
    (value = brent_minimizer(λ -> -log_likelihood(𝐱, λ), Float64(i1), Float64(i2)),)
end

# Where `f` is least between `x_lower` and `x_upper`, by Brent's method: golden
# section steps, and parabolic ones where they can be trusted. This is Optim's
# `optimize(f, x_lower, x_upper)` (Optim 1.13.3, src/univariate/solvers/brent.jl)
# with its defaults, statement for statement, so that λ is the same to the
# last digit; its tracing and time limit are left out. Optim, which OSJ used
# for this alone, cannot be built trimmed.
function brent_minimizer(f::F, x_lower::Float64, x_upper::Float64;
                         rel_tol::Float64 = sqrt(eps(Float64)), abs_tol::Float64 = eps(Float64),
                         iterations::Int = 1_000)::Float64 where {F}
    x_lower > x_upper && error("x_lower must be less than x_upper")
    golden_ratio = 1.0 / 2 * (3 - sqrt(5.0))

    new_minimizer = x_lower + golden_ratio * (x_upper - x_lower)
    new_minimum = Float64(f(new_minimizer))
    step = 0.0
    old_step = 0.0
    old_minimizer = new_minimizer
    old_old_minimizer = new_minimizer
    old_minimum = new_minimum
    old_old_minimum = new_minimum

    iteration = 0
    while iteration < iterations
        p = 0.0
        q = 0.0
        x_tol = rel_tol * abs(new_minimizer) + abs_tol
        x_midpoint = (x_upper + x_lower) / 2
        abs(new_minimizer - x_midpoint) <= 2 * x_tol - (x_upper - x_lower) / 2 && break
        iteration += 1

        if abs(old_step) > x_tol
            # Parabola interpolation: new_minimizer + p/q is the parabola's
            # optimum, and q is made positive
            r = (new_minimizer - old_minimizer) * (new_minimum - old_old_minimum)
            q = (new_minimizer - old_old_minimizer) * (new_minimum - old_minimum)
            p = (new_minimizer - old_old_minimizer) * q - (new_minimizer - old_minimizer) * r
            q = 2(q - r)
            if q > 0
                p = -p
            else
                q = -q
            end
        end

        if abs(p) < abs(q * old_step / 2) && p < q * (x_upper - new_minimizer) && p < q * (new_minimizer - x_lower)
            old_step = step
            step = p / q
            # f is not to be evaluated too close to x_upper or x_lower
            x_temp = new_minimizer + step
            if (x_temp - x_lower) < 2 * x_tol || (x_upper - x_temp) < 2 * x_tol
                step = (new_minimizer < x_midpoint) ? x_tol : -x_tol
            end
        else
            old_step = (new_minimizer < x_midpoint) ? x_upper - new_minimizer : x_lower - new_minimizer
            step = golden_ratio * old_step
        end

        # nor too close to new_minimizer
        new_x = abs(step) >= x_tol ? new_minimizer + step : new_minimizer + ((step > 0) ? x_tol : -x_tol)
        new_f = Float64(f(new_x))

        if new_f < new_minimum
            if new_x < new_minimizer
                x_upper = new_minimizer
            else
                x_lower = new_minimizer
            end
            old_old_minimizer = old_minimizer
            old_old_minimum = old_minimum
            old_minimizer = new_minimizer
            old_minimum = new_minimum
            new_minimizer = new_x
            new_minimum = new_f
        else
            if new_x < new_minimizer
                x_lower = new_x
            else
                x_upper = new_x
            end
            if new_f <= old_minimum || old_minimizer == new_minimizer
                old_old_minimizer = old_minimizer
                old_old_minimum = old_minimum
                old_minimizer = new_x
                old_minimum = new_f
            elseif new_f <= old_old_minimum || old_old_minimizer == new_minimizer || old_old_minimizer == old_minimizer
                old_old_minimizer = new_x
                old_old_minimum = new_f
            end
        end
    end
    return new_minimizer
end

function log_likelihood(𝐱, λ)
    N = length(𝐱)
    𝐲 = transform(float.(𝐱), λ)
    σ² = var(𝐲, corrected = false)
    c = sum(sign.(𝐱) .* log.(abs.(𝐱) .+ 1))
    llf = -N / 2.0 * log(σ²) + (λ - 1) * c
    llf
end

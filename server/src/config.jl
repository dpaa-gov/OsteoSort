# Runtime configuration. Everything comes from the environment so the same
# image runs locally and under Atlas, which injects the DB_* variables.

const REPO_ROOT = dirname(pkgdir(@__MODULE__))

struct Config
    db_host::String
    db_port::Int
    db_name::String
    db_user::String
    db_pass::String
    port::Int
    reference_max_age_seconds::Int
    web_dir::String
    config_dir::String
    version::String
end

function env_int(env, name, default)
    value = tryparse(Int, get(env, name, ""))
    return value === nothing ? default : value
end

function read_version(path)
    isfile(path) || return "dev"
    return strip(readline(path))
end

function Config(env = ENV)
    missing_vars = [name for name in ("DB_NAME", "DB_USER", "DB_PASS") if isempty(get(env, name, ""))]
    isempty(missing_vars) ||
        error("Missing required database environment variables: " * join(missing_vars, ", "))
    return Config(
        get(env, "DB_HOST", "host.docker.internal"),
        env_int(env, "DB_PORT", 5432),
        env["DB_NAME"],
        env["DB_USER"],
        env["DB_PASS"],
        env_int(env, "PORT", 3838),
        env_int(env, "REFERENCE_MAX_AGE_SECONDS", 30),
        get(env, "OSTEOSORT_WEB_DIR", joinpath(REPO_ROOT, "web")),
        get(env, "OSTEOSORT_CONFIG_DIR", joinpath(pkgdir(@__MODULE__), "config")),
        read_version(get(env, "OSTEOSORT_VERSION_FILE", joinpath(REPO_ROOT, "VERSION"))),
    )
end

# libpq keyword/value string; values are quoted so any password survives.
conninfo_value(value) = "'" * replace(string(value), "\\" => "\\\\", "'" => "\\'") * "'"

function conninfo(config::Config)
    return join((
        "host=" * conninfo_value(config.db_host),
        "port=" * conninfo_value(config.db_port),
        "dbname=" * conninfo_value(config.db_name),
        "user=" * conninfo_value(config.db_user),
        "password=" * conninfo_value(config.db_pass),
        "connect_timeout='10'",
        # a query that stalls fails the reload, and the data already loaded stays in use
        "options='-c statement_timeout=15000'",
    ), " ")
end

# Single-column or two-column config files with a header row and no quoting.
function read_config_rows(path)
    lines = filter(!isempty, strip.(readlines(path)))
    return [String.(strip.(split(line, ","))) for line in lines[2:end]]
end

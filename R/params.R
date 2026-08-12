## Runtime parameter contract.
##
## Every input, output and option of a job is passed on the command line as a
## `--name value` pair (or `--name=value`).  Job scripts begin with
##
##     params <- BiocJobs::jobParams("<package>", "<job>")
##
## which locates the job's own specification, parses the command line against
## it, coerces types, applies defaults, and validates.  The script body is
## then plain analysis code reading `params$<name>`.

#' Parse and validate job parameters at runtime
#'
#' Called at the top of a job script.  Locates the job specification (from
#' the installed host package, or from the `BIOCJOBS_SPEC` environment
#' variable during development and `runJob()`), parses `--name value`
#' command-line arguments against it, coerces option types, applies defaults,
#' and checks that required inputs exist on disk.
#'
#' Output parameters that are not supplied default to `<name>.<extension>`
#' in the current working directory; parent directories of supplied output
#' paths are created.
#'
#' @param package Name of the host package (e.g. `"DESeq2"`).
#' @param job Job name as declared in the specification.
#' @param args Command-line arguments; defaults to
#'   `commandArgs(trailingOnly = TRUE)`.
#' @return A named list with one element per declared input (path), output
#'   (path) and option (typed value).  The specification is attached as
#'   attribute `"job"`.
#' @export
jobParams <- function(package, job,
                      args = commandArgs(trailingOnly = TRUE)) {
    spec <- .locateSpec(package, job)
    parsed <- .parseArgv(args)

    ## A value like '{{options.contrast_factor}}' means a TES task template
    ## was submitted without being filled in; fail loudly and early.
    unfilled <- vapply(parsed, function(v)
        grepl("^\\{\\{.*\\}\\}$", v), NA)
    if (any(unfilled))
        stop("unfilled template placeholder(s): ",
             paste0("--", names(parsed)[unfilled], " ",
                    unlist(parsed[unfilled]), collapse = ", "),
             "\nthis task was generated as a template; supply real values ",
             "before submission")

    declared <- c(
        vapply(spec$inputs, `[[`, "", "name"),
        vapply(spec$outputs, `[[`, "", "name"),
        vapply(spec$options, `[[`, "", "name")
    )
    unknown <- setdiff(names(parsed), declared)
    if (length(unknown))
        stop("unknown parameter(s): ",
             paste0("--", unknown, collapse = ", "),
             "\ndeclared parameters: ",
             paste0("--", declared, collapse = ", "))

    params <- list()

    for (e in spec$inputs) {
        value <- parsed[[e$name]]
        if (is.null(value)) {
            if (!isFALSE(e$required))    # inputs are required by default
                stop("missing required input --", e$name)
            params[e$name] <- list(NULL)
            next
        }
        if (!file.exists(value))
            stop("input --", e$name, ": file not found: ", value)
        params[[e$name]] <- value
    }

    for (e in spec$outputs) {
        value <- parsed[[e$name]] %||% .defaultFileName(e$name, e$format)
        dir <- dirname(value)
        if (nzchar(dir) && !dir.exists(dir))
            dir.create(dir, recursive = TRUE)
        params[[e$name]] <- value
    }

    for (o in spec$options) {
        raw <- parsed[[o$name]]
        if (is.null(raw)) {
            if (isTRUE(o$required))
                stop("missing required option --", o$name)
            raw <- o$default
        }
        params[[o$name]] <- .coerceValue(raw, o)
    }

    attr(params, "job") <- spec
    params
}

## Locate a job spec at runtime: BIOCJOBS_SPEC override first (development,
## runJob()), then the installed package.
.locateSpec <- function(package, job) {
    override_note <- ""
    override <- Sys.getenv("BIOCJOBS_SPEC", "")
    if (nzchar(override)) {
        spec <- readJob(override)
        if (identical(spec$name, job) && identical(spec$package, package))
            return(spec)
        ## Override points elsewhere; fall through to the installed package,
        ## but say so if that fails too.
        override_note <- paste0("\n(BIOCJOBS_SPEC was set to '", override,
                                "', which declares job '", spec$name,
                                "' of package '", spec$package,
                                "' and did not match)")
    }
    dir <- system.file("biocjobs", package = package)
    if (!nzchar(dir))
        stop("package '", package, "' is not installed or ships no ",
             "biocjobs/ directory; during development set BIOCJOBS_SPEC to ",
             "the YAML path", override_note)
    for (ext in c(".yaml", ".yml")) {
        path <- file.path(dir, paste0(job, ext))
        if (file.exists(path))
            return(readJob(path))
    }
    stop("job '", job, "' not found in package '", package, "'",
         override_note)
}

## Parse --name value / --name=value pairs into a named character list.
.parseArgv <- function(args) {
    out <- list()
    i <- 1L
    while (i <= length(args)) {
        arg <- args[[i]]
        if (!startsWith(arg, "--"))
            stop("unexpected argument '", arg,
                 "'; expected --name value pairs")
        if (grepl("=", arg, fixed = TRUE)) {
            key <- sub("^--([^=]+)=.*$", "\\1", arg)
            value <- sub("^--[^=]+=", "", arg)
            i <- i + 1L
        } else {
            key <- substring(arg, 3L)
            if (i == length(args))
                stop("option --", key, " is missing a value")
            value <- args[[i + 1L]]
            i <- i + 2L
        }
        if (!nzchar(key))
            stop("malformed argument '", arg, "'")
        if (!is.null(out[[key]]))
            stop("parameter --", key, " supplied more than once")
        out[[key]] <- value
    }
    out
}

## Coerce a raw (character or YAML-typed) value according to an option
## declaration.  Used both at runtime and to type-check spec defaults.
.coerceValue <- function(value, option) {
    if (is.null(value))
        return(NULL)
    type <- option$type
    if (identical(type, "boolean")) {
        v <- tolower(as.character(value))
        if (v %in% c("true", "yes", "1"))  return(TRUE)
        if (v %in% c("false", "no", "0"))  return(FALSE)
        stop("option --", option$name, ": expected a boolean, got '",
             value, "'")
    }
    if (identical(type, "integer")) {
        v <- suppressWarnings(as.numeric(value))
        if (is.na(v) || v != trunc(v))
            stop("option --", option$name, ": expected an integer, got '",
                 value, "'")
        if (abs(v) > .Machine$integer.max)
            stop("option --", option$name, ": ", value,
                 " exceeds the integer range (max ", .Machine$integer.max,
                 ")")
        return(as.integer(v))
    }
    if (identical(type, "float")) {
        v <- suppressWarnings(as.numeric(value))
        if (is.na(v))
            stop("option --", option$name, ": expected a number, got '",
                 value, "'")
        return(v)
    }
    if (identical(type, "choice")) {
        v <- as.character(value)
        choices <- as.character(option$choices)
        if (!v %in% choices)
            stop("option --", option$name, ": '", v,
                 "' is not one of: ", paste(choices, collapse = ", "))
        return(v)
    }
    as.character(value)
}

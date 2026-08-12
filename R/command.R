## The canonical invocation.
##
## Every execution target (local run, TES task, Galaxy wrapper) launches a
## job with the same self-locating command:
##
##     Rscript -e 'BiocJobs::execJob("<package>", "<job>")' --name value ...
##
## `execJob()` resolves the job script inside the *installed* host package
## and sources it; the script's own `jobParams()` call then parses the
## trailing arguments.  No absolute paths ever appear in generated artifacts.

#' Execute a job from an installed package
#'
#' The canonical entry point used by generated TES tasks and Galaxy wrappers.
#' Locates the job's script inside the installed host package and runs it.
#' Command-line arguments after the `-e` expression are consumed by the
#' script's `jobParams()` call.
#'
#' @param package Name of the installed host package.
#' @param job Job name as declared in the specification.
#' @return Invisibly, the value of the sourced script.
#' @export
execJob <- function(package, job) {
    spec <- .locateSpec(package, job)
    script <- jobScript(spec)
    ## Let jobParams() inside the script resolve the same spec even when the
    ## override mechanism was used to find it; restore the caller's value.
    previous <- Sys.getenv("BIOCJOBS_SPEC", unset = NA)
    Sys.setenv(BIOCJOBS_SPEC = spec[["_path"]])
    on.exit(
        if (is.na(previous)) Sys.unsetenv("BIOCJOBS_SPEC")
        else Sys.setenv(BIOCJOBS_SPEC = previous),
        add = TRUE)
    message("BiocJobs: running ", package, "/", job, " (", script, ")")
    invisible(source(script, echo = FALSE, local = new.env(parent = globalenv())))
}

#' Build the command line for a job
#'
#' Returns the argv vector that launches a job with the given parameter
#' values.  This single builder is used by `runJob()` and by the TES
#' generator, so all execution paths stay in lockstep.
#'
#' @param job A `BiocJob` object.
#' @param params Named list or character vector of parameter values
#'   (inputs as paths/placeholders, outputs as paths, options as values).
#' @param rscript Path or name of the `Rscript` executable.
#' @return Character vector: the full argv, element one the executable.
#' @export
jobCommand <- function(job, params = list(), rscript = "Rscript") {
    stopifnot(inherits(job, "BiocJob"))
    expr <- sprintf('BiocJobs::execJob("%s", "%s")', job$package, job$name)
    argv <- c(rscript, "-e", expr)
    for (name in names(params)) {
        value <- params[[name]]
        if (is.null(value))
            next
        if (isTRUE(value))  value <- "true"
        if (isFALSE(value)) value <- "false"
        argv <- c(argv, paste0("--", name), as.character(value))
    }
    argv
}

#' Run a job locally
#'
#' Runs a job in a fresh `Rscript` process, without requiring the host
#' package's jobs to be installed: the specification path is passed to the
#' child process via the `BIOCJOBS_SPEC` environment variable, so a job can
#' be exercised straight from a package source checkout.
#'
#' @param job A `BiocJob` object, or path to a job YAML file.
#' @param params Named list of parameter values (see `jobCommand()`).
#' @param workdir Working directory for the run (created if needed);
#'   defaults to a fresh temporary directory.  Relative output paths land
#'   here.
#' @param rscript Path or name of the `Rscript` executable.
#' @return Invisibly, a list with `status` (exit code), `workdir`, and
#'   `outputs` (named vector of absolute paths to declared outputs).
#' @export
runJob <- function(job, params = list(), workdir = tempfile("biocjob_"),
                   rscript = "Rscript") {
    if (is.character(job))
        job <- readJob(job)
    stopifnot(inherits(job, "BiocJob"))
    if (!dir.exists(workdir))
        dir.create(workdir, recursive = TRUE)

    ## Make relative input paths survive the working-directory change.
    for (e in job$inputs) {
        v <- params[[e$name]]
        if (!is.null(v) && file.exists(v))
            params[[e$name]] <- normalizePath(v)
    }

    ## Run the script directly (not via execJob) so an uninstalled source
    ## checkout works; jobParams() picks the spec up from the environment.
    script <- jobScript(job)
    argv <- character()
    for (name in names(params)) {
        value <- params[[name]]
        if (is.null(value))
            next
        if (isTRUE(value))  value <- "true"
        if (isFALSE(value)) value <- "false"
        argv <- c(argv, paste0("--", name), as.character(value))
    }

    owd <- setwd(workdir)
    on.exit(setwd(owd), add = TRUE)
    status <- system2(rscript, c(shQuote(script), shQuote(argv)),
                      env = paste0("BIOCJOBS_SPEC=",
                                   shQuote(job[["_path"]])))

    outputs <- vapply(job$outputs, function(e) {
        path <- params[[e$name]] %||% .defaultFileName(e$name, e$format)
        if (!file.exists(path)) NA_character_ else normalizePath(path)
    }, "")
    names(outputs) <- vapply(job$outputs, `[[`, "", "name")

    if (!identical(status, 0L))
        warning("job exited with status ", status)
    missing <- names(outputs)[is.na(outputs)]
    if (length(missing))
        warning("declared output(s) not produced: ",
                paste(missing, collapse = ", "))

    invisible(list(status = status, workdir = normalizePath(workdir),
                   outputs = outputs))
}

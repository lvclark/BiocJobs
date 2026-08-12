## Command-line interface for automation.
##
## Everything the framework does is reachable from a shell, so build
## infrastructure needs nothing but:
##
##     Rscript -e 'BiocJobs::biocjobsCLI()' <command> <pkg> [job] [options]

.CLI_USAGE <- "
BiocJobs command line interface

usage:
  Rscript -e 'BiocJobs::biocjobsCLI()' <command> [arguments]

commands:
  list     <pkg>                       list jobs declared by a package
  validate <pkg>                       validate all job specs (exit 1 on error)
  manifest <pkg> [--out FILE]          write the package job manifest (JSON)
  tes      <pkg> <job> [--out FILE]    generate a TES task template (JSON)
  galaxy   <pkg> <job> [--out FILE]    generate a Galaxy tool wrapper (XML)
  run      <pkg> <job> [--workdir DIR] [--<param> <value> ...]
                                       run a job locally

<pkg> is a package source directory, an installed package directory, or an
installed package name.
"

#' BiocJobs command line interface
#'
#' Entry point for shell-driven use; see the package README for the command
#' reference.  Exits the R session with a non-zero status on failure when
#' run non-interactively.
#'
#' @param args Command-line arguments; defaults to
#'   `commandArgs(trailingOnly = TRUE)`.
#' @return Exits the process when non-interactive; otherwise returns
#'   invisibly.
#' @export
biocjobsCLI <- function(args = commandArgs(trailingOnly = TRUE)) {
    status <- tryCatch(.cliDispatch(args), error = function(e) {
        message("error: ", conditionMessage(e))
        1L
    })
    if (!interactive())
        quit(status = status, save = "no")
    invisible(status)
}

.cliDispatch <- function(args) {
    if (!length(args)) {
        message(.CLI_USAGE)
        return(1L)
    }
    command <- args[[1L]]
    rest <- args[-1L]

    if (command %in% c("help", "--help", "-h")) {
        message(.CLI_USAGE)
        return(0L)
    }
    if (!command %in% c("list", "validate", "manifest", "tes", "galaxy",
                        "run"))
        stop("unknown command '", command, "'")
    if (!length(rest))
        stop("command '", command, "' needs a package argument")

    pkg <- rest[[1L]]
    rest <- rest[-1L]

    switch(
        command,
        list = {
            jobs <- findJobs(pkg)
            if (!length(jobs)) {
                message("no jobs declared")
            } else {
                for (job in jobs) print(job)
            }
            0L
        },
        validate = {
            jobs <- findJobs(pkg, validate = FALSE)
            if (!length(jobs))
                message("no jobs declared")
            n_err <- 0L
            for (job in jobs) {
                issues <- validateJob(job)
                for (i in issues) {
                    message(job$name %||% "?", ": ", i$severity, ": ",
                            i$message)
                    if (identical(i$severity, "error"))
                        n_err <- n_err + 1L
                }
            }
            if (n_err) {
                message(n_err, " error(s)")
                1L
            } else {
                message("all job specifications valid")
                0L
            }
        },
        manifest = {
            opts <- .parseArgv(rest)
            out <- opts$out
            manifest <- jobManifest(pkg, file = out)
            if (is.null(out))
                cat(jsonlite::toJSON(unclass(manifest), auto_unbox = TRUE,
                                     pretty = TRUE), "\n")
            else message("wrote ", out)
            0L
        },
        tes = ,
        galaxy = {
            if (!length(rest))
                stop("command '", command, "' needs a job name")
            jobname <- rest[[1L]]
            opts <- .parseArgv(rest[-1L])
            job <- .cliFindJob(pkg, jobname)
            if (identical(command, "tes")) {
                task <- tesTask(job)
                json <- writeTesTask(task, file = opts$out)
                if (is.null(opts$out)) cat(json, "\n")
                else message("wrote ", opts$out)
            } else {
                doc <- galaxyTool(job)
                out <- opts$out %||% paste0(.galaxyToolId(job), ".xml")
                writeGalaxyTool(doc, out, job = job)
                message("wrote ", out)
            }
            0L
        },
        run = {
            if (!length(rest))
                stop("command 'run' needs a job name")
            jobname <- rest[[1L]]
            opts <- .parseArgv(rest[-1L])
            job <- .cliFindJob(pkg, jobname)
            workdir <- opts$workdir %||% tempfile("biocjob_")
            opts$workdir <- NULL
            result <- runJob(job, params = opts, workdir = workdir)
            message("workdir: ", result$workdir)
            for (name in names(result$outputs))
                message("output ", name, ": ", result$outputs[[name]])
            if (identical(result$status, 0L)) 0L else 1L
        }
    )
}

.cliFindJob <- function(pkg, jobname) {
    jobs <- findJobs(pkg)
    job <- jobs[[jobname]]
    if (is.null(job))
        stop("job '", jobname, "' not found in ", pkg,
             if (length(jobs)) paste0("; available: ",
                                      paste(names(jobs), collapse = ", "))
             else "; the package declares no jobs")
    job
}

#FIXME: check whether optimization can be paralleized if req. by user

#' @title Hyperparameter tuning.
#'
#' @description
#' Optimizes the hyperparameters of a learner.
#' Allows for different optimization methods, such as grid search, evolutionary strategies,
#' iterated F-race, etc. You can select such an algorithm (and its settings)
#' by passing a corresponding control object. For a complete list of implemented algorithms look at
#' \code{\link{TuneControl}}.
#'
#' Multi-criteria tuning can be done with \code{\link{tuneParamsMultiCrit}}.
#'
#' @template arg_learner
#' @template arg_task
#' @param resampling [\code{\link{ResampleInstance}} | \code{\link{ResampleDesc}}]\cr
#'   Resampling strategy to evaluate points in hyperparameter space. If you pass a description,
#'   it is instantiated once at the beginning by default, so all points are
#'   evaluated on the same training/test sets.
#'   If you want to change that behavior, look at \code{\link{TuneControl}}.
#' @template arg_measures_opt
#' @param par.set [\code{\link[ParamHelpers]{ParamSet}}]\cr
#'   Collection of parameters and their constraints for optimization.
#'   Dependent parameters with a \code{requires} field must use \code{quote} and not
#'   \code{expression} to define it.
#' @param control [\code{\link{TuneControl}}]\cr
#'   Control object for search method. Also selects the optimization algorithm for tuning.
#' @template arg_showinfo
#' @param resample.fun [\code{closure}]\cr
#'   The function to use for resampling. Defaults to \code{\link{resample}}. If a user-given function
#'   is to be used instead, it should take the arguments \dQuote{learner}, \dQuote{task}, \dQuote{resampling},
#'   \dQuote{measures}, and \dQuote{show.info}; see \code{\link{resample}}. Within this function,
#'   it is easiest to call \code{\link{resample}} and possibly modify the result.
#'   However, it is possible to return a list with only the following essential slots:
#'   the \dQuote{aggr} slot for general tuning, additionally the \dQuote{pred} slot if threshold tuning is performed
#'   (see \code{\link{TuneControl}}), and the \dQuote{err.msgs} and \dQuote{err.dumps} slots for error reporting.
#'   This parameter must be the default when \code{mbo} tuning is performed.
#' @return [\code{\link{TuneResult}}].
#' @family tune
#' @note If you would like to include results from the training data set, make
#' sure to appropriately adjust the resampling strategy and the aggregation for
#' the measure. See example code below.
#' @export
#' @examples
#' # a grid search for an SVM (with a tiny number of points...)
#' # note how easily we can optimize on a log-scale
#' ps = makeParamSet(
#'   makeNumericParam("C", lower = -12, upper = 12, trafo = function(x) 2^x),
#'   makeNumericParam("sigma", lower = -12, upper = 12, trafo = function(x) 2^x)
#' )
#' ctrl = makeTuneControlGrid(resolution = 2L)
#' rdesc = makeResampleDesc("CV", iters = 2L)
#' res = tuneParams("classif.ksvm", iris.task, rdesc, par.set = ps, control = ctrl)
#' print(res)
#' # access data for all evaluated points
#' print(head(as.data.frame(res$opt.path)))
#' print(head(as.data.frame(res$opt.path, trafo = TRUE)))
#' # access data for all evaluated points - alternative
#' print(head(generateHyperParsEffectData(res)))
#' print(head(generateHyperParsEffectData(res, trafo = TRUE)))
#'
#' \dontrun{
#' # we optimize the SVM over 3 kernels simultanously
#' # note how we use dependent params (requires = ...) and iterated F-racing here
#' ps = makeParamSet(
#'   makeNumericParam("C", lower = -12, upper = 12, trafo = function(x) 2^x),
#'   makeDiscreteParam("kernel", values = c("vanilladot", "polydot", "rbfdot")),
#'   makeNumericParam("sigma", lower = -12, upper = 12, trafo = function(x) 2^x,
#'     requires = quote(kernel == "rbfdot")),
#'   makeIntegerParam("degree", lower = 2L, upper = 5L,
#'     requires = quote(kernel == "polydot"))
#' )
#' print(ps)
#' ctrl = makeTuneControlIrace(maxExperiments = 5, nbIterations = 1, minNbSurvival = 1)
#' rdesc = makeResampleDesc("Holdout")
#' res = tuneParams("classif.ksvm", iris.task, rdesc, par.set = ps, control = ctrl)
#' print(res)
#' print(head(as.data.frame(res$opt.path)))
#'
#' # include the training set performance as well
#' rdesc = makeResampleDesc("Holdout", predict = "both")
#' res = tuneParams("classif.ksvm", iris.task, rdesc, par.set = ps,
#'   control = ctrl, measures = list(mmce, setAggregation(mmce, train.mean)))
#' print(res)
#' print(head(as.data.frame(res$opt.path)))
#' }
#' @seealso \code{\link{generateHyperParsEffectData}}
tuneParams = function(learner, task, resampling, measures, par.set, control, show.info = getMlrOption("show.info"), resample.fun = resample) {
  learner = checkLearner(learner)
  assertClass(task, classes = "Task")
  measures = checkMeasures(measures, learner)
  assertClass(par.set, classes = "ParamSet")
  assertClass(control, classes = "TuneControl")
  assertFunction(resample.fun)
  if (!inherits(resampling, "ResampleDesc") &&  !inherits(resampling, "ResampleInstance"))
    stop("Argument resampling must be of class ResampleDesc or ResampleInstance!")
  if (inherits(resampling, "ResampleDesc") && control$same.resampling.instance)
    resampling = makeResampleInstance(resampling, task = task)
  assertFlag(show.info)
  checkTunerParset(learner, par.set, measures, control)
  control = setDefaultImputeVal(control, measures)

  cl = getClass1(control)
  sel.func = switch(cl,
    TuneControlRandom = tuneRandom,
    TuneControlGrid = tuneGrid,
    TuneControlDesign = tuneDesign,
    TuneControlCMAES = tuneCMAES,
    TuneControlGenSA = tuneGenSA,
    TuneControlMBO = tuneMBO,
    TuneControlIrace = tuneIrace,
    stopf("Tuning algorithm for '%s' does not exist!", cl)
  )

  need.extra = control$tune.threshold || getMlrOption("on.error.dump")
  opt.path = makeOptPathDFFromMeasures(par.set, measures, include.extra = need.extra)
  if (show.info) {
    messagef("[Tune] Started tuning learner %s for parameter set:", learner$id)
    message(printToChar(par.set))  # using message() since this can go over the char limit of messagef(), see issue #1528
    messagef("With control class: %s", cl)
    messagef("Imputation value: %g", control$impute.val)
  }
  or = sel.func(learner, task, resampling, measures, par.set, control, opt.path, show.info, resample.fun)
  if (show.info)
    messagef("[Tune] Result: %s : %s", paramValueToString(par.set, or$x), perfsToString(or$y))
  return(or)
}


#' @title Get the optimization path of a tuning result.
#'
#' @description
#' Returns the opt.path from a [\code{\link{TuneResult}}] object.
#' @param tune.result [\code{\link{TuneResult}}] \cr
#'   A tuning result of the [\code{\link{tuneParams}}] function.
#' @param as.df [\code{logical(1)}]\cr
#'   Should the optimization path be returned as a data frame?
#'   Default is \code{TRUE}.
#' @export
getTuneResultOptPath = function(tune.result, as.df = TRUE) {
  if (as.df == TRUE) {
    return(as.data.frame(tune.result$opt.path))
  } else {
    return(tune.result$opt.path)
  }
}

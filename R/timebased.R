#' Analyze each variable in respect to a time variable
#'
#' @param data_analyze a data frame to analyze
#' @param date_variable the variable (length one character vector or bare expression) that will be used to pivot all other variables
#' @param time_unit the time unit to use if not automatically
#' @param nvals_num_to_cat numeric numeric values with this many or fewer distinct values will be treated as categorical
#' @param outdir an optional output directory to save the resulting plots as png images
#'
#' @examples
#' library(xray)
#' data(longley)
#' longley$Year=as.Date(paste0(longley$Year,'-01-01'))
#' timebased(longley, 'Year')
#'
#' @export
#' @import dplyr
#' @import ggplot2
#' @importFrom grDevices boxplot.stats
#' @importFrom utils head
#' @importFrom stats quantile
#' @importFrom stats setNames
#' @importFrom utils setTxtProgressBar
#' @importFrom utils txtProgressBar
#'
timebased <- function(data_analyze, date_variable, time_unit="auto",
                      nvals_num_to_cat=2,outdir) {


  # Remove nulls
  data_analyze = filter(data_analyze, !is.na(!!date_variable))

  if(inherits(data_analyze, 'tbl_sql')){
    # Collect up to 100k samples
    print("Remote data source, collecting up to 100k sample rows")
    data_analyze = collect(data_analyze, n=100000)
  }

  # Obtain metadata for the dataset
  varMetadata = suppressWarnings(anomalies(data_analyze)$variables)

  dateData = pull(data_analyze, date_variable)

  if(inherits(dateData, 'POSIXct') || inherits(dateData, 'POSIXlt')){
    # Remove timezone
    attr(dateData, "tzone") <- "UTC"

  }else if(! inherits(dateData, 'Date')){
    # Not a Date nor a POSIXct/POSIXlt, what are you giving me?

    if(is.character(dateData) || is.factor(dateData)){ #Try to convert strings
      dateData = as.Date(as.character(dateData))
    }else{
      warning('You need to specify a date variable as the second parameter.')
      return()
    }
  }

  #Determine time unit
  if(time_unit == 'auto'){
    timeRange = as.double(difftime(max(dateData, na.rm=TRUE), min(dateData, na.rm=TRUE), units='secs'))
    min=60
    hour=min*60
    day=hour*24
    year=day*365
    time_unit = case_when(
      timeRange > year*2 ~ 'year',
      timeRange > day*35 ~ 'month',
      timeRange > hour*6 ~ 'hour',
      timeRange > min*10 ~ 'minute',
      TRUE ~ 'second'
    )
  }

  dateData=lubridate::floor_date(dateData, unit=time_unit)

  # Start rolling baby!
  i=0
  pb <- txtProgressBar(0, nrow(varMetadata)) # Progress bar
  resVars = c()
  results = foreach::foreach(i=seq_len(nrow(varMetadata))) %do% {
    var=varMetadata[i,]
    varName=as.character(var$Variable)
    setTxtProgressBar(pb, i)
    if(var$pNA=='100%'){
      #All null
      warning("The variable ", varName, " is completely NA, can't plot that.")
      return()
    }else if(var$Variable == quo_name(date_variable)) {
      #Do nothing when date var
      return()
    }else if(!var$type %in% c('Integer', 'Logical', 'Numeric', 'Factor', 'Character')){
      #Do not try to plot anything
      warning('Ignoring variable ', varName, ': Unsupported type for visualization.')
      return()
    }else{
      resVars=c(resVars,varName)

      if(var$type %in% c('Numeric','Integer') &
         var$qDistinct > nvals_num_to_cat){
        # Box plot for visualizing difference in distribution among time

        varAnalyze = data.frame(dat=as.double(data_analyze[[varName]]), date=as.factor(dateData))

        ylim1 = boxplot.stats(varAnalyze$dat)$stats[c(1, 5)]
        yrange = ylim1[2]-ylim1[1]

        ggplot(varAnalyze, aes(date, dat)) +
          geom_boxplot(fill='#ccccff', outlier.color = 'red', outlier.shape=1, na.rm=TRUE) +
          theme_minimal() +
          labs(x = varName, y = "Rows") +
          coord_cartesian(ylim = ylim1+c(-0.1*yrange,0.1*yrange)) +
          ggtitle(paste("Histogram of", var$Variable)) +
          theme(axis.text.x = element_text(angle = 45, hjust = 1))

      }else{
        # 100% stacked barchart showing difference in categorical composition
        varAnalyze = data.frame(dat=as.character(data_analyze[[varName]]), date=dateData)
        topvars = group_by(varAnalyze, dat) %>% count() %>% arrange(-n) %>% ungroup()
        topten=topvars
        if(nrow(topvars) > 10){
          topten=head(topvars, 10)
          warning("On variable ", varName, ", more than 10 distinct variables found, only using top 10 for visualization.")
          others = anti_join(varAnalyze, topten, by='dat') %>%
            group_by(date) %>% count() %>% ungroup() %>%
            mutate(dat='Others') %>% select(date, dat, n)
        }

        grouped = group_by(varAnalyze, date, dat) %>%
          semi_join(topten, by='dat') %>%
          count() %>% arrange(date, -n) %>% ungroup()

        if(nrow(topvars)>10){
          grouped = rbind(grouped, others)
        }

        abbr = function (x) {return (abbreviate(x, minlength = 10))}


        ggplot(grouped, aes(x=date, y=n, fill=dat)) +
          geom_bar(position='fill', stat='identity') +
          scale_y_continuous(labels = scales::percent_format()) +
          scale_fill_brewer(palette='Paired', label=abbr) +
          theme_minimal() +
          labs(x = var$Variable, y = "Rows", fill=varName) +
          ggtitle(paste("Evolution of variable", varName)) +
          theme(axis.text.x = element_text(angle = 45, hjust = 1))
      }
    }

  }
  close(pb)

  results[vapply(results, is.null, logical(1))] <- NULL
  batches = ceiling(length(results)/4)

  foreach::foreach(i=seq_len(batches)) %do% {
    firstPlot=((i-1)*4)+1
    lastPlot=min(firstPlot+3, length(results), na.rm=T)
    if(lastPlot==firstPlot){
      plot(results[[firstPlot]])
    }else{
      grid::grid.newpage()
      grid::pushViewport(grid::viewport(layout = grid::grid.layout(2,2)))

      row=1
      col=1
      for (j in firstPlot:lastPlot) {
        print(results[[j]], vp = grid::viewport(layout.pos.row = row,
                                                layout.pos.col = col))
        if(row==2){
          row=1
          col=col+1
        }else{
          row=row+1
        }
      }
    }
  }


  if(!missing(outdir)){
    foreach::foreach(i=seq_along(results)) %do% {
      ggsave(filename=file.path(outdir, paste0(gsub('[^a-z0-9 ]','_', tolower(resVars[[i]])), '.png')), plot=results[[i]])
    }
  }

  message(length(results), " charts have been generated.")
}

original<-getwd();sandbox<-tempfile();dir.create(sandbox)
invisible(file.copy(c('app.R','ui.R','classifier.R','project_helpers.R','project_server.R','sol_server.R','sol_config.json'),sandbox))
dir.create(file.path(sandbox,'www'));invisible(file.copy('www/app.css',file.path(sandbox,'www','app.css')));setwd(sandbox)
app<-source('app.R')$value
calls<-0L;downloads<-0L
read_analysis_image<-function(url) {downloads<<-downloads+1L;magick::image_blank(40,40,color='gray')}
fetch_salamander_batch<-function(place='',before=NULL,research_only=TRUE,taxon_id='27186') {
  calls<<-calls+1L
  if(identical(place,'999')) return(list(results=list()))
  ids<-if(is.null(before)) 401:202 else 201:200
  list(results=lapply(ids,function(id) list(id=id,quality_grade=if(research_only) 'research' else 'needs_id',location='42,-84',obscured=TRUE,place_guess='Fixture',observed_on='2026-10-22',user=list(login='fixture'),uri=paste0('https://www.inaturalist.org/observations/',id),photos=list(list(id=id+1000,url='https://example.com/x.jpg',attribution='Fixture')))))
}
shiny::testServer(app$serverFuncSource(),{
  finish_load<-function() {deadline<-Sys.time()+3;while(loading() && Sys.time()<deadline) {later::run_now(.2);session$flushReact()}}
  session$setInputs(region='29',research_only=TRUE,review_filter=c('red_backed','lead_backed','cant_tell','unclassified'),queue_filter='all',workspace='photos',photo_index='1')
  session$setInputs(fetch=1)
  stopifnot(calls==1,nrow(rows())==200,all(rows()$obscured))
  invisible(photo_data());stopifnot(downloads==1)
  finish_load()
  stopifnot(calls==2,nrow(rows())==202,!loading(),length(unique(rows()$id))==202)
  invisible(photo_data());stopifnot(downloads==1)
  snapshot<-data_file(file.path('observation-cache','27186_29_research.json'));stopifnot(file.exists(snapshot),isTRUE(read_saved(snapshot)$complete))
  session$setInputs(fetch=2);stopifnot(calls==2,nrow(rows())==202,grepl('saved region snapshot',load_status()))
  session$setInputs(refresh_observations=1);finish_load();stopifnot(calls==4,nrow(rows())==202)
  session$setInputs(region='999',refresh_observations=2);stopifnot(nrow(rows())==0,length(raw())==0,!loading())
  session$setInputs(region='29',research_only=FALSE,fetch=3);finish_load()
  stopifnot(nrow(rows())==202,all(rows()$quality_grade=='needs_id'),file.exists(data_file(file.path('observation-cache','27186_29_all-grades.json'))))
})
setwd(original);unlink(sandbox,recursive=TRUE)
cat('Loader checks passed: pagination, compact metadata, obscured locations, snapshot reuse, refresh, grade separation, empty regions and stable photo caching. No live API calls made.\n')

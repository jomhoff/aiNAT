job<-reactiveVal(NULL);job_state<-reactiveVal(list(state='idle',message='Ready. Choose a photo or prepare a classifier.'))
photo_zoom<-reactiveVal(1)
observeEvent(input$zoom_in,photo_zoom(min(5,photo_zoom()+.5)));observeEvent(input$zoom_out,photo_zoom(max(.5,photo_zoom()-.5)));observeEvent(input$zoom_reset,photo_zoom(1));observeEvent(list(selected(),input$photo_index),photo_zoom(1))
output$zoom_level<-renderText(sprintf('%.0f%%',100*photo_zoom()))
photo_data<-reactive({
  p<-current_photos();req(length(p)>0);i<-suppressWarnings(as.integer(input$photo_index));if(!length(i)||is.na(i)||i<1||i>length(p)) i<-1
  photo<-p[[i]];tryCatch({
    if(length(photo$image_path) && file.exists(photo$image_path)) img<-magick::image_read(photo$image_path) else {
      id<-as.character(photo$id);if(!grepl('^[0-9]+$',id)) stop('Invalid photo ID')
      saved<-data_file(file.path('annotations','images',paste0(id,'.png')));if(!file.exists(saved)) saved<-data_file(file.path('sol','images',paste0(id,'.png')))
      img<-if(file.exists(saved)) magick::image_read(saved) else read_analysis_image(sub('/square\\.','/large.',photo$url))
    };list(img=img,photo=photo,id=selected())
  },error=function(e) shiny::validate(shiny::need(FALSE,'Photo unavailable. Try another photo.')))
}) |> bindCache(project()$id,selected(),input$photo_index,cache='session')
output$analysis_image<-renderImage({d<-photo_data();path<-tempfile(fileext='.png');info<-magick::image_info(d$img);magick::image_write(d$img,path,format='png');list(src=path,contentType='image/png',width=round(info$width*photo_zoom()),height=round(info$height*photo_zoom()),alt='Species observation photo')},deleteFile=TRUE)
current_prediction<-reactive({hit<-Filter(function(o) identical(as.character(o$id),selected()),active_predictions());if(length(hit)) hit[[1]] else NULL})
output$current_ai<-renderUI({
  r<-current_prediction();if(is.null(r)) return(tagList(tags$h4('Sol identification'),tags$p(if(is.null(expected_config_id())) 'Prepare a classifier in Train & evaluate first.' else 'Ready to assess this observation.')))
  tagList(tags$h4(paste('Sol:',pretty_morph(r$ai_morph))),if(!is.null(r$confidence)) tags$span(class='score-chip',paste('Self-assessed score:',r$confidence,'/ 100')),if(r$raw_label!=r$ai_morph) tags$p(paste('Raw suggestion:',pretty_morph(r$raw_label),'· withheld by the acceptance policy.')),tags$p(r$reason),
    if(length(r$photos)>1) tags$details(tags$summary('Photo assessments'),lapply(r$photos,function(p) tags$p(paste(pretty_morph(p$morph),'—',p$reason)))))
})
output$ai_actions<-renderUI({d<-current();r<-current_prediction();j<-job();busy<-!is.null(j)&&!isTRUE(j$finished)
  button<-function(id,label,disabled,primary=FALSE) {a<-list(inputId=id,label=label,class=if(primary) 'btn-primary' else NULL);if(disabled) a$disabled<-'disabled';do.call(actionButton,a)}
  tagList(button('classify_selected','Identify with Sol',busy||!nrow(d)||d$manual_morph[1]!='unclassified'||is.null(expected_config_id()),TRUE),button('accept_ai','Confirm category',is.null(r)||!r$ai_morph %in% keys()))
})
observeEvent(input$accept_ai,{r<-current_prediction();if(!is.null(r)&&r$ai_morph %in% keys()) save_label(r$ai_morph,TRUE)})
queue<-reactive({
  excluded<-labels()$id[labels()$morph!='unclassified'];eligible<-all_records()$id;observations<-raw()
  ids<-vapply(observations,function(o) as.character(o$id),character(1));keep<-ids %in% eligible & !ids %in% excluded
  completed<-ai_results();index<-match(ids,vapply(completed,function(o) as.character(o$id),character(1)))
  for(i in which(keep & !is.na(index))) {
    old<-completed[[index[i]]]
    if(identical(old$config_id,expected_config_id())&&setequal(as.character(unlist(old$photo_ids)),vapply(selected_photos(observations[[i]]),function(p) as.character(p$id),character(1)))) keep[i]<-FALSE
  }
  observations[keep]
})
run_limits<-reactive({n<-suppressWarnings(as.integer(input$batch_limit));if(length(n)!=1||is.na(n)||n<1||n>10000) n<-100;cost<-suppressWarnings(as.numeric(input$cost_limit));if(length(cost)!=1||!is.finite(cost)||cost<=0||cost>100) cost<-2;list(n=n,cost=cost)})
output$batch_estimate<-renderText({q<-head(queue(),run_limits()$n);photos<-sum(vapply(q,function(o) length(selected_photos(o)),integer(1)));mult<-if(is.null(recipe())) 1 else 1+length(recipe()$examples);sprintf('%d eligible observations · %d photos. Rough estimate $%.2f; examples and token usage affect cost.',length(q),photos,photos*.528854/315*mult)})
key_version<-reactiveVal(0L)
output$key_status<-renderText({key_version();if(file.exists(api_key_path())||nzchar(Sys.getenv('OPENAI_API_KEY'))) 'Your API key is configured locally.' else 'Add your own OpenAI API key to use Sol.'})
photo_manifest<-function(o) list(id=as.character(o$id),photo_mode=photo_mode(),photos=lapply(selected_photos(o),function(p) {
  value<-list(id=as.character(p$id))
  if(length(p$image_path)) value$image_path<-normalizePath(p$image_path) else value$url<-sub('/square\\.','/large.',p$url)
  value
}))
start_job<-function(command,observations=list()) {
  j<-job();if(!is.null(j)&&j$process$is_alive()) stop('A job is already running. Stop it or wait before continuing.')
  if(command!='train' && !file.exists(api_key_path()) && !nzchar(Sys.getenv('OPENAI_API_KEY'))) stop('Set up your own API key first.')
  if(command %in% c('classify','evaluate') && is.null(expected_config_id())) stop('Train a classifier first.')
  if(command=='evaluate'&&legacy_mode()) stop('Build an example-taught classifier before evaluating confidence. The existing baseline has no confidence scores.')
  if(command=='classify'&&!length(observations)) stop('No eligible observations. Load a region with the selected quality filter or upload images.')
  python<-file.path(normalizePath('.venv',mustWork=FALSE),'bin','python');if(!file.exists(python)) stop('Run Setup.command first.')
  run<-tempfile(pattern='run-',tmpdir=data_dir());dir.create(run);status<-file.path(run,'status.json');stop_file<-file.path(run,'stop');input_file<-file.path(run,'queue.json')
  if(command=='train') {
    l<-labels();manifest<-lapply(Filter(function(o) as.character(o$id) %in% l$id[l$morph %in% keys()],raw()),function(o) {r<-photo_manifest(o);r$label<-l$morph[match(r$id,l$id)];r})
    counts<-table(factor(vapply(manifest,function(o) o$label,character(1)),levels=keys()));if(any(counts<5)) stop('Label at least 5 independent observations per category before training; aim for 50+.')
  } else manifest<-lapply(observations,photo_manifest)
  write_json(manifest,input_file);write_json(list(state='starting',message=paste('Starting',command,'…')),status)
  output_path<-if(command=='classify') prediction_path() else if(command=='train') run else dirname(project()$active_recipe)
  if(legacy_mode()&&command=='classify') {
    script<-'sol_classifier.py';args<-character()
  } else {
    script<-'project_model.py';args<-command
    if(command=='train') {settings<-file.path(run,'project.json');p<-project();p$photo_mode<-photo_mode();write_json(p,settings);args<-c(args,'--project',normalizePath(settings))}
    else args<-c(args,'--recipe',normalizePath(project()$active_recipe))
  }
  args<-c(args,'--input',normalizePath(input_file),'--output',normalizePath(output_path,mustWork=FALSE),'--status',normalizePath(status),'--stop-file',normalizePath(stop_file,mustWork=FALSE),'--budget',as.character(run_limits()$cost),'--data',normalizePath(data_dir()))
  process<-processx::process$new(python,c(normalizePath(script),args),stdout=file.path(run,'stdout.log'),stderr=file.path(run,'stderr.log'),cleanup_tree=TRUE)
  job(list(process=process,status=status,stop_file=stop_file,command=command,run_dir=run,project_id=project()$id,finished=FALSE));job_state(read_saved(status))
}
observeEvent(input$classify_selected,tryCatch({req(selected());d<-current();req(nrow(d)>0);if(d$manual_morph[1]!='unclassified') stop('Your label is already saved. Clear it before requesting a new assessment.');start_job('classify',Filter(function(o) identical(as.character(o$id),selected()),raw()))},error=function(e) showNotification(conditionMessage(e),type='error')))
observeEvent(input$classify_all,tryCatch(start_job('classify',head(queue(),run_limits()$n)),error=function(e) showNotification(conditionMessage(e),type='error')))
observeEvent(input$train_project,tryCatch({save_loaded();start_job('train')},error=function(e) showNotification(conditionMessage(e),type='error')))
observeEvent(input$evaluate_project,tryCatch(start_job('evaluate'),error=function(e) showNotification(conditionMessage(e),type='error')))
stop_job<-function() {j<-job();if(!is.null(j)&&j$process$is_alive()) {file.create(j$stop_file);s<-job_state();s$message<-'Stopping after in-flight requests finish…';job_state(s)}}
observeEvent(input$stop_batch,stop_job());observeEvent(input$stop_training,stop_job())
observe({invalidateLater(1000,session);j<-job();if(is.null(j)||isTRUE(j$finished)) return()
  state<-read_saved(j$status,NULL);if(!is.null(state)) job_state(state)
  if(j$command=='classify'&&file.exists(prediction_path())) {r<-read_saved(prediction_path(),NULL);if(!is.null(r)&&!identical(r,isolate(ai_results()))) ai_results(r)}
  if(!j$process$is_alive()) {
    if(!is.null(state)&&identical(state$state,'complete')&&j$command=='train') {p<-project();p$active_recipe<-normalizePath(file.path(j$run_dir,'recipe.json'));write_json(p,project_file(p$id));project(p);showNotification('Classifier prepared. Evaluate it before accepting automatic labels.',duration=8)}
    if(is.null(state)||!state$state %in% c('complete','stopped','error')) job_state(list(state='error',message='Job stopped unexpectedly. Completed answers remain saved.'))
    j$finished<-TRUE;job(j)
  }
})
output$batch_status<-renderText(job_state()$message)
output$job_progress<-renderUI({s<-job_state();if(is.null(s$total)||is.null(s$completed)||s$total<1) return(NULL);pct<-min(100,100*s$completed/s$total);tags$div(class='progress',tags$div(class='progress-bar',role='progressbar',style=paste0('width:',pct,'%;'),'aria-valuenow'=round(pct),'aria-valuemin'=0,'aria-valuemax'=100))})
results_table<-reactive({
  r<-active_predictions();l<-labels();eligible<-all_records()$id;if(length(raw())) r<-Filter(function(o) o$id %in% eligible,r)
  d<-if(!length(r)) data.frame(id=character(),ai_category=character(),raw_category=character(),score=numeric(),human_label=character(),reason=character()) else do.call(rbind,lapply(r,function(o) {manual<-l$morph[match(o$id,l$id)];if(is.na(manual)) manual<-'unclassified';data.frame(id=o$id,ai_category=o$ai_morph,raw_category=o$raw_label,score=if(is.null(o$confidence)) NA_real_ else o$confidence,human_label=manual,reason=o$reason)}))
  f<-input$ai_result_filter;if(is.null(f)) f<-'all';keep<-switch(f,uncertain=d$ai_category=='cant_tell',suggested=d$human_label=='unclassified'&d$ai_category %in% keys(),disagreement=d$human_label %in% keys()&d$ai_category %in% keys()&d$human_label!=d$ai_category,rep(TRUE,nrow(d)));d[keep,,drop=FALSE]
})
output$batch_results<-renderDT(datatable(results_table(),selection='single',rownames=FALSE,options=list(pageLength=10,scrollX=TRUE)))
observeEvent(input$batch_results_rows_selected,{d<-results_table();i<-input$batch_results_rows_selected;if(length(i)&&i[1]<=nrow(d)&&d$id[i[1]] %in% all_records()$id) {updateSelectInput(session,'queue_filter',selected='all');updateCheckboxGroupInput(session,'review_filter',selected=unname(choices()));selected(d$id[i[1]]);updateTabsetPanel(session,'workspace',selected='photos')}})
output$export_predictions<-downloadHandler(filename=function() paste0(project()$id,'_ai_results.csv'),content=function(file) {
  d<-results_table();grades<-rows();d$quality_grade<-grades$quality_grade[match(d$id,grades$id)];d$quality_grade[is.na(d$quality_grade)]<-'unknown';d$photo_mode<-rep(photo_mode(),nrow(d));d$project<-rep(project()$name,nrow(d));d$species<-rep(project()$species$name,nrow(d));d$acceptance_policy<-rep(if(is.null(input$acceptance_mode)) 'validated' else input$acceptance_mode,nrow(d));write.csv(d,file,row.names=FALSE)
})
output$overview<-renderUI({d<-all_records();stat<-function(n,label) tags$div(class='stat-card',tags$strong(format(n,big.mark=',',trim=TRUE)),tags$span(label));tags$div(class='overview',stat(nrow(d),'observations in view'),stat(sum(d$manual_morph!='unclassified'),'human labeled'),stat(sum(d$manual_morph=='unclassified'&d$ai_morph %in% keys()),'AI suggestions'),stat(sum(d$morph %in% c('cant_tell','unclassified')),'to identify / review'))})
output$classifier_summary<-renderUI({if(legacy_mode()) return(tags$p(class='evaluation-note','Original salamander baseline retained: 96.5% agreement among accepted assignments in its 315-photo test. No confidence scores; build and evaluate a new recipe to enable thresholds.'));if(is.null(recipe())) return(tags$p('Train a classifier for this project first.'));tagList(if(!identical(recipe_photo_mode(),photo_mode())) tags$p(class='evaluation-note','Photo selection differs from this recipe’s evaluation. Train and evaluate a new recipe with the selected setting to enable validated assignments.'),tags$p(paste(length(recipe()$examples),'teaching images · classifier',substr(recipe()$config_id,1,10))),if(is.null(policy())) tags$p(class='evaluation-note','Not evaluated yet. Validated mode sends all assignments to review until a policy is available.') else tags$p(class='evaluation-note','Validated mode applies the saved per-category calibration thresholds. See Train & evaluate for independent test results.'))})
session$onSessionEnded(function() {j<-isolate(job());if(!is.null(j)&&j$process$is_alive()) file.create(j$stop_file)})

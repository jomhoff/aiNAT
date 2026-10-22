output$project_subtitle<-renderUI(tags$p(paste(project()$species$name,'·',project()$name)))
refresh_projects<-function(selected_id=project()$id) {ps<-list_projects();projects(ps);cs<-setNames(vapply(ps,function(p) p$id,character(1)),vapply(ps,function(p) p$name,character(1)));updateSelectInput(session,'project_select',choices=cs,selected=selected_id)}
observeEvent(TRUE,refresh_projects(),once=TRUE)
loaded_project_id<-reactiveVal(NULL)
observeEvent(project()$id,{
  if(identical(isolate(loaded_project_id()),project()$id)) return()
  loaded_project_id(project()$id)
  dir.create(data_dir(),recursive=TRUE,showWarnings=FALSE)
  cached<-read_saved(data_file('loaded_observations.json'));raw(cached);rows(observation_rows(cached));labels(load_labels(label_path()));ai_results(read_saved(prediction_path()));selected(NULL)
  job(NULL);job_state(list(state='idle',message='Project ready.'));load_status(if(length(cached)) sprintf('%d observations restored.',length(cached)) else 'Choose a region or upload photographs.')
  region<-read_saved(data_file('loaded_region.json'),list(id='',label='All regions'));cs<-c('All regions'='', 'Michigan (MI)'='29');if(!region$id %in% cs) cs<-c(cs,setNames(region$id,region$label));region_choices(cs);updateSelectInput(session,'region',choices=cs,selected=region$id)
  updateSelectInput(session,'queue_filter',selected='all');updateSelectInput(session,'acceptance_mode',selected='validated');write_json(list(id=project()$id),'data/active_project.json')
},ignoreNULL=FALSE)
observeEvent(input$project_select,{
  id<-input$project_select;if(!nzchar(id)||identical(id,project()$id)) return()
  if(!file.exists(project_file(id))) return()
  j<-job();if(!is.null(j)&&j$process$is_alive()) {showNotification('Stop the current job before switching projects.',type='error');updateSelectInput(session,'project_select',selected=project()$id);return()}
  generation<<-generation+1L;loading(FALSE);save_loaded();project(read_saved(project_file(id)))
})
settings_mode<-reactiveVal('new');species_matches<-reactiveVal(list())
show_settings<-function(mode='new') {
  settings_mode(mode);p<-project();edit<-mode=='edit';species_matches(if(edit) list(p$species) else list())
  showModal(modalDialog(title=if(edit) 'Project settings' else 'Create a classification project',size='l',
    textInput('project_name','Project name',if(edit) p$name else '',placeholder='Example: species and trait'),
    textInput('species_search','Species name',if(edit) p$species$name else '',placeholder='Common or scientific name'),actionButton('find_species','Search iNaturalist species'),
    selectInput('species_pick','Species match',choices=if(edit) setNames('1',p$species$name) else character()),
    tags$p(class='muted small','Search and choose a species to load iNaturalist observations. A typed species name without a match supports local uploads.'),
    textAreaInput('classification_task','What should Sol classify?',if(edit) p$task else '',rows=3,placeholder='Describe the visible trait and the distinctions that matter.'),
    textAreaInput('category_definitions','Categories: key | display name | visible distinguishing features',if(edit) paste(vapply(p$categories,function(c) paste(c$key,c$label,c$description,sep=' | '),character(1)),collapse='\n') else '',rows=6,placeholder='category_a | Category A | Visible features that define A\ncategory_b | Category B | Visible features that define B'),
    tags$p(class='muted small','Use 2–12 mutually exclusive categories. Needs review is always available. Teaching examples and saved answers belong only to this project. Changing an existing category scheme requires a new project.'),
    footer=tagList(modalButton('Cancel'),actionButton('save_project',if(edit) 'Save settings' else 'Create project',class='btn-primary'))))
}
observeEvent(input$open_project_setup,show_settings('new'))
observeEvent(input$edit_project,show_settings('edit'))
observeEvent(input$find_species,tryCatch({
  term<-trimws(input$species_search);if(!nzchar(term)) stop('Enter a species name first.')
  response<-GET('https://api.inaturalist.org/v1/taxa/autocomplete',query=list(q=term,is_active='true',per_page=15),timeout(20));stop_for_status(response);matches<-fromJSON(content(response,'text',encoding='UTF-8'),simplifyVector=FALSE)$results
  if(!length(matches)) stop('No matching taxa found. Try a scientific name.')
  species_matches(lapply(matches,function(t) list(id=as.character(t$id),name=t$name,common_name=if(is.null(t$preferred_common_name)) '' else t$preferred_common_name)))
  updateSelectInput(session,'species_pick',choices=setNames(as.character(seq_along(matches)),vapply(matches,function(t) paste(t$name,if(is.null(t$preferred_common_name)) '' else paste('·',t$preferred_common_name)),character(1))),selected='1')
},error=function(e) showNotification(conditionMessage(e),type='error')))
observeEvent(input$save_project,tryCatch({
  name<-trimws(input$project_name);task<-trimws(input$classification_task);if(!nzchar(name)||!nzchar(task)||!nzchar(trimws(input$species_search))) stop('Enter a project name, species and classification task.')
  categories<-category_definitions(input$category_definitions)
  matches<-species_matches();i<-suppressWarnings(as.integer(input$species_pick));species<-if(length(i)&&!is.na(i)&&i>=1&&i<=length(matches)) matches[[i]] else list(id='',name=trimws(input$species_search),common_name='')
  if(settings_mode()=='edit') {
    p<-project();if(!identical(vapply(categories,function(c) c$key,character(1)),keys()) || !identical(species$name,p$species$name)) stop('Create a new project to change the species or category keys; this protects existing labels.')
    p$name<-name;p$task<-task;p$categories<-categories;p$active_recipe<-NULL
    write_json(p,project_file(p$id));project(p);refresh_projects();removeModal();showNotification('Settings saved. Build a new classifier before classifying.',duration=6)
  } else {
    slug<-gsub('(^-+|-+$)','',gsub('[^a-z0-9]+','-',tolower(name)));if(!nzchar(slug)) slug<-'project'
    id<-paste0(substr(slug,1,40),'-',format(Sys.time(),'%Y%m%d%H%M%S'),'-',sample(1000:9999,1));dir<-file.path(project_root,id);dir.create(dir,recursive=TRUE)
    p<-list(id=id,name=name,species=species,task=task,categories=categories,data_dir=dir,label_file='labels.csv',prediction_file='predictions.json',active_recipe=NULL)
    write_json(p,project_file(id));save_loaded();generation<<-generation+1L;project(p);refresh_projects(id);removeModal();updateTabsetPanel(session,'workspace',selected='train')
  }
},error=function(e) showNotification(conditionMessage(e),type='error')))
observeEvent(input$local_photos,tryCatch({
  files<-input$local_photos;if(is.null(files)) return()
  added<-list();dir<-data_file('uploads');dir.create(dir,recursive=TRUE,showWarnings=FALSE)
  for(i in seq_len(nrow(files))) {
    hash<-unname(tools::md5sum(files$datapath[i]));id<-paste0('local_',hash);path<-file.path(dir,paste0(id,'.png'))
    image<-magick::image_read(files$datapath[i])[1];image<-magick::image_resize(magick::image_orient(image),'900x480>');magick::image_write(image,path,format='png')
    added[[length(added)+1L]]<-list(id=id,quality_grade='local',location='',place_guess='Local upload',observed_on='',user=list(login='You'),coordinates_obscured=FALSE,uri='',photos=list(list(id=id,image_path=normalizePath(path),url='',attribution=paste('Local photo:',files$name[i]))))
  }
  combined<-c(raw(),added);ids<-vapply(combined,function(o) as.character(o$id),character(1));combined<-combined[!duplicated(ids)];raw(combined);rows(observation_rows(combined));save_loaded();selected(as.character(added[[1]]$id));updateTabsetPanel(session,'workspace',selected='photos')
},error=function(e) showNotification('One or more photos could not be imported. Use JPEG, PNG or WebP.',type='error')))
output$project_definition<-renderUI(tagList(tags$h4(project()$species$name),tags$p(project()$task),tags$div(class='project-definitions',lapply(project()$categories,function(c) tags$div(class='category-description',tags$strong(c$label),tags$p(c$description))))))
output$label_counts<-renderText({l<-labels();paste(vapply(keys(),function(k) sprintf('%s: %d labeled observations',pretty_morph(k),sum(l$morph==k)),character(1)),collapse=' · ')})
output$recipe_status<-renderText({j<-job();if(!is.null(j)&&j$command=='train'&&!isTRUE(j$finished)) return(job_state()$message);if(legacy_mode()) return('Original salamander baseline is available. Build a new recipe to teach examples and evaluate confidence.');r<-recipe();if(is.null(r)) return('No classifier prepared yet.');sprintf('Prepared: %d reference images · %d teaching / %d calibration / %d test observations.',length(r$examples),length(r$splits$teaching),length(r$splits$calibration),length(r$splits$test))})
output$evaluation_summary<-renderUI({
  invalidateLater(2000,session);r<-recipe();j<-job();if(!is.null(j)&&j$command=='evaluate'&&!isTRUE(j$finished)) return(tags$p(job_state()$message))
  if(is.null(r)) return(tags$p('Prepare a classifier to enable independent confidence evaluation.'))
  summary<-read_saved(file.path(dirname(project()$active_recipe),'evaluation_summary.json'),NULL)
  if(is.null(summary)||!identical(summary$config_id,r$config_id)) return(tags$p('Not evaluated. No confidence threshold is validated for this classifier.'))
  m<-summary$test;precision<-if(is.null(m$precision)) 'n/a' else sprintf('%.1f%%',100*m$precision)
  tagList(tags$p(class='evaluation-note',sprintf('Frozen test: %s agreement among %d accepted assignments · %d wrong · %d sent for review (%d total).',precision,m$accepted,m$wrong,m$uncertain,m$n)),
    tags$table(class='evaluation-table',tags$thead(tags$tr(tags$th('Category'),tags$th('Score cutoff'),tags$th('Calibration correct / accepted'))),tags$tbody(lapply(keys(),function(k) {threshold<-summary$policy$thresholds[[k]];e<-summary$policy$calibration[[k]];tags$tr(tags$td(pretty_morph(k)),tags$td(if(is.null(threshold)) 'Review only' else threshold),tags$td(paste(e$correct,'/',e$accepted)))}))),
    tags$p(class='muted small','Thresholds were selected on calibration only. This test is now evaluated; further tuning needs a fresh independent audit. Self-assessed scores and selected calibration accuracy are not guarantees.'))
})
output$export_evaluation<-downloadHandler(filename=function() paste0(project()$id,'_evaluation.json'),content=function(file) {r<-recipe();if(is.null(r)) {write_json(list(message='No classifier evaluated.'),file);return()};report<-read_saved(file.path(dirname(project()$active_recipe),'evaluation_summary.json'),list(message='No evaluation available.'));write_json(report,file)})
observeEvent(input$api_setup,showModal(modalDialog(title='Use your own Sol API key',passwordInput('own_api_key','Full OpenAI secret API key'),tags$p('Your key is saved only on this computer, outside the project, with owner-only file permissions. It is never included in exports or GitHub. API use is billed to your own OpenAI project.'),footer=tagList(modalButton('Cancel'),actionButton('save_api_key','Save my key',class='btn-primary')))))
observeEvent(input$save_api_key,tryCatch({
  key<-trimws(input$own_api_key);if(!startsWith(key,'sk-')||grepl('\\s|\\.\\.\\.|…',key)) stop('Enter the full secret key, not its shortened display value.')
  python<-file.path(normalizePath('.venv',mustWork=FALSE),'bin','python');if(!file.exists(python)) stop('Run Setup.command before configuring your key.')
  proc<-processx::process$new(python,c(normalizePath('openai_key_setup.py'),'--stdin'),stdin='|',stdout='|',stderr='|')
  proc$write_input(key);processx::processx_conn_close(proc$get_input_connection());proc$wait(5000)
  if(proc$is_alive()) {proc$kill();stop('Key setup timed out.')}
  if(proc$get_exit_status()!=0) stop('Could not save the key. Check that it is a full secret key.')
  updateTextInput(session,'own_api_key',value='');key<-NULL;removeModal();key_version(key_version()+1L);showNotification('Your key is saved locally. No API requests were made.')
},error=function(e) showNotification(conditionMessage(e),type='error')))

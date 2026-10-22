suppressPackageStartupMessages({library(shiny); library(leaflet); library(DT); library(httr); library(jsonlite)})
options(shiny.maxRequestSize=20*1024^2)
label_path <- file.path('data','salamander_morph_labels.csv')
dir.create('data', showWarnings=FALSE)
empty_labels <- data.frame(id=character(), morph=character(), notes=character(), stringsAsFactors=FALSE)
load_labels <- function(path=label_path) {
  if (!file.exists(path)) return(empty_labels)
  read.csv(path, colClasses='character', stringsAsFactors=FALSE)
}
observation_query <- function(place='', before=NULL,research_only=TRUE,taxon_id='27186') {
  query <- list(taxon_id=taxon_id, photos='true', per_page=200, order_by='id', order='desc')
  if (nzchar(trimws(place))) query$place_id <- trimws(place)
  if (!is.null(before)) query$id_below <- before
  if(isTRUE(research_only)) query$quality_grade <- 'research'
  query
}
fetch_salamander_batch <- function(place='', before=NULL,research_only=TRUE,taxon_id='27186') {
  query <- observation_query(place,before,research_only,taxon_id)
  query$fields <- jsonlite::toJSON(list(id=TRUE,quality_grade=TRUE,location=TRUE,place_guess=TRUE,observed_on=TRUE,user=list(login=TRUE),obscured=TRUE,uri=TRUE,photos=list(id=TRUE,url=TRUE,attribution=TRUE)),auto_unbox=TRUE)
  response <- RETRY('GET', 'https://api.inaturalist.org/v2/observations', query=query,
    timeout(30), user_agent('aiNAT/1.0'), times=3, quiet=TRUE)
  stop_for_status(response)
  fromJSON(content(response, 'text', encoding='UTF-8'), simplifyVector=FALSE)
}
observation_rows <- function(observations) {
  if (!length(observations)) return(data.frame(id=character(), latitude=numeric(), longitude=numeric(), locality=character(), date=character(), observer=character(), quality_grade=character(), obscured=logical(), url=character()))
  value <- function(x, fallback='') if(!length(x)) fallback else as.character(x)[1]
  rows <- lapply(observations, function(o) {
    coords <- strsplit(value(o$location),',',fixed=TRUE)[[1]]
    if(!length(o$photos)) return(NULL)
    if(length(coords)!=2) coords <- c(NA_character_, NA_character_)
    data.frame(id=as.character(o$id), latitude=as.numeric(coords[1]), longitude=as.numeric(coords[2]), locality=value(o$place_guess), date=value(o$observed_on), observer=value(o$user$login), quality_grade=value(o$quality_grade,'unknown'), obscured=isTRUE(o$coordinates_obscured)||isTRUE(o$obscured), url=value(o$uri), stringsAsFactors=FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if(!length(rows)) return(observation_rows(list()))
  out <- do.call(rbind,rows)
  out
}
source('classifier.R',local=TRUE)
source('project_helpers.R',local=TRUE)
source('ui.R',local=TRUE)
server <- function(input,output,session) {
  ensure_projects(); projects <- reactiveVal(list_projects()); initial<-read_saved('data/active_project.json',list(id='salamander-morphs'))
  project <- reactiveVal(read_saved(project_file(initial$id),default_project()))
  data_dir <- reactive(project()$data_dir)
  data_file <- function(name) file.path(data_dir(),name)
  label_path <- reactive(data_file(project()$label_file))
  prediction_path <- reactive(data_file(project()$prediction_file))
  keys <- reactive(vapply(project()$categories,function(c) c$key,character(1)))
  choices <- reactive(c(setNames(keys(),vapply(project()$categories,function(c) c$label,character(1))),'Needs review'='cant_tell','Unclassified'='unclassified'))
  pretty_morph <- function(x) {if(!length(x) || is.na(x)) return('Unclassified'); hit<-match(x,unname(choices()));if(is.na(hit)) x else names(choices())[hit]}
  colors <- reactive(setNames(c(grDevices::hcl.colors(length(keys()),'Dark 3'),'#9173ad','#d2d6da'),c(keys(),'cant_tell','unclassified')))
  raw<-reactiveVal(list());rows<-reactiveVal(observation_rows(list()));labels<-reactiveVal(empty_labels);selected<-reactiveVal(NULL);ai_results<-reactiveVal(list())
  loading<-reactiveVal(FALSE);load_status<-reactiveVal('');generation<-0L;region_choices<-reactiveVal(c('All regions'='', 'Michigan (MI)'='29'))
  recipe <- reactive({p<-project()$active_recipe;if(is.null(p) || identical(p,'legacy')) NULL else read_saved(p,NULL)})
  legacy_mode <- reactive(identical(project()$active_recipe,'legacy'))
  expected_config_id <- reactive(if(legacy_mode()) jsonlite::fromJSON('sol_config.json')$config_id else if(!is.null(recipe())) recipe()$config_id else NULL)
  policy <- reactive({invalidateLater(2000,session);r<-recipe();if(is.null(r)) return(NULL);p<-read_saved(file.path(dirname(project()$active_recipe),'policy.json'),NULL);if(!is.null(p) && identical(p$config_id,r$config_id)) p else NULL})
  active_predictions <- reactive({
    id<-expected_config_id();if(is.null(id)) return(list())
    r<-Filter(function(o) identical(o$config_id,id),ai_results())
    lapply(r,function(o) {
      o$raw_label<-if(is.null(o$raw_label)) o$ai_morph else o$raw_label
      if(!legacy_mode() || identical(input$acceptance_mode,'manual')) {
        threshold<-NULL
        if(identical(input$acceptance_mode,'manual')) threshold<-input$confidence_cutoff else if(!is.null(policy())) threshold<-policy()$thresholds[[o$raw_label]]
        accepted<-!is.null(threshold) && !is.null(o$confidence) && isTRUE(o$feature_visible) && o$raw_label %in% keys() && o$confidence>=threshold
        o$ai_morph<-if(accepted) o$raw_label else 'cant_tell'
      }
      o
    })
  })
  all_records <- reactive({
    d<-rows();if(!identical(input$research_only,FALSE)) d<-d[d$quality_grade %in% c('research','local'),,drop=FALSE]
    l<-labels();idx<-match(d$id,l$id);d$manual_morph<-l$morph[idx];d$manual_morph[is.na(d$manual_morph)]<-'unclassified';d$notes<-l$notes[idx];d$notes[is.na(d$notes)]<-''
    predictions<-active_predictions();pi<-match(d$id,vapply(predictions,function(o) as.character(o$id),character(1)))
    d$ai_morph<-vapply(predictions,function(o) o$ai_morph,character(1))[pi];d$ai_morph[is.na(d$ai_morph)]<-'unclassified'
    d$confidence<-vapply(predictions,function(o) if(is.null(o$confidence)) NA_real_ else as.numeric(o$confidence),numeric(1))[pi]
    d$morph<-ifelse(d$manual_morph!='unclassified',d$manual_morph,d$ai_morph);d$label_source<-ifelse(d$manual_morph!='unclassified','Human',ifelse(d$ai_morph!='unclassified','Sol','Unclassified'));d
  })
  review_records <- reactive({
    d<-all_records();shown<-input$review_filter;if(is.null(shown)) shown<-unname(choices());d<-d[d$morph %in% shown,,drop=FALSE]
    q<-input$queue_filter;if(is.null(q)) q<-'all'
    keep<-switch(q,unprocessed=d$manual_morph=='unclassified' & d$ai_morph=='unclassified',uncertain=d$manual_morph=='unclassified' & d$ai_morph=='cant_tell',suggested=d$manual_morph=='unclassified' & d$ai_morph %in% keys(),confirmed=d$manual_morph!='unclassified',rep(TRUE,nrow(d)))
    d[keep,,drop=FALSE]
  })
  current <- reactive({d<-all_records();d[d$id %in% selected(),,drop=FALSE]})
  current_photos <- reactive({hit<-Filter(function(o) identical(as.character(o$id),selected()),raw());if(length(hit)) hit[[1]]$photos else list()})
  next_review_id <- function(exclude_current=FALSE) {
    ids<-all_records()$id;candidates<-review_records()$id;if(exclude_current) candidates<-setdiff(candidates,selected());if(!length(candidates)) return(NULL)
    i<-match(selected(),ids);if(!length(i) || is.na(i)) return(candidates[1])
    order<-c(if(i<length(ids)) ids[seq.int(i+1,length(ids))] else character(),ids[seq_len(i)]);order[order %in% candidates][1]
  }
  save_loaded <- function() {
    write_json(raw(),data_file('loaded_observations.json'));id<-input$region;if(is.null(id)) id<-''
    region<-region_choices();name<-names(region)[match(id,region)];if(is.na(name)) name<-paste('Region',id)
    write_json(list(id=id,label=name),data_file('loaded_region.json'))
  }
  save_label <- function(morph,advance=FALSE) {
    req(selected());stopifnot(morph %in% c(keys(),'cant_tell','unclassified'))
    next_id<-if(advance) next_review_id(TRUE) else selected();l<-labels();l<-l[l$id!=selected(),,drop=FALSE];note<-if(is.null(input$notes)) '' else input$notes
    l<-rbind(l,data.frame(id=selected(),morph=morph,notes=note,stringsAsFactors=FALSE))
    tryCatch({atomic_csv(l,label_path());labels(l);if(advance) selected(next_id);TRUE},error=function(e) {showNotification('Could not save label.',type='error');FALSE})
  }
  observeEvent(list(input$review_filter,input$queue_filter,input$research_only),{if(!is.null(selected()) && selected() %in% review_records()$id) return();selected(next_review_id())},ignoreNULL=FALSE)
  for(i in seq_len(12)) local({index<-i;observeEvent(input[[paste0('category_',index)]],{if(index<=length(keys())) save_label(keys()[index],TRUE)},ignoreInit=TRUE)})
  observeEvent(input$label_cant_tell,save_label('cant_tell',TRUE));observeEvent(input$label_unclassified,save_label('unclassified',FALSE))
  observeEvent(input$save_notes,{d<-current();if(nrow(d)) save_label(d$manual_morph[1])});observeEvent(input$next_obs,selected(next_review_id()))
  observeEvent(selected(),{d<-current();if(nrow(d)) updateTextAreaInput(session,'notes',value=d$notes[1])})
  output$category_filter<-renderUI(checkboxGroupInput('review_filter','Categories shown',choices=choices(),selected=unname(choices())))
  output$label_controls<-renderUI(tags$div(class='label-grid',lapply(seq_along(keys()),function(i) actionButton(paste0('category_',i),pretty_morph(keys()[i]))),actionButton('label_cant_tell',"Can't tell"),actionButton('label_unclassified','Clear label')))
  output$photo_picker<-renderUI({p<-current_photos();if(length(p)>1) selectInput('photo_index','Photo',setNames(seq_along(p),paste('Photo',seq_along(p))))})
  output$photo<-renderUI({p<-current_photos();if(!length(p)) return(tags$div(class='empty-photo',tags$h3('Ready for a closer look'),tags$p('Load a species and region, upload photos, or choose another review queue.')))
    i<-suppressWarnings(as.integer(input$photo_index));if(!length(i)||is.na(i)||i<1||i>length(p)) i<-1
    credit<-p[[i]]$attribution;if(!length(credit)) credit<-'Your local photograph'
    tagList(tags$div(class='photo-toolbar',actionButton('zoom_in','＋'),actionButton('zoom_out','−'),actionButton('zoom_reset','Fit'),textOutput('zoom_level',inline=TRUE)),tags$div(class='photo-viewport',imageOutput('analysis_image',height='auto',width='100%')),tags$p(class='photo-credit',credit))})
  output$details<-renderUI({d<-current();if(!nrow(d)) return(tags$p(class='muted','Select a photo to begin.'));tagList(tags$h3(class='observation-title',paste('Observation',d$id[1])),tags$div(class='observation-meta',tags$p(d$locality[1]),tags$p(paste('Quality grade:',d$quality_grade[1]))),tags$span(class='badge-morph',paste('Your label:',pretty_morph(d$manual_morph[1]))),if(nzchar(d$url[1])) tags$p(tags$a(href=d$url[1],target='_blank',rel='noopener','View on iNaturalist ↗')))})
  observeEvent(input$find_region,tryCatch({
    term<-trimws(input$region_search);if(!nzchar(term)) return()
    response<-GET('https://api.inaturalist.org/v1/places/autocomplete',query=list(q=term),timeout(20));stop_for_status(response);places<-fromJSON(content(response,'text',encoding='UTF-8'),simplifyVector=FALSE)$results
    if(!length(places)) stop('No matching regions.')
    cs<-c('All regions'='', 'Michigan (MI)'='29',setNames(vapply(places,function(p) as.character(p$id),character(1)),vapply(places,function(p) p$display_name,character(1))));cs<-cs[!duplicated(unname(cs))];region_choices(cs);updateSelectInput(session,'region',choices=cs,selected=as.character(places[[1]]$id))
  },error=function(e) showNotification(conditionMessage(e),type='error')))
  observeEvent(input$stop_load,{generation<<-generation+1L;loading(FALSE);save_loaded();load_status(sprintf('Stopped. %d observations retained.',nrow(rows())))})
  load_observations<-function(refresh=FALSE) {
    taxon<-project()$species$id;if(!length(taxon)||!nzchar(taxon)) {showNotification('Choose an iNaturalist species first, or upload local photos.',type='error');return()}
    generation<<-generation+1L;token<-generation;scope<-project()$id;research_only<-!identical(input$research_only,FALSE);place<-input$region;cursor<-NULL
    if(is.null(place)) place<-''
    cache_name<-paste0(gsub('[^0-9]','',taxon),'_',if(nzchar(place)) gsub('[^0-9]','',place) else 'all','_',if(research_only) 'research' else 'all-grades','.json')
    cache_path<-data_file(file.path('observation-cache',cache_name))
    accumulated<-Filter(function(o) identical(o$quality_grade,'local'),raw());current_rows<-observation_rows(accumulated)
    if(!refresh && file.exists(cache_path)) {
      snapshot<-read_saved(cache_path,NULL)
      if(!is.null(snapshot)&&isTRUE(snapshot$complete)) {
        combined<-c(accumulated,snapshot$observations);ids<-vapply(combined,function(o) as.character(o$id),character(1));combined<-combined[!duplicated(ids)]
        raw(combined);rows(observation_rows(combined));selected(next_review_id());loading(FALSE);save_loaded()
        load_status(sprintf('%d observations from saved region snapshot (%s). Refresh checks for updates.',length(snapshot$observations),snapshot$loaded_at));return()
      }
    }
    page_received<-FALSE
    loading(TRUE);load_status('Loading compact observation records…')
    step<-function() {
      if(token!=generation||scope!=project()$id||session$isClosed()) return()
      tryCatch({
        result<-fetch_salamander_batch(place,cursor,research_only,taxon)
        if(!page_received) {page_received<<-TRUE;raw(accumulated);rows(current_rows);selected(NULL)}
        batch<-lapply(result$results,function(o) list(id=o$id,quality_grade=o$quality_grade,location=o$location,place_guess=o$place_guess,observed_on=o$observed_on,user=list(login=o$user$login),coordinates_obscured=isTRUE(o$obscured)||isTRUE(o$coordinates_obscured),uri=o$uri,photos=lapply(o$photos,function(p) list(id=p$id,url=p$url,attribution=p$attribution))))
        if(length(batch)) {
          # Build rows for the new page only; don't reconstruct every earlier row.
          new_rows<-observation_rows(batch);new_rows<-new_rows[!new_rows$id %in% current_rows$id,,drop=FALSE]
          new_ids<-new_rows$id;batch<-Filter(function(o) as.character(o$id) %in% new_ids,batch)
          accumulated<<-c(accumulated,batch);current_rows<<-rbind(current_rows,new_rows)
          raw(accumulated);rows(current_rows);if(is.null(selected())||!selected() %in% all_records()$id) selected(next_review_id())
          new_cursor<-min(vapply(result$results,function(o) as.numeric(o$id),numeric(1)))
          if(!is.null(cursor)&&new_cursor>=cursor) stop('Pagination did not advance.');cursor<<-new_cursor
        }
        finished<-length(result$results)<200
        load_status(sprintf('%d retained%s',length(accumulated),if(finished) ' · complete' else ' · loading…'))
        if(!finished) later::later(function() shiny::withReactiveDomain(session,isolate(step())),1)
        else {
          loading(FALSE);save_loaded();dir.create(dirname(cache_path),recursive=TRUE,showWarnings=FALSE)
          write_json(list(complete=TRUE,loaded_at=format(Sys.time(),tz='UTC',usetz=TRUE),query=list(taxon_id=taxon,place_id=place,research_only=research_only),observations=Filter(function(o) !identical(o$quality_grade,'local'),accumulated)),cache_path)
        }
      },error=function(e) {loading(FALSE);if(page_received) save_loaded();load_status(paste('Import stopped:',conditionMessage(e)))})
    };step()
  }
  observeEvent(input$fetch,load_observations(FALSE))
  observeEvent(input$refresh_observations,load_observations(TRUE))
  output$quality_status<-renderText({d<-rows();if(any(d$quality_grade=='unknown')) 'Older records lack quality grades. Reload to include them with Research Grade only.' else if(!identical(input$research_only,FALSE)) 'Research Grade iNaturalist observations + your local uploads.' else 'All observation grades included.'})
  output$load_status<-renderText(load_status());output$status<-renderText({d<-all_records();sprintf('%d shown · %d human labeled',nrow(d),sum(d$manual_morph!='unclassified'))})
  output$map<-renderLeaflet(leaflet(options=leafletOptions(preferCanvas=TRUE)) |> addTiles() |> setView(-95,48,3))
  observe({req(identical(input$workspace,'records'));d<-review_records();d<-d[is.finite(d$latitude)&is.finite(d$longitude),,drop=FALSE];proxy<-leafletProxy('map') |> clearMarkers() |> clearControls() |> addLegend(colors=unname(colors()),labels=names(choices())[match(names(colors()),unname(choices()))],title='Classification');if(nrow(d)) proxy |> addCircleMarkers(lng=d$longitude,lat=d$latitude,layerId=d$id,radius=6,color='#333',weight=1,fillColor=unname(colors()[d$morph]),fillOpacity=.9,popup=paste0(htmltools::htmlEscape(d$locality),'<br>Category: ',d$morph,'<br>Source: ',d$label_source))})
  observeEvent(input$map_marker_click,{selected(input$map_marker_click$id);updateTabsetPanel(session,'workspace',selected='photos')})
  output$records<-renderDT(datatable(review_records(),selection='single',rownames=FALSE,options=list(pageLength=10,scrollX=TRUE)))
  observeEvent(input$records_rows_selected,{d<-review_records();i<-input$records_rows_selected;if(length(i)&&i[1]<=nrow(d)) {selected(d$id[i[1]]);updateTabsetPanel(session,'workspace',selected='photos')}})
  output$export<-downloadHandler(filename=function() paste0(project()$id,'_records.csv'),content=function(file) write.csv(all_records(),file,row.names=FALSE))
  source('sol_server.R',local=TRUE)
  source('project_server.R',local=TRUE)
}
shinyApp(ui,server)

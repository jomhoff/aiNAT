project_root <- file.path('data','projects')
default_project <- function() list(id='salamander-morphs',name='Red-backed salamander morphs',species=list(id='27186',name='Plethodon cinereus',common_name='Red-backed salamander'),task='Classify the dorsal color morph: a contrasting mid-dorsal stripe versus an unstriped lead-colored back.',categories=list(list(key='red_backed',label='Red-backed',description='Distinct red, orange, tan or brown dorsal stripe contrasting with darker sides.'),list(key='lead_backed',label='Lead-backed',description='Clearly visible dorsal surface with no distinct stripe.')),data_dir='data',label_file='salamander_morph_labels.csv',prediction_file='sol_predictions.json',active_recipe='legacy')
read_saved <- function(path,default=list()) tryCatch(jsonlite::fromJSON(path,simplifyVector=FALSE),error=function(e) default)
project_file <- function(id) file.path(project_root,id,'project.json')
list_projects <- function() {
  paths<-list.files(project_root,pattern='project.json$',recursive=TRUE,full.names=TRUE)
  Filter(function(p) length(p$id)>0,lapply(paths,read_saved))
}
ensure_projects <- function() {
  dir.create(project_root,recursive=TRUE,showWarnings=FALSE)
  p<-default_project();if(!file.exists(project_file(p$id))) {dir.create(dirname(project_file(p$id)),recursive=TRUE,showWarnings=FALSE);write_json(p,project_file(p$id))}
}
category_definitions <- function(text) {
  lines<-trimws(strsplit(text,'\n',fixed=TRUE)[[1]]);lines<-lines[nzchar(lines)]
  if(length(lines)<2 || length(lines)>12) stop('Define 2–12 categories, one per line.')
  categories<-lapply(lines,function(line) {
    parts<-trimws(strsplit(line,'|',fixed=TRUE)[[1]])
    if(length(parts)!=3 || any(!nzchar(parts))) stop('Use key | display name | visible distinguishing features on every line.')
    if(!grepl('^[a-z][a-z0-9_]{0,39}$',parts[1]) || parts[1] %in% c('cant_tell','unclassified')) stop('Keys must be lowercase letters, numbers or underscores and cannot be cant_tell or unclassified.')
    list(key=parts[1],label=parts[2],description=parts[3])
  })
  if(anyDuplicated(vapply(categories,function(c) c$key,character(1)))) stop('Category keys must be unique.')
  categories
}
api_key_path <- function() {
  explicit<-Sys.getenv('SPECIES_VISION_KEY_FILE');if(nzchar(explicit)) return(path.expand(explicit))
  current<-path.expand('~/.config/species-vision-lab/openai-api-key');old<-path.expand('~/.config/salamander-morphs/openai-api-key')
  if(file.exists(current) || !file.exists(old)) current else old
}

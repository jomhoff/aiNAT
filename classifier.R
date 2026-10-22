atomic_csv <- function(d,path) {
  tmp <- tempfile(tmpdir=dirname(path)); on.exit(unlink(tmp))
  write.csv(d,tmp,row.names=FALSE)
  if(!file.rename(tmp,path)) stop('Could not save file.')
}
read_analysis_image <- function(url) {
  response <- httr::GET(url,httr::timeout(30)); httr::stop_for_status(response)
  img <- magick::image_read(httr::content(response,'raw'))[1]
  magick::image_resize(magick::image_orient(img),'900x480>')
}
write_json <- function(value,path) {
  tmp <- tempfile(tmpdir=dirname(path)); on.exit(unlink(tmp))
  jsonlite::write_json(value,tmp,auto_unbox=TRUE,pretty=TRUE,na='null')
  if(!file.rename(tmp,path)) stop('Could not save job file.')
}
pretty_morph <- function(x) {
  if(!length(x) || is.na(x)) return('Unclassified')
  switch(x,red_backed='Red-backed',lead_backed='Lead-backed',cant_tell='Needs review',unclassified='Unclassified',x)
}

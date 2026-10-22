#!/bin/zsh
cd "${0:A:h}"
Rscript -e "shiny::runApp('.', host='127.0.0.1', port=7460, launch.browser=TRUE)"

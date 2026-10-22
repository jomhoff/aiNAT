#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
Rscript -e "shiny::runApp('.',host='127.0.0.1',port=7460,launch.browser=TRUE)"

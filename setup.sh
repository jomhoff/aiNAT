#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v python3 >/dev/null || { echo 'Install Python 3.11+ first.'; exit 1; }
command -v Rscript >/dev/null || { echo 'Install R 4.3+ first.'; exit 1; }
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
Rscript -e "p <- c('shiny','leaflet','DT','httr','jsonlite','htmltools','later','magick','processx'); missing <- p[!vapply(p, requireNamespace, logical(1), quietly=TRUE)]; if(length(missing)) install.packages(missing,repos='https://cloud.r-project.org')"
echo 'Setup complete. Run Launch.command or bash launch.sh.'

#!/bin/bash

# init repo
# restic init --repo /mnt/cache/backup/restic

export RESTIC_REPOSITORY=/mnt/cache/backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-pass

restic backup /srv \
  --exclude /srv/media \
  --exclude /srv/ftp \
  --exclude /srv/http

restic forget --prune \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6
#!/bin/bash

export PLEX_TOKEN='f_nrFDNmmptCDziYkUx3&'
export PLEX_SERVER='192.168.4.30:32400'

curl -s "http://$PLEX_SERVER/library/sections/1/all?X-Plex-Token=$PLEX_TOKEN" \
| grep -o 'type="movie"[^>]*title="[^"]\+"' \
| sed 's/.*title="//; s/"$//' \
| head -n 100

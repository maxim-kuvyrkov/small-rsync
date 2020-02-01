#!/bin/bash

if [ -d "$(dirname "/mnt/btrfs/$@")" ]; then
    printf "%s\0" "$@"
fi

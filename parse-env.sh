#!/bin/bash
set -eu

ENV_FILE="config.env"
OUT_FILE="config_vars.yml"

echo "# Auto-generated from config.env" > "$OUT_FILE"
while IFS='=' read -r key value; do
  if [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]]; then
    continue
  fi
  echo "$key: \"$value\"" >> "$OUT_FILE"
done < "$ENV_FILE"

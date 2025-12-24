#!/usr/bin/env bash
# Python virtual environment helper script
# Usage: pyenvshell.sh [env_name]
# Creates or activates a Python virtual environment

ENV_NAME="${1:-venv}"
ENV_DIR="./$ENV_NAME"

if [ ! -d "$ENV_DIR" ]; then
    echo "Creating new virtual environment: $ENV_NAME"
    python3 -m venv "$ENV_DIR"
    source "$ENV_DIR/bin/activate"
    pip install --upgrade pip
    echo "Virtual environment '$ENV_NAME' created and activated"
else
    echo "Activating existing virtual environment: $ENV_NAME"
    source "$ENV_DIR/bin/activate"
fi

# Return to fish shell with the venv activated
exec fish

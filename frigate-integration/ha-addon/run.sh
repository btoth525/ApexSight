#!/usr/bin/with-contenv bashio

export DOORBELL_IP=$(bashio::config 'doorbell_ip')
export WS_PORT=$(bashio::config 'ws_port')
export FRIGATE_TOKEN=$(bashio::config 'frigate_token')

bashio::log.info "Starting Apex Doorbell Audio proxy"
bashio::log.info "Doorbell: ${DOORBELL_IP}  WS port: ${WS_PORT}"

exec python3 /doorbell_audio_ws.py

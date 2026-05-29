ARG BUILD_FROM
FROM $BUILD_FROM

# ffmpeg for PCM → AAC-LC ADTS encoding
RUN apk add --no-cache ffmpeg

# Python dependency
RUN pip3 install --no-cache-dir websockets

COPY doorbell_audio_ws.py /doorbell_audio_ws.py
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]

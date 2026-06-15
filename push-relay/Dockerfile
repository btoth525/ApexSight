FROM python:3.12-slim

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV APEX_DATA_DIR=/data
# Port the relay listens on inside the container. Override with APEX_PORT (.env).
ENV APEX_PORT=3421
VOLUME ["/data"]
EXPOSE 3421

# Shell-form CMD so ${APEX_PORT} is substituted at runtime.
CMD uvicorn app.main:app --host 0.0.0.0 --port ${APEX_PORT}

FROM python:3.12-slim

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV APEX_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 3421

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "3421"]

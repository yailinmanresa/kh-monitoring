# Small official Python image
FROM python:3.12-slim

# Work in /app inside the container
WORKDIR /app

# Install the packages first
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy only the API code
COPY app.py .

# Don't run as root (more secure), but let appuser write api.log and api.db
RUN useradd -m appuser && chown -R appuser /app
USER appuser

# The API listens on port 8000
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
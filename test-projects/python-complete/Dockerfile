FROM python:3.12-alpine
WORKDIR /app
COPY src/ ./src/
USER 1000:1000
CMD ["python3", "-c", "from src.calculator import add; print(add(1, 2))"]

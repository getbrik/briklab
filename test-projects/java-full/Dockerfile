FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY target/*.jar app.jar
USER 1000:1000
CMD ["java", "-jar", "app.jar"]

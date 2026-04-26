FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine3.21 AS build
WORKDIR /app
COPY . .
RUN dotnet publish src/Calculator/Calculator.csproj -c Release -o /out

FROM mcr.microsoft.com/dotnet/runtime:9.0-alpine3.21
WORKDIR /app
COPY --from=build /out .
USER 1000:1000
CMD ["dotnet", "Calculator.dll"]

FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS build
WORKDIR /app
COPY . .
RUN dotnet publish src/Calculator/Calculator.csproj -c Release -o /out

FROM mcr.microsoft.com/dotnet/runtime:9.0-alpine
WORKDIR /app
COPY --from=build /out .
USER 1000:1000
CMD ["dotnet", "Calculator.dll"]

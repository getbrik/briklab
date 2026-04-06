FROM rust:1-alpine3.21 AS builder
WORKDIR /app
COPY Cargo.toml .
COPY src/ ./src/
RUN cargo build --release

FROM alpine:3.21
WORKDIR /app
COPY --from=builder /app/target/release/rust-complete .
CMD ["./rust-complete"]

FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o edge-device-service .

FROM alpine:3.19
RUN apk add --no-cache wget ca-certificates
WORKDIR /app
COPY --from=builder /app/edge-device-service .
EXPOSE 8080
ENTRYPOINT ["./edge-device-service"]

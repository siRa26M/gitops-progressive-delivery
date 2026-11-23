# syntax=docker/dockerfile:1
FROM golang:1.24-alpine AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/demo-app .

# Distroless, non-root (uid 65532), no shell - minimal attack surface.
FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/siRa26M/gitops-progressive-delivery" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=build /out/demo-app /demo-app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/demo-app"]

# syntax=docker/dockerfile:1
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY app/go.mod ./
COPY app/*.go ./

# ARGs declared here, immediately before the build step, rather than at the
# top of the stage — a BUILD_TIME that changes on every build shouldn't
# invalidate the (currently trivial, but not always) layers above it.
ARG GIT_SHA=dev
ARG IMAGE_TAG=dev
ARG BUILD_TIME=unknown

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags "-s -w -X main.gitSHA=${GIT_SHA} -X main.imageTag=${IMAGE_TAG} -X main.buildTime=${BUILD_TIME}" \
    -o /out/waypoint .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/waypoint /waypoint
EXPOSE 8080
ENTRYPOINT ["/waypoint"]

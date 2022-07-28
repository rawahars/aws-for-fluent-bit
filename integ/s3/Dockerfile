FROM public.ecr.aws/docker/library/golang:1.17.9 AS base

RUN go version

ENV GOPROXY=direct

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the source from the current directory to the Working Directory inside the container
COPY . .

# Download all dependencies. Dependencies will be cached if the go.mod and go.sum files are not changed
RUN go mod download

# Build the Go app
RUN go build -o s3ValidateAndClean .

# Command to run the executable
# Override this for Windows from docker-compose YML
CMD ["./s3ValidateAndClean"]

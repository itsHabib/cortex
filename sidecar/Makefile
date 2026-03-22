.PHONY: build worker-build test lint docker-build clean

BINARY := bin/cortex-sidecar
WORKER_BINARY := bin/agent-worker

build:
	CGO_ENABLED=0 go build -o $(BINARY) ./cmd/cortex-sidecar

worker-build:
	CGO_ENABLED=0 go build -o $(WORKER_BINARY) ./cmd/agent-worker

test:
	go test ./... -race -v

lint:
	go vet ./...
	@which golangci-lint > /dev/null 2>&1 && golangci-lint run || echo "golangci-lint not installed, skipping"

docker-build:
	docker build -t cortex-sidecar .

clean:
	rm -rf bin/

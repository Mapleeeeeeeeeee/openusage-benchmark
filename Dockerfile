FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git jq curl bash procps unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (openusage project uses bun.lock)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /benchmark
COPY . /benchmark/
RUN chmod +x run_benchmark.sh validate.sh test_benchmark.sh entrypoint.sh docker-login.sh run_in_docker.sh

ENTRYPOINT ["/benchmark/entrypoint.sh"]

FROM debian:bookworm-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash curl git ca-certificates unzip jq \
        python3 python3-dev gcc libc6-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    curl -fsSL https://bun.sh/install | bash

ENV PATH="/root/.local/bin:/root/.bun/bin:/root/.headlong/app/bin:/root/.headlong/app/tools:$PATH"

# The app dir is a checkout of YOUR fork (the build context) — origin is
# pinned to the fork and any other remote (e.g. upstream) is dropped, so the
# container can never drift back to the original repo.
ARG FORK_URL="git@github.com:fcasco/lonco.git"
COPY . /root/.headlong/app/
WORKDIR /root/.headlong/app

RUN bash install.sh --symlinks && \
    headlong-web --build-only && \
    for r in $(git remote); do [ "$r" = origin ] || git remote remove "$r"; done && \
    git remote set-url origin "$FORK_URL" && \
    git checkout -B main origin/main 2>/dev/null || true && \
    git -C /root/.headlong/app symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true && \
    git rev-parse HEAD

VOLUME ["/root/.headlong"]

EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost:8080/ || exit 1

# Pull the fork's latest code at every start, then hand boot over to
# headlong-init (idempotent: keeps the key, restarts the mind + dashboard).
CMD ["bash", "-c", "bash /root/.headlong/app/bin/headlong-update --start; exec bash"]
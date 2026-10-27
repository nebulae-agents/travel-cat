FROM docker.io/library/node@sha256:b20fe038d9592822dd534600a1ddf467e985178aa3fed60ec441a056c2cc45bd
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/travelcat-acp
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
ENV HOME=/tmp XDG_CACHE_HOME=/tmp CODEX_HOME=/tmp NO_BROWSER=1 DEFAULT_AUTH_REQUEST="{\"methodId\":\"api-key\"}"
ENV MODEL_PROVIDER=travelcat-relay
ENV CODEX_CONFIG="{\"model\":\"gpt-5.1-codex\",\"web_search\":\"disabled\",\"model_provider\":\"travelcat-relay\",\"model_providers\":{\"travelcat-relay\":{\"name\":\"Travel Cat Relay\",\"base_url\":\"http://127.0.0.1:8765/v1\",\"env_key\":\"OPENAI_API_KEY\",\"wire_api\":\"responses\",\"request_max_retries\":0,\"stream_max_retries\":0}}}"
USER 65532:65532
WORKDIR /
CMD ["/opt/travelcat-acp/node_modules/.bin/codex-acp"]

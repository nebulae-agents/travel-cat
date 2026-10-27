# Supply an audited Python 3.11+ base by immutable digest; intentionally no default.
# Add a pinned ACP adapter and dependencies in a derived image, then use its digest.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 65532:65532
WORKDIR /tmp
ENTRYPOINT ["python3"]

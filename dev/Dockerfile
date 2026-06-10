FROM python:3.12-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    zip \
    unzip \
    curl \
    vim \
    nano \
    virtualenv \
    iputils-ping \
    curl \
    git \
    less \
    ssh \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    ca-certificates \
    gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg

# Add the official Docker repository to Apt sources
RUN echo \
    "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker CLI and Docker Compose plugin
RUN apt-get update && apt-get install -y \
    docker-ce-cli \
    docker-compose-plugin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN docker --version

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
    AWS_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
    AWS_ARCH="aarch64"; \
    else \
    echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

ENV AWS_CLI_PATH=/usr/local/aws-cli/current/bin
ENV PATH="$AWS_CLI_PATH:${PATH}"

RUN aws --version

COPY requirements.txt .
RUN pip3 install -r requirements.txt -t ./

RUN pip3 install --upgrade virtualenv

ARG TF_VERSION=1.11.3
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
    TF_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
    TF_ARCH="arm64"; \
    else \
    echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -LO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${TF_ARCH}.zip" && \
    unzip "terraform_${TF_VERSION}_linux_${TF_ARCH}.zip" && \
    mv terraform /usr/local/bin/ && \
    rm "terraform_${TF_VERSION}_linux_${TF_ARCH}.zip"

RUN terraform --version

ARG TOFU_VERSION=1.9.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
    TOFU_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
    TOFU_ARCH="arm64"; \
    else \
    echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -LO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TOFU_ARCH}.zip" && \
    unzip "tofu_${TOFU_VERSION}_linux_${TOFU_ARCH}.zip" tofu -d /usr/local/bin/ && \
    rm "tofu_${TOFU_VERSION}_linux_${TOFU_ARCH}.zip"

RUN tofu --version

RUN apt-get purge -y --auto-remove && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/bin/bash"]
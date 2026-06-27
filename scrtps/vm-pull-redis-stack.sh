#!/bin/bash
set -euo pipefail

echo "==> configure docker registry mirrors (CN)"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://docker.1panel.live"
  ]
}
JSON
systemctl restart docker
sleep 3

# 直连镜像前缀拉取（比 registry-mirrors 更稳）
IMAGES=(
  "docker.m.daocloud.io/redis/redis-stack-server:latest"
  "docker.1ms.run/redis/redis-stack-server:latest"
  "docker.xuanyuan.me/redis/redis-stack-server:latest"
)

for img in "${IMAGES[@]}"; do
  echo "==> trying pull $img"
  if docker pull "$img"; then
    docker tag "$img" redis/redis-stack-server:latest
    docker rm -f redis-stack 2>/dev/null || true
    docker run -d \
      --name redis-stack \
      --restart unless-stopped \
      -p 0.0.0.0:6379:6379 \
      -p 0.0.0.0:8001:8001 \
      -v redis-stack-data:/data \
      redis/redis-stack-server:latest
    echo "==> verify"
    docker ps --filter name=redis-stack
    docker exec redis-stack redis-cli PING
    docker exec redis-stack redis-cli MODULE LIST | head -15
    echo "==> DONE Redis Stack 192.168.59.129:6379"
    exit 0
  fi
done

echo "FAILED to pull redis stack image"
exit 1
